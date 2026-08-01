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

// MARK: - The feed

/// What `https://dotmd.tools/editmd/latest.json` serves.
///
/// A contract with a deployed site, read by copies we can no longer change:
/// unknown fields are ignored and missing ones are tolerated, so the site can
/// grow the document without stranding an old app. Decoded by hand because
/// `URL`'s synthesized decoding throws on the empty string the site writes
/// when a product has no changelog — a missing link must not lose the whole
/// answer.
struct UpdateFeed: Decodable, Equatable {
    var version: String
    /// Where to send the reader — the product page, which carries the
    /// download button, the changelog and the Homebrew line. The app does not
    /// have to know which of those suits them.
    var page: URL?
    var notes: URL?
    /// The macOS the new version needs, when the site states one.
    var minimumSystemVersion: String?

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
        page = Self.url(try c.decodeIfPresent(String.self, forKey: .page))
        notes = Self.url(try c.decodeIfPresent(String.self, forKey: .notes))
        let minimum = try c.decodeIfPresent(String.self, forKey: .minimumSystemVersion)
        minimumSystemVersion = (minimum?.isEmpty ?? true) ? nil : minimum
    }

    /// Only http(s) survives: the feed is a place the app will hand to
    /// `NSWorkspace`, and a document served from the network must not be able
    /// to name `file:` or a scheme registered by some other app.
    private static func url(_ raw: String?) -> URL? {
        guard let raw, !raw.isEmpty, let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else { return nil }
        return url
    }
}

// MARK: - Version comparison

/// Dotted numeric versions, compared the way a reader means them: 0.47.9 is
/// older than 0.47.10, and a missing component is zero (1.2 == 1.2.0).
/// Anything non-numeric in a component is ignored rather than rejected, so a
/// future "0.48.0-beta1" still sorts by its numbers instead of throwing the
/// comparison away.
enum AppVersion {
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = components(lhs), right = components(rhs)
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a < b ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    static func components(_ version: String) -> [Int] {
        version
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .drop { $0 == "v" || $0 == "V" }
            .split(separator: ".")
            .map { Int($0.prefix { $0.isNumber }) ?? 0 }
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
enum InstallChannel: Equatable {
    case homebrew
    case direct

    /// Homebrew only when the cask is actually present *and* this copy sits in
    /// an Applications folder — a developer running a build out of DerivedData
    /// on a machine that happens to have the cask is not a brew install.
    static func detect(bundlePath: String,
                       home: String = NSHomeDirectory(),
                       exists: (String) -> Bool = {
                           FileManager.default.fileExists(atPath: $0)
                       }) -> InstallChannel {
        let caskroots = ["/opt/homebrew/Caskroom/editmd", "/usr/local/Caskroom/editmd"]
        guard caskroots.contains(where: exists) else { return .direct }
        let appDirs = ["/Applications/", "\(home)/Applications/"]
        return appDirs.contains(where: bundlePath.hasPrefix) ? .homebrew : .direct
    }
}

// MARK: - The verdict

struct AvailableUpdate: Equatable {
    var version: String
    var current: String
    var page: URL?
    var notes: URL?
    var channel: InstallChannel
}

enum UpdateCheckResult: Equatable {
    case upToDate
    case available(AvailableUpdate)
    /// A newer version exists but this Mac cannot run it. Said out loud rather
    /// than swallowed: silence here reads as "no updates", and the user would
    /// keep waiting for one that will never be offered.
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
        // An empty version means the site could not resolve one at build time
        // (a deploy without network falls back to a pinned number, and that
        // number can be blank for a product that has never shipped). Nothing
        // to say — never invent a prompt out of a gap.
        guard !feed.version.isEmpty, !current.isEmpty else { return .upToDate }
        guard AppVersion.compare(feed.version, current) == .orderedDescending else {
            return .upToDate
        }
        if let minimum = feed.minimumSystemVersion,
           AppVersion.compare(system, minimum) == .orderedAscending {
            return .requiresNewerSystem(version: feed.version, minimum: minimum)
        }
        if let skipping, AppVersion.compare(skipping, feed.version) != .orderedAscending {
            return .upToDate
        }
        return .available(AvailableUpdate(version: feed.version, current: current,
                                          page: feed.page, notes: feed.notes,
                                          channel: channel))
    }

    /// One automatic check a day. The interval is counted from the last
    /// completed check, so a Mac that is opened and closed all day still asks
    /// once — and a machine that never quits EditMD is not a reason to stop
    /// checking, which is why the caller also re-arms on becoming active.
    static let automaticInterval: TimeInterval = 24 * 60 * 60

    static func isDue(last: Date?, now: Date = Date(),
                      interval: TimeInterval = automaticInterval) -> Bool {
        guard let last else { return true }
        // A clock moved backwards (timezone edit, restored backup) would
        // otherwise park the next check in the far future.
        if last > now { return true }
        return now.timeIntervalSince(last) >= interval
    }
}

// MARK: - Fetching

protocol UpdateFeedFetching: Sendable {
    func data(from url: URL) async throws -> Data
}

struct URLSessionFeedFetcher: UpdateFeedFetching {
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
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

// MARK: - The service

@MainActor
final class UpdateChecker {
    static let shared = UpdateChecker()

    static let feedURL = URL(string: "https://dotmd.tools/editmd/latest.json")!

    private enum Keys {
        static let lastCheck = "updateLastAutomaticCheck"
        static let skippedVersion = "updateSkippedVersion"
    }

    private let fetcher: UpdateFeedFetching
    private let defaults: UserDefaults
    /// Guards against two checks in flight — the menu item during a launch
    /// check, or a second click while the first request is still out.
    private var isChecking = false

    init(fetcher: UpdateFeedFetching = URLSessionFeedFetcher(),
         defaults: UserDefaults = .standard) {
        self.fetcher = fetcher
        self.defaults = defaults
    }

    var skippedVersion: String? {
        get { defaults.string(forKey: Keys.skippedVersion) }
        set { defaults.set(newValue, forKey: Keys.skippedVersion) }
    }

    private var lastAutomaticCheck: Date? {
        get { defaults.object(forKey: Keys.lastCheck) as? Date }
        set { defaults.set(newValue, forKey: Keys.lastCheck) }
    }

    /// Launch-time check. Silent by design: it reports only a real update, and
    /// a failure (offline, site down) says nothing at all — an alert about a
    /// check the user never asked for is noise.
    func checkAutomaticallyIfDue() {
        guard !AppDelegate.isRunningUnitTests,
              EditorSettings.shared.general.checkForUpdates,
              UpdateDecision.isDue(last: lastAutomaticCheck),
              !isChecking else { return }
        Task { [weak self] in
            guard let self else { return }
            let result = await self.check(skippingUserSkips: true)
            self.lastAutomaticCheck = Date()
            if case .available(let update) = result {
                UpdatePrompt.present(update, checker: self)
            }
        }
    }

    /// The menu item. Answers every outcome out loud, including "you are up to
    /// date" and the failure — a check the user started must not look ignored.
    func checkManually() {
        guard !isChecking else { return }
        Task { [weak self] in
            guard let self else { return }
            let result = await self.check(skippingUserSkips: false)
            self.lastAutomaticCheck = Date()
            UpdatePrompt.present(result, checker: self)
        }
    }

    private func check(skippingUserSkips: Bool) async -> UpdateCheckResult {
        isChecking = true
        defer { isChecking = false }
        do {
            let data = try await fetcher.data(from: Self.feedURL)
            let feed = try JSONDecoder().decode(UpdateFeed.self, from: data)
            return UpdateDecision.evaluate(
                feed: feed,
                current: AppVersion.current,
                system: AppVersion.currentSystem,
                channel: InstallChannel.detect(bundlePath: Bundle.main.bundlePath),
                skipping: skippingUserSkips ? skippedVersion : nil)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
