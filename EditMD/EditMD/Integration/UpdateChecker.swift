import Foundation

/// Tells the user when a newer EditMD exists. It never downloads or installs
/// anything: the app that ships outside the App Store has no updater, so the
/// gap this closes is *not knowing* a release happened — the replacing is
/// still done by hand (or by `brew upgrade`).
///
/// The question goes to `dotmd.tools`, not to GitHub's API: the request then
/// stays with the site the app belongs to, has no rate limit, and lets the
/// site decide what a released copy is told (see the site's `build.py`, which
/// writes the feed at build time).
///
/// The feed is treated as untrusted input throughout — it is a document
/// fetched over the network and parsed by copies we can no longer change.

// MARK: - The feed

/// What `https://dotmd.tools/editmd/latest.json` serves.
///
/// A contract with a deployed site: unknown fields are ignored and missing
/// ones tolerated, so the site can grow the document without stranding an old
/// app. Decoded by hand because `URL`'s synthesized decoding throws on the
/// empty string the site writes when a product has no changelog — a missing
/// link must not cost us the whole answer.
struct UpdateFeed: Decodable, Equatable {
    var version: String
    /// Where to send the reader. Only a link to our own site survives
    /// decoding; anything else is dropped and the compiled-in page is used,
    /// so a tampered feed cannot aim the "Open Download Page" button at an
    /// attacker's build.
    var page: URL?
    var notes: URL?
    /// The macOS the new version needs, when the site states one.
    var minimumSystemVersion: String?

    /// The page shipped in the binary. It is the answer whenever the feed
    /// does not supply a trusted one, so the primary button always works.
    static let productPage = URL(string: "https://dotmd.tools/editmd")!
    private static let trustedHost = "dotmd.tools"

    private enum CodingKeys: String, CodingKey {
        case version, page, notes, minimumSystemVersion
    }

    init(version: String, page: URL? = nil, notes: URL? = nil,
         minimumSystemVersion: String? = nil) {
        self.version = version
        self.page = page
        self.notes = notes
        self.minimumSystemVersion = minimumSystemVersion
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try c.decodeIfPresent(String.self, forKey: .version) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        page = Self.trustedURL(try c.decodeIfPresent(String.self, forKey: .page))
        notes = Self.trustedURL(try c.decodeIfPresent(String.self, forKey: .notes))
        let minimum = try c.decodeIfPresent(String.self, forKey: .minimumSystemVersion)
        minimumSystemVersion = (minimum?.isEmpty ?? true) ? nil : minimum
    }

    /// HTTPS on our own host, and nothing else. The app hands these to
    /// `NSWorkspace.open` behind a label the user reads as trustworthy, so
    /// plain HTTP, a `file:` path, somebody else's registered scheme and a
    /// look-alike domain all have to be impossible — not merely unlikely.
    static func trustedURL(_ raw: String?) -> URL? {
        guard let raw, !raw.isEmpty, let url = URL(string: raw),
              url.scheme?.lowercased() == "https",
              let host = url.host()?.lowercased(),
              host == trustedHost || host.hasSuffix(".\(trustedHost)")
        else { return nil }
        return url
    }
}

// MARK: - Version comparison

/// Dotted numeric versions, parsed strictly and compared the way a reader
/// means them: 0.47.9 is older than 0.47.10, and a missing component is zero
/// (1.2 == 1.2.0).
///
/// Strict on purpose. An earlier version of this shrugged at junk by reading
/// it as zero, which turned a corrupt feed saying ".999" into a confident
/// "version 999 is available". Anything that is not a plain dotted number now
/// fails to parse, and an unparsable version means silence.
enum AppVersion {
    /// At most four components of at most six digits — enough for any real
    /// version, and small enough that no component can overflow.
    static func parse(_ raw: String) -> [Int]? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.first == "v" || text.first == "V" { text.removeFirst() }
        guard !text.isEmpty else { return nil }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        var components: [Int] = []
        for part in parts {
            guard (1...6).contains(part.count),
                  part.allSatisfy(\.isNumber),
                  let value = Int(part) else { return nil }
            components.append(value)
        }
        return components
    }

    static func compare(_ lhs: [Int], _ rhs: [Int]) -> ComparisonResult {
        for index in 0..<max(lhs.count, rhs.count) {
            let a = index < lhs.count ? lhs[index] : 0
            let b = index < rhs.count ? rhs[index] : 0
            if a != b { return a < b ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    /// `nil` when either side is not a version at all — the caller must then
    /// stay quiet rather than guess an ordering.
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult? {
        guard let left = parse(lhs), let right = parse(rhs) else { return nil }
        return compare(left, right)
    }

    /// The running app's `CFBundleShortVersionString`.
    static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? ""
    }

    static var currentSystem: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
}

// MARK: - How this copy was installed

/// Decides the *advice*, never the download. Telling a Homebrew user to drag a
/// DMG over their install desynchronizes them from brew, which would then
/// report an older version forever; telling everyone else to run `brew` is a
/// command most of them cannot run.
enum InstallChannel: Equatable, Sendable {
    case homebrew
    case direct

    /// Homebrew only when the cask exists *and* this very bundle is the app a
    /// cask installs: `EditMD.app`, directly inside an Applications folder. A
    /// build running out of DerivedData, or a differently-named copy sitting
    /// beside the cask's, would be told to run a command that updates some
    /// other app.
    ///
    /// `nonisolated` and called off the main actor: the probes are file-system
    /// reads, which never run on the main actor in this app.
    nonisolated static func detect(
        bundlePath: String,
        home: String = NSHomeDirectory(),
        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> InstallChannel {
        let caskroots = ["/opt/homebrew/Caskroom/editmd", "/usr/local/Caskroom/editmd"]
        guard caskroots.contains(where: exists) else { return .direct }
        let path = (bundlePath as NSString).standardizingPath
        let caskInstalls = ["/Applications/EditMD.app", "\(home)/Applications/EditMD.app"]
        return caskInstalls.contains(path) ? .homebrew : .direct
    }
}

// MARK: - The verdict

struct AvailableUpdate: Equatable {
    var version: String
    var current: String
    /// Never optional: a feed that names no trusted page falls back to the
    /// compiled-in one, so the button in the alert always leads somewhere.
    var page: URL
    var notes: URL?
    var channel: InstallChannel
}

enum UpdateCheckResult: Equatable {
    case upToDate
    case available(AvailableUpdate)
    /// A newer version exists but this Mac cannot run it. Said out loud rather
    /// than swallowed: silence here reads as "no updates", and the user would
    /// keep waiting for one that will never be offered. Announced once per
    /// version on the automatic path — a fact that cannot change until they
    /// upgrade macOS must not become a daily alert.
    case requiresNewerSystem(version: String, minimum: String)
    case failed(String)
}

enum UpdateDecision {
    /// The whole judgement, as a pure function: everything the UI shows is
    /// decided here from values, so it can be tested without a network, a
    /// clock, or an installed app.
    ///
    /// `skipping` is the version the user asked not to hear about again; it is
    /// passed only on the automatic path, so "Check for Updates…" always
    /// answers honestly even about a skipped release.
    static func evaluate(feed: UpdateFeed,
                         current: String,
                         system: String,
                         channel: InstallChannel,
                         skipping: String? = nil) -> UpdateCheckResult {
        // An unparsable or missing version means the site could not resolve
        // one, or the document is not what we think it is. Nothing to say —
        // never manufacture a prompt out of a gap or out of junk.
        guard let latest = AppVersion.parse(feed.version),
              let running = AppVersion.parse(current),
              AppVersion.compare(latest, running) == .orderedDescending
        else { return .upToDate }

        // A minimum we cannot parse is ignored rather than obeyed: hiding a
        // real release because one field is malformed is the worse failure.
        if let raw = feed.minimumSystemVersion, let minimum = AppVersion.parse(raw),
           let running = AppVersion.parse(system),
           AppVersion.compare(running, minimum) == .orderedAscending {
            return .requiresNewerSystem(version: feed.version, minimum: raw)
        }

        // Only this exact version. Skipping 0.50 must not also hide a 0.49
        // that the site rolls back to.
        if let skipping, let skipped = AppVersion.parse(skipping),
           AppVersion.compare(skipped, latest) == .orderedSame {
            return .upToDate
        }

        return .available(AvailableUpdate(version: feed.version, current: current,
                                          page: feed.page ?? UpdateFeed.productPage,
                                          notes: feed.notes, channel: channel))
    }

    /// One automatic check a day, counted from the last completed check.
    static let automaticInterval: TimeInterval = 24 * 60 * 60

    static func isDue(last: Date?, now: Date = Date(),
                      interval: TimeInterval = automaticInterval) -> Bool {
        guard let last else { return true }
        // A clock moved backwards (timezone edit, restored backup) would
        // otherwise park the next check in the far future.
        if last > now { return true }
        return now.timeIntervalSince(last) >= interval
    }

    /// An alert must not land on a user who is not looking, or on top of
    /// another modal — `runModal` would nest inside an open panel and trap
    /// them. The automatic path waits for a calm moment instead.
    static func canPresentNow(appIsActive: Bool, hasModalWindow: Bool) -> Bool {
        appIsActive && !hasModalWindow
    }
}

// MARK: - Fetching

protocol UpdateFeedFetching: Sendable {
    func data(from url: URL) async throws -> Data
}

struct URLSessionFeedFetcher: UpdateFeedFetching {
    /// The real document is ~150 bytes. Anything past this is not our feed —
    /// a captive portal, a broken deploy, or something hostile — and reading
    /// it into memory is the only harm it could do us.
    static let maxBytes = 64 * 1024

    /// The cap itself, apart from the network, so it can be tested for what it
    /// actually does rather than by injecting the error it is supposed to
    /// raise.
    static func collect<Bytes: AsyncSequence>(_ bytes: Bytes,
                                              cap: Int = maxBytes) async throws -> Data
    where Bytes.Element == UInt8 {
        var data = Data()
        data.reserveCapacity(1024)
        for try await byte in bytes {
            data.append(byte)
            if data.count > cap { throw URLError(.dataLengthExceedsMaximum) }
        }
        return data
    }

    func data(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        // The site serves the feed with `must-revalidate`, so a conditional
        // request is enough to stay fresh; going out of our way to ignore the
        // cache would only cost bytes on a check that runs once a day.
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // A deliberate User-Agent rather than URLSession's default, which
        // already leaks a build number and a CFNetwork version. This states
        // the two things the site could legitimately want in a server log —
        // which release is asking, on which macOS — and nothing that
        // distinguishes one copy from another.
        request.setValue("EditMD/\(AppVersion.current) (macOS \(AppVersion.currentSystem))",
                         forHTTPHeaderField: "User-Agent")

        let (stream, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        if response.expectedContentLength > Int64(Self.maxBytes) {
            throw URLError(.dataLengthExceedsMaximum)
        }
        // Streamed rather than buffered by URLSession, so a server that
        // ignores its own Content-Length cannot make us hold the whole body.
        return try await Self.collect(stream)
    }
}

// MARK: - Presentation seam

/// Why an alert is being raised — which decides how long it may wait for a
/// calm moment, and nothing else.
enum PresentationUrgency: Equatable, Sendable {
    /// Nobody asked. Waits a while for the app to be usable, then gives up:
    /// news this old is not worth ambushing anyone with.
    case unsolicited
    /// The user pressed Check for Updates… and is owed an answer, however
    /// long they take to come back to the app.
    case requested
}

/// What the checker needs from a screen. A protocol so the service can be
/// tested for what it decides to show, without AppKit in the way.
@MainActor
protocol UpdatePresenting {
    /// Returns once the alert has actually been in front of the user —
    /// `false` if the moment never came and nothing was shown.
    ///
    /// The caller records "already told them" only on `true`. Marking it
    /// beforehand meant a quit during the wait suppressed the message
    /// permanently, without it ever having been seen.
    @discardableResult
    func present(_ result: UpdateCheckResult, checker: UpdateChecker,
                 urgency: PresentationUrgency) async -> Bool
}

// MARK: - The service

@MainActor
final class UpdateChecker {
    static let shared = UpdateChecker()

    static let feedURL = URL(string: "https://dotmd.tools/editmd/latest.json")!

    private enum Keys {
        static let lastCheck = "updateLastAutomaticCheck"
        static let skippedVersion = "updateSkippedVersion"
        static let announcedIncompatible = "updateAnnouncedIncompatibleVersion"
    }

    private let fetcher: UpdateFeedFetching
    private let defaults: UserDefaults
    private let presenter: UpdatePresenting
    private let now: () -> Date

    /// The one check that may be in flight. Held (rather than a bare flag) so
    /// a second caller joins the running request instead of starting its own
    /// — and so a manual click during the daily check still gets an answer.
    /// The request in flight, carrying its own generation so a joiner cannot
    /// read a newer number after waking late and pair it with an older result.
    private var inFlight: (generation: Int, task: Task<Result<Probe, Error>, Never>)?
    /// Which round trip a result belongs to. Everyone joining one request
    /// shares its number, and nothing older than the last answered number ever
    /// speaks — that is what stops the paths waiting on a single request from
    /// each raising an alert, whichever order they wake in, and what keeps a
    /// slow older alert from following a fresher one onto the screen.
    private var lastGeneration = 0
    private var answeredGeneration = 0
    /// Set when someone asked in person while a silent check was already
    /// running: the silent path then stays quiet and lets the manual one
    /// answer, honestly — re-judged without their skip.
    private var manualJoined = false
    /// Whether an alert is on screen or waiting for its moment, and who is
    /// queued behind it.
    ///
    /// Presentation spans suspensions, so this is held for the whole span and
    /// released only by the caller that took it. An earlier version reset a
    /// shared flag at the start of every request, which could revoke a live
    /// alert's claim and let two stand at once.
    private var isPresenting = false
    private var waitingForScreen: [CheckedContinuation<Void, Never>] = []

    /// What one round trip yields. The channel travels with the feed because
    /// detecting it is file-system work that belongs off the main actor.
    private struct Probe: Sendable {
        var feed: UpdateFeed
        var channel: InstallChannel
    }

    init(fetcher: UpdateFeedFetching = URLSessionFeedFetcher(),
         defaults: UserDefaults = .standard,
         presenter: UpdatePresenting = UpdateAlertPresenter(),
         now: @escaping () -> Date = Date.init) {
        self.fetcher = fetcher
        self.defaults = defaults
        self.presenter = presenter
        self.now = now
    }

    var skippedVersion: String? {
        get { defaults.string(forKey: Keys.skippedVersion) }
        set { defaults.set(newValue, forKey: Keys.skippedVersion) }
    }

    private var announcedIncompatibleVersion: String? {
        get { defaults.string(forKey: Keys.announcedIncompatible) }
        set { defaults.set(newValue, forKey: Keys.announcedIncompatible) }
    }

    private var lastAutomaticCheck: Date? {
        get { defaults.object(forKey: Keys.lastCheck) as? Date }
        set { defaults.set(newValue, forKey: Keys.lastCheck) }
    }

    /// Launch-time check. Silent by design: it reports a real update, says the
    /// once-per-version piece about a release this Mac cannot run, and says
    /// nothing at all when the check fails — an alert about a check the user
    /// never asked for is noise.
    func checkAutomaticallyIfDue() {
        guard !AppDelegate.isRunningUnitTests,
              EditorSettings.shared.general.checkForUpdates,
              UpdateDecision.isDue(last: lastAutomaticCheck, now: now())
        else { return }
        Task { await runAutomatic() }
    }

    /// The menu item and the Settings button. Answers every outcome out loud,
    /// including "you are up to date" and the failure — a check the user
    /// started must never look ignored.
    func checkManually() {
        Task { await runManual() }
    }

    /// Internal rather than private so the tests can drive one round of the
    /// silent path directly, without a clock or a settings toggle in the way.
    func runAutomatic() async {
        let (outcome, generation) = await probe()
        lastAutomaticCheck = now()
        // Someone asked in person while this was out: their answer is the
        // honest one, and it is theirs to show.
        guard !manualJoined else { return }
        let verdict = judge(outcome, skipping: skippedVersion)
        if case .requiresNewerSystem(let version, _) = verdict,
           announcedIncompatibleVersion == version { return }
        // Recorded only once it has actually been seen: a quit while the
        // alert was still waiting for a calm moment would otherwise mute
        // this release for good.
        await announce(verdict, urgency: .unsolicited, generation: generation)
    }

    func runManual() async {
        // Join a running silent check rather than racing it: two requests
        // would mean two alerts about the same release.
        if inFlight != nil { manualJoined = true }
        let (outcome, generation) = await probe()
        manualJoined = false
        lastAutomaticCheck = now()
        await announce(judge(outcome, skipping: nil), urgency: .requested,
                       generation: generation)
    }

    /// Show a verdict and remember what showing it implies. Seeing the
    /// "needs a newer macOS" notice counts however it was reached — otherwise
    /// looking it up by hand today means being told again tomorrow.
    private func announce(_ result: UpdateCheckResult,
                          urgency: PresentationUrgency,
                          generation: Int) async {
        if case .upToDate = result, urgency == .unsolicited { return }
        if case .failed = result, urgency == .unsolicited { return }
        guard generation > answeredGeneration else { return }
        guard await takeScreen(urgency: urgency) else { return }
        defer { releaseScreen() }
        // Again, now that this call owns the screen. Two callers can both pass
        // the check above and then queue; without this the second one shows
        // the answer the first has already given.
        guard generation > answeredGeneration else { return }
        let shown = await presenter.present(result, checker: self, urgency: urgency)
        guard shown else { return }
        // Marked only once something reached the screen, so an alert that
        // never found its moment does not silence the path behind it.
        answeredGeneration = generation
        if case .requiresNewerSystem(let version, _) = result {
            announcedIncompatibleVersion = version
        }
    }

    /// One alert at a time.
    ///
    /// `false` only for an unsolicited alert that found the screen busy — its
    /// news is either already up there or can wait for tomorrow. A requested
    /// one queues, because the user pressed a button.
    private func takeScreen(urgency: PresentationUrgency) async -> Bool {
        while isPresenting {
            guard urgency == .requested else { return false }
            await withCheckedContinuation { waitingForScreen.append($0) }
        }
        isPresenting = true
        return true
    }

    private func releaseScreen() {
        isPresenting = false
        let queued = waitingForScreen
        waitingForScreen.removeAll()
        queued.forEach { $0.resume() }
    }

    private func judge(_ outcome: Result<Probe, Error>,
                       skipping: String?) -> UpdateCheckResult {
        switch outcome {
        case .failure(let error):
            return .failed(error.localizedDescription)
        case .success(let probe):
            return UpdateDecision.evaluate(
                feed: probe.feed,
                current: AppVersion.current,
                system: AppVersion.currentSystem,
                channel: probe.channel,
                skipping: skipping)
        }
    }

    /// One request at a time, shared by everyone who asks while it is out.
    /// The number identifies the round trip, so joiners can tell they are
    /// looking at the same answer.
    private func probe() async -> (Result<Probe, Error>, Int) {
        if let inFlight { return (await inFlight.task.value, inFlight.generation) }
        lastGeneration += 1
        let generation = lastGeneration
        let fetcher = self.fetcher
        let url = Self.feedURL
        let bundlePath = Bundle.main.bundlePath
        let task = Task<Result<Probe, Error>, Never>.detached(priority: .utility) {
            // Off the main actor entirely: the network wait, the byte cap,
            // the parse of an untrusted document, and the file-system probes
            // behind the install channel all happen here.
            do {
                let data = try await fetcher.data(from: url)
                let feed = try JSONDecoder().decode(UpdateFeed.self, from: data)
                return .success(Probe(feed: feed,
                                      channel: InstallChannel.detect(bundlePath: bundlePath)))
            } catch {
                return .failure(error)
            }
        }
        inFlight = (generation, task)
        let result = await task.value
        inFlight = nil
        return (result, generation)
    }
}
