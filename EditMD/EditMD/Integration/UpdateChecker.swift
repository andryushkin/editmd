import Foundation

/// Update notification only — never downloads or installs. Feed contract,
/// threat model, decision rules: docs/integration.md § Update check.

// MARK: - The feed

/// Shape of https://dotmd.tools/editmd/latest.json. Contract with deployed
/// copies: add fields, never rename or drop. Hand-decoded because URL's
/// synthesized decoding throws on the empty string the site writes when a
/// product has no changelog.
struct UpdateFeed: Decodable, Equatable {
    var version: String
    /// Only trustedURL-accepted links survive decoding; nil → productPage.
    var page: URL?
    var notes: URL?
    var minimumSystemVersion: String?

    /// Compiled-in fallback so the alert button is never a no-op.
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

    /// HTTPS on dotmd.tools (or subdomain) only. Opened via NSWorkspace behind
    /// a trusted label, so HTTP, file:, foreign schemes, and look-alike
    /// domains must be impossible, not unlikely.
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

/// Strict dotted-numeric parse; missing component = 0 (1.2 == 1.2.0).
/// Strict on purpose: a lenient parse once read a corrupt ".999" as
/// "version 999 available" — junk must mean silence, not zero.
enum AppVersion {
    /// 1–4 components of ≤6 digits — no component can overflow.
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

    /// nil when either side is unparsable — caller must stay silent, not guess.
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult? {
        guard let left = parse(lhs), let right = parse(rhs) else { return nil }
        return compare(left, right)
    }

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

/// Decides the advice, never the download: DMG advice desynchronizes a brew
/// user from brew; brew advice hands everyone else a command they don't have.
enum InstallChannel: Equatable, Sendable {
    case homebrew
    case direct

    /// Homebrew only when the cask exists AND this bundle is exactly what a
    /// cask installs (EditMD.app directly inside an Applications folder) —
    /// otherwise the advice would update some other copy.
    /// nonisolated: file-system probes, always called off the main actor.
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
    /// Non-optional: feed without a trusted page falls back to productPage.
    var page: URL
    var notes: URL?
    var channel: InstallChannel
}

enum UpdateCheckResult: Equatable {
    case upToDate
    case available(AvailableUpdate)
    /// Newer version this Mac cannot run. Said out loud (silence reads as
    /// "no updates") but announced once per version on the automatic path.
    case requiresNewerSystem(version: String, minimum: String)
    case failed(String)
}

enum UpdateDecision {
    /// Pure verdict — testable without network, clock, or installed app.
    /// `skipping` is passed only on the automatic path; a manual check always
    /// answers honestly, even about a skipped release.
    static func evaluate(feed: UpdateFeed,
                         current: String,
                         system: String,
                         channel: InstallChannel,
                         skipping: String? = nil) -> UpdateCheckResult {
        // Unparsable/missing version → silence; never manufacture a prompt
        // out of a gap or junk.
        guard let latest = AppVersion.parse(feed.version),
              let running = AppVersion.parse(current),
              AppVersion.compare(latest, running) == .orderedDescending
        else { return .upToDate }

        // Unparsable minimum is ignored, not obeyed: one malformed field must
        // not hide a real release.
        if let raw = feed.minimumSystemVersion, let minimum = AppVersion.parse(raw),
           let running = AppVersion.parse(system),
           AppVersion.compare(running, minimum) == .orderedAscending {
            return .requiresNewerSystem(version: feed.version, minimum: raw)
        }

        // Exact version only: skipping 0.50 must not hide a rollback to 0.49.
        if let skipping, let skipped = AppVersion.parse(skipping),
           AppVersion.compare(skipped, latest) == .orderedSame {
            return .upToDate
        }

        return .available(AvailableUpdate(version: feed.version, current: current,
                                          page: feed.page ?? UpdateFeed.productPage,
                                          notes: feed.notes, channel: channel))
    }

    /// Counted from the last completed check.
    static let automaticInterval: TimeInterval = 24 * 60 * 60

    static func isDue(last: Date?, now: Date = Date(),
                      interval: TimeInterval = automaticInterval) -> Bool {
        guard let last else { return true }
        // A clock moved backwards would park the next check in the far future.
        if last > now { return true }
        return now.timeIntervalSince(last) >= interval
    }

    /// No alert on an inactive app or over another modal — runModal would nest
    /// inside an open panel and trap the user.
    static func canPresentNow(appIsActive: Bool, hasModalWindow: Bool) -> Bool {
        appIsActive && !hasModalWindow
    }
}

// MARK: - Fetching

protocol UpdateFeedFetching: Sendable {
    func data(from url: URL) async throws -> Data
}

struct URLSessionFeedFetcher: UpdateFeedFetching {
    /// Real feed is ~150 bytes; anything past this is a captive portal, a
    /// broken deploy, or hostile.
    static let maxBytes = 64 * 1024

    /// Cap separated from the network so it can be tested for what it does.
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
        // Site serves must-revalidate; default cache behavior stays fresh.
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Deliberate UA: states release + macOS only. URLSession's default
        // already leaks a build number and CFNetwork version.
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
        // Streamed: a server ignoring its own Content-Length cannot make us
        // buffer the whole body.
        return try await Self.collect(stream)
    }
}

// MARK: - Presentation seam

/// Decides only how long an alert may wait for a calm moment.
enum PresentationUrgency: Equatable, Sendable {
    /// Nobody asked — bounded wait, then give up.
    case unsolicited
    /// User pressed the button and is owed an answer — unlimited wait.
    case requested
}

/// Screen seam so the service is testable without AppKit.
@MainActor
protocol UpdatePresenting {
    /// true only once the alert was actually in front of the user. Caller
    /// records "already told them" only on true — marking beforehand let a
    /// quit during the wait mute a release permanently, unseen.
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

    /// The one in-flight request; a second caller joins it instead of racing.
    /// Carries its generation so a late-waking joiner cannot pair a newer
    /// number with an older result.
    private var inFlight: (generation: Int, task: Task<Result<Probe, Error>, Never>)?
    /// Round-trip identity: joiners share the number; nothing ≤
    /// answeredGeneration ever speaks. Stops two waiters on one request from
    /// each alerting, and a slow old alert from following a fresh one.
    private var lastGeneration = 0
    private var answeredGeneration = 0
    /// Manual check joined a running silent one: the silent path stays quiet
    /// and the manual one answers, re-judged without the skip.
    private var manualJoined = false
    /// Held across suspensions, released only by the taker. An earlier version
    /// reset it at the start of every request, which revoked a live alert's
    /// claim and let two stand at once.
    private var isPresenting = false
    private var waitingForScreen: [CheckedContinuation<Void, Never>] = []

    /// Channel travels with the feed: detection is file-system work, off main.
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

    /// Silent by design: reports a real update, the once-per-version
    /// incompatible notice, and nothing at all on failure.
    func checkAutomaticallyIfDue() {
        guard !AppDelegate.isRunningUnitTests,
              EditorSettings.shared.general.checkForUpdates,
              UpdateDecision.isDue(last: lastAutomaticCheck, now: now())
        else { return }
        Task { await runAutomatic() }
    }

    /// Answers every outcome out loud, including up-to-date and failure —
    /// a user-initiated check must never look ignored.
    func checkManually() {
        Task { await runManual() }
    }

    /// Internal so tests can drive one silent round without clock or settings.
    func runAutomatic() async {
        let (outcome, generation) = await probe()
        lastAutomaticCheck = now()
        // A manual caller joined: their answer is the honest one to show.
        guard !manualJoined else { return }
        let verdict = judge(outcome, skipping: skippedVersion)
        if case .requiresNewerSystem(let version, _) = verdict,
           announcedIncompatibleVersion == version { return }
        await announce(verdict, urgency: .unsolicited, generation: generation)
    }

    func runManual() async {
        // Join a running silent check: two requests would mean two alerts
        // about the same release.
        if inFlight != nil { manualJoined = true }
        let (outcome, generation) = await probe()
        manualJoined = false
        lastAutomaticCheck = now()
        await announce(judge(outcome, skipping: nil), urgency: .requested,
                       generation: generation)
    }

    /// Seeing the incompatible notice counts however it was reached —
    /// otherwise a manual lookup today means being told again tomorrow.
    private func announce(_ result: UpdateCheckResult,
                          urgency: PresentationUrgency,
                          generation: Int) async {
        if case .upToDate = result, urgency == .unsolicited { return }
        if case .failed = result, urgency == .unsolicited { return }
        guard generation > answeredGeneration else { return }
        guard await takeScreen(urgency: urgency) else { return }
        defer { releaseScreen() }
        // Re-check after taking the screen: two callers can both pass the
        // guard above and then queue.
        guard generation > answeredGeneration else { return }
        let shown = await presenter.present(result, checker: self, urgency: urgency)
        guard shown else { return }
        // Marked only once shown — an alert that never found its moment must
        // not silence the path behind it.
        answeredGeneration = generation
        if case .requiresNewerSystem(let version, _) = result {
            announcedIncompatibleVersion = version
        }
    }

    /// One alert at a time. false only for an unsolicited alert finding the
    /// screen busy; a requested one queues.
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

    /// One request at a time, shared by joiners; the generation identifies
    /// the round trip.
    private func probe() async -> (Result<Probe, Error>, Int) {
        if let inFlight { return (await inFlight.task.value, inFlight.generation) }
        lastGeneration += 1
        let generation = lastGeneration
        let fetcher = self.fetcher
        let url = Self.feedURL
        let bundlePath = Bundle.main.bundlePath
        let task = Task<Result<Probe, Error>, Never>.detached(priority: .utility) {
            // Everything off main: network wait, byte cap, untrusted parse,
            // install-channel probes.
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
