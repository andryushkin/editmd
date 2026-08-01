import XCTest
@testable import EditMD

/// The update check is a promise made to people we cannot reach: a copy in the
/// wild decides, from a document served by the site, whether to interrupt its
/// owner. Everything that decision rests on is a pure function, and this is
/// where it is held to account — no network, no clock, no installed app.
final class UpdateCheckerTests: XCTestCase {

    // MARK: - Version comparison

    func testTenIsNewerThanNine() {
        // The reason this is not a string comparison: "0.47.10" < "0.47.9".
        XCTAssertEqual(AppVersion.compare("0.47.10", "0.47.9"), .orderedDescending)
        XCTAssertEqual(AppVersion.compare("0.47.9", "0.47.10"), .orderedAscending)
    }

    func testMissingComponentsAreZero() {
        XCTAssertEqual(AppVersion.compare("1.2", "1.2.0"), .orderedSame)
        XCTAssertEqual(AppVersion.compare("1.2.1", "1.2"), .orderedDescending)
        XCTAssertEqual(AppVersion.compare("2", "1.9.9"), .orderedDescending)
    }

    func testTagPrefixIsAccepted() {
        XCTAssertEqual(AppVersion.compare("v0.48.0", "0.48.0"), .orderedSame)
    }

    func testJunkHasNoOrderingAtAll() {
        // Reading junk as zero is how ".999" once became "version 999 is
        // available". Nothing that is not a plain dotted number parses.
        for junk in ["", ".999", "nonsense", "0.48.0-beta1", "1.2.3.4.5",
                     "1234567", "1..2", "0x10", " ", "1.2.-3"] {
            XCTAssertNil(AppVersion.parse(junk), "\(junk) must not parse")
        }
        XCTAssertNil(AppVersion.compare(".999", "0.47.14"))
    }

    func testRealVersionsParse() {
        XCTAssertEqual(AppVersion.parse("0.47.14"), [0, 47, 14])
        XCTAssertEqual(AppVersion.parse("26.5.0"), [26, 5, 0])
        XCTAssertEqual(AppVersion.parse("14"), [14])
        XCTAssertEqual(AppVersion.parse("1.2.3.4"), [1, 2, 3, 4])
    }

    // MARK: - Feed decoding

    private func decode(_ json: String) throws -> UpdateFeed {
        try JSONDecoder().decode(UpdateFeed.self, from: Data(json.utf8))
    }

    func testDecodesTheFeedTheSiteActuallyServes() throws {
        let feed = try decode("""
        {
          "version": "0.48.0",
          "page": "https://dotmd.tools/editmd",
          "notes": "https://dotmd.tools/editmd/changelog",
          "minimumSystemVersion": "14.0"
        }
        """)
        XCTAssertEqual(feed.version, "0.48.0")
        XCTAssertEqual(feed.page?.absoluteString, "https://dotmd.tools/editmd")
        XCTAssertEqual(feed.notes?.absoluteString, "https://dotmd.tools/editmd/changelog")
        XCTAssertEqual(feed.minimumSystemVersion, "14.0")
    }

    func testEmptyAndMissingLinksDoNotLoseTheAnswer() throws {
        // The site writes "" for a product with no changelog, and may omit the
        // minimum entirely. Neither may cost us the version.
        let feed = try decode(#"{"version": "0.48.0", "notes": ""}"#)
        XCTAssertEqual(feed.version, "0.48.0")
        XCTAssertNil(feed.notes)
        XCTAssertNil(feed.page)
        XCTAssertNil(feed.minimumSystemVersion)
    }

    func testUnknownFieldsAreIgnoredSoTheSiteCanGrow() throws {
        let feed = try decode(#"{"version": "0.48.0", "criticality": "high"}"#)
        XCTAssertEqual(feed.version, "0.48.0")
    }

    func testOnlyOurOwnHTTPSLinksSurvive() throws {
        // The alert opens this behind a label the user reads as trustworthy,
        // so a tampered feed must not be able to aim it anywhere else.
        for hostile in ["file:///Applications/Calculator.app",
                        "editmd://new?name=x",
                        "http://dotmd.tools/editmd",
                        "https://dotmd.tools.evil.example/editmd",
                        "https://evil.example/editmd",
                        "https://user@evil.example#dotmd.tools"] {
            XCTAssertNil(UpdateFeed.trustedURL(hostile), "\(hostile) must be rejected")
        }
        XCTAssertNotNil(UpdateFeed.trustedURL("https://dotmd.tools/editmd"))
        XCTAssertNotNil(UpdateFeed.trustedURL("https://www.dotmd.tools/editmd/changelog"))
    }

    func testARejectedPageStillLeavesTheButtonSomewhereToGo() {
        // The primary button must never be a no-op: without a trusted page
        // the compiled-in one stands in.
        let feed = UpdateFeed(version: "0.48.0", page: nil)
        guard case .available(let update) = UpdateDecision.evaluate(
            feed: feed, current: "0.47.14", system: "26.5.0", channel: .direct)
        else { return XCTFail("expected an available update") }
        XCTAssertEqual(update.page, UpdateFeed.productPage)
    }

    // MARK: - Install channel

    private func detect(bundle: String, present: [String]) -> InstallChannel {
        InstallChannel.detect(bundlePath: bundle, home: "/Users/tester",
                              exists: { present.contains($0) })
    }

    func testBrewInstallGetsTheBrewAdvice() {
        XCTAssertEqual(detect(bundle: "/Applications/EditMD.app",
                              present: ["/opt/homebrew/Caskroom/editmd"]), .homebrew)
        XCTAssertEqual(detect(bundle: "/Users/tester/Applications/EditMD.app",
                              present: ["/usr/local/Caskroom/editmd"]), .homebrew)
    }

    func testDMGInstallIsNeverToldToRunBrew() {
        XCTAssertEqual(detect(bundle: "/Applications/EditMD.app", present: []), .direct)
    }

    func testDeveloperBuildOnAMachineWithTheCaskIsNotABrewInstall() {
        // The copy being run is the one out of DerivedData; `brew upgrade`
        // would touch a different app than the one on screen.
        XCTAssertEqual(
            detect(bundle: "/Users/tester/Library/Developer/Xcode/DerivedData/EditMD-x/Build/Products/Debug/EditMD.app",
                   present: ["/opt/homebrew/Caskroom/editmd"]),
            .direct)
    }

    func testAnotherCopyBesideTheCaskInstallIsNotTheCaskInstall() {
        // `brew upgrade` would update /Applications/EditMD.app — not this.
        XCTAssertEqual(detect(bundle: "/Applications/EditMD Beta.app",
                              present: ["/opt/homebrew/Caskroom/editmd"]), .direct)
        XCTAssertEqual(detect(bundle: "/Applications/Old/EditMD.app",
                              present: ["/opt/homebrew/Caskroom/editmd"]), .direct)
    }

    // MARK: - The verdict

    private func evaluate(feedVersion: String, current: String,
                          system: String = "26.5.0", minimum: String? = "14.0",
                          skipping: String? = nil) -> UpdateCheckResult {
        UpdateDecision.evaluate(
            feed: UpdateFeed(version: feedVersion,
                             page: URL(string: "https://dotmd.tools/editmd"),
                             minimumSystemVersion: minimum),
            current: current, system: system, channel: .direct, skipping: skipping)
    }

    func testNewerVersionIsOffered() {
        guard case .available(let update) =
                evaluate(feedVersion: "0.48.0", current: "0.47.14") else {
            return XCTFail("expected an available update")
        }
        XCTAssertEqual(update.version, "0.48.0")
        XCTAssertEqual(update.current, "0.47.14")
        XCTAssertEqual(update.channel, .direct)
    }

    func testSameOrOlderIsSilence() {
        XCTAssertEqual(evaluate(feedVersion: "0.47.14", current: "0.47.14"), .upToDate)
        // A developer build ahead of the site must not be told to downgrade.
        XCTAssertEqual(evaluate(feedVersion: "0.47.14", current: "0.48.0"), .upToDate)
    }

    func testAFeedWithoutAVersionInventsNothing() {
        // A site built without network falls back to a pinned number, which
        // can be blank. Silence is the only correct response.
        XCTAssertEqual(evaluate(feedVersion: "", current: "0.47.14"), .upToDate)
        XCTAssertEqual(evaluate(feedVersion: "0.48.0", current: ""), .upToDate)
    }

    func testAnUnrunnableReleaseIsExplainedRatherThanHidden() {
        let result = evaluate(feedVersion: "0.48.0", current: "0.47.14",
                              system: "14.7.1", minimum: "15.0")
        XCTAssertEqual(result, .requiresNewerSystem(version: "0.48.0", minimum: "15.0"))
    }

    func testSystemExactlyAtTheMinimumIsOffered() {
        guard case .available = evaluate(feedVersion: "0.48.0", current: "0.47.14",
                                         system: "15.0.0", minimum: "15.0") else {
            return XCTFail("15.0 satisfies a 15.0 minimum")
        }
    }

    func testSkippedVersionStaysQuietButALaterOneDoesNot() {
        XCTAssertEqual(
            evaluate(feedVersion: "0.48.0", current: "0.47.14", skipping: "0.48.0"),
            .upToDate)
        guard case .available = evaluate(feedVersion: "0.49.0", current: "0.47.14",
                                         skipping: "0.48.0") else {
            return XCTFail("skipping 0.48.0 must not mute 0.49.0")
        }
    }

    func testSkipMutesOnlyItsOwnVersion() {
        // A rollback on the site: they skipped 0.50, the feed now says 0.49,
        // and they are still on 0.47 — 0.49 is news.
        guard case .available = evaluate(feedVersion: "0.49.0", current: "0.47.14",
                                         skipping: "0.50.0") else {
            return XCTFail("skipping a later version must not mute an earlier one")
        }
    }

    func testAnUnparsableMinimumIsIgnoredRatherThanHidingTheRelease() {
        guard case .available = evaluate(feedVersion: "0.48.0", current: "0.47.14",
                                         system: "14.0.0", minimum: "soon") else {
            return XCTFail("one malformed field must not swallow a real release")
        }
    }

    func testAJunkFeedVersionSaysNothing() {
        XCTAssertEqual(evaluate(feedVersion: ".999", current: "0.47.14"), .upToDate)
        XCTAssertEqual(evaluate(feedVersion: "99999999", current: "0.47.14"), .upToDate)
    }

    func testSkipIsIgnoredWhenTheUserAsksExplicitly() {
        // `skipping: nil` is what the menu item passes: a check someone
        // started themselves must answer honestly.
        guard case .available = evaluate(feedVersion: "0.48.0", current: "0.47.14",
                                         skipping: nil) else {
            return XCTFail("a manual check must still see the skipped release")
        }
    }

    // MARK: - Throttling

    func testFirstLaunchChecks() {
        XCTAssertTrue(UpdateDecision.isDue(last: nil))
    }

    func testOncePerDay() {
        let now = Date()
        XCTAssertFalse(UpdateDecision.isDue(last: now.addingTimeInterval(-3600), now: now))
        XCTAssertTrue(UpdateDecision.isDue(last: now.addingTimeInterval(-25 * 3600), now: now))
    }

    func testAClockMovedBackwardsDoesNotParkTheNextCheckForever() {
        let now = Date()
        XCTAssertTrue(UpdateDecision.isDue(last: now.addingTimeInterval(86_400), now: now))
    }

    // MARK: - The size cap

    /// Bytes as the fetcher really consumes them, so the cap is tested for
    /// what it does rather than by injecting the error it should raise.
    private func stream(of count: Int) -> AsyncStream<UInt8> {
        AsyncStream { continuation in
            for _ in 0..<count { continuation.yield(UInt8(ascii: "x")) }
            continuation.finish()
        }
    }

    func testABodyWithinTheCapIsRead() async throws {
        let data = try await URLSessionFeedFetcher.collect(stream(of: 512), cap: 1024)
        XCTAssertEqual(data.count, 512)
    }

    func testAnEndlessBodyIsCutOffAtTheCap() async {
        // A server ignoring its own Content-Length must not be able to make
        // the app hold the whole thing.
        do {
            _ = try await URLSessionFeedFetcher.collect(stream(of: 4096), cap: 1024)
            XCTFail("expected the cap to stop the read")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .dataLengthExceedsMaximum)
        }
    }

    // MARK: - Presentation timing

    func testAnAlertWaitsForAMomentTheUserIsActuallyThere() {
        // Nesting runModal inside an open panel traps the user, and an alert
        // raised while they are in another app lands where they are not.
        XCTAssertTrue(UpdateDecision.canPresentNow(appIsActive: true, hasModalWindow: false))
        XCTAssertFalse(UpdateDecision.canPresentNow(appIsActive: false, hasModalWindow: false))
        XCTAssertFalse(UpdateDecision.canPresentNow(appIsActive: true, hasModalWindow: true))
    }
}

// MARK: - The service

/// The checker itself: what it decides to *show*, and when it keeps quiet.
/// Everything is injected — feed, clock, defaults, presenter — so these run
/// with no network and no screen.
@MainActor
final class UpdateCheckerServiceTests: XCTestCase {

    private final class Presenter: UpdatePresenting {
        var shown: [UpdateCheckResult] = []
        /// Set false to stand in for an alert that never found its moment —
        /// the app was never activated again, or a modal stayed up.
        var succeeds = true
        func present(_ result: UpdateCheckResult, checker: UpdateChecker) async -> Bool {
            guard succeeds else { return false }
            shown.append(result)
            return true
        }
    }

    /// Answers with a fixed body, after an optional handshake that lets a test
    /// hold a request open and start a second one.
    private struct Fetcher: UpdateFeedFetching {
        let body: String
        var error: (any Error)?
        var gate: Gate?

        func data(from url: URL) async throws -> Data {
            if let gate { await gate.wait() }
            if let error { throw error }
            return Data(body.utf8)
        }
    }

    private actor Gate {
        private var continuations: [CheckedContinuation<Void, Never>] = []
        private var open = false
        func wait() async {
            if open { return }
            await withCheckedContinuation { continuations.append($0) }
        }
        func openUp() {
            open = true
            continuations.forEach { $0.resume() }
            continuations.removeAll()
        }
    }

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        suiteName = "editmd-update-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    /// A version nothing can be newer than, so a feed quoting the running
    /// build reads as "up to date" whatever the test host's version is.
    private var runningVersion: String { AppVersion.current }

    private func feed(_ version: String) -> String {
        #"{"version": "\#(version)", "page": "https://dotmd.tools/editmd"}"#
    }

    private func makeChecker(body: String,
                             error: (any Error)? = nil,
                             gate: Gate? = nil,
                             presenter: Presenter) -> UpdateChecker {
        UpdateChecker(fetcher: Fetcher(body: body, error: error, gate: gate),
                      defaults: defaults,
                      presenter: presenter,
                      now: { Date() })
    }

    func testAManualCheckAlwaysAnswers() async {
        let presenter = Presenter()
        let checker = makeChecker(body: feed(runningVersion), presenter: presenter)
        await checker.runManual()
        XCTAssertEqual(presenter.shown.count, 1)
        XCTAssertEqual(presenter.shown.first, .upToDate)
    }

    func testAManualCheckReportsAFailureRatherThanLookingIgnored() async {
        let presenter = Presenter()
        let checker = makeChecker(body: "", error: URLError(.notConnectedToInternet),
                                  presenter: presenter)
        await checker.runManual()
        guard case .failed = presenter.shown.first else {
            return XCTFail("a check the user started must say it failed")
        }
    }

    func testAManualCheckSeesThroughASkip() async {
        let presenter = Presenter()
        let checker = makeChecker(body: feed("99.0.0"), presenter: presenter)
        checker.skippedVersion = "99.0.0"
        await checker.runManual()
        guard case .available = presenter.shown.first else {
            return XCTFail("asked in person, the skip does not apply")
        }
    }

    func testTheSilentPathSaysNothingWhenTheCheckFails() async {
        let presenter = Presenter()
        let checker = makeChecker(body: "", error: URLError(.timedOut), presenter: presenter)
        await checker.runAutomatic()
        XCTAssertTrue(presenter.shown.isEmpty)
    }

    func testTheSilentPathSaysNothingWhenUpToDate() async {
        let presenter = Presenter()
        let checker = makeChecker(body: feed(runningVersion), presenter: presenter)
        await checker.runAutomatic()
        XCTAssertTrue(presenter.shown.isEmpty)
    }

    func testAnIncompatibleReleaseIsAnnouncedOnceAndThenLetGo() async {
        // The P1 this replaced: the silent path used to drop this verdict
        // entirely, so a user on an older macOS was told nothing at all.
        let body = #"{"version": "99.0.0", "minimumSystemVersion": "999.0"}"#
        let presenter = Presenter()
        let checker = makeChecker(body: body, presenter: presenter)
        await checker.runAutomatic()
        guard case .requiresNewerSystem = presenter.shown.first else {
            return XCTFail("expected the incompatible release to be explained")
        }
        // It cannot change until they upgrade macOS, so it must not repeat.
        await checker.runAutomatic()
        XCTAssertEqual(presenter.shown.count, 1)
    }

    func testAnUnseenAnnouncementIsNotRememberedAsSeen() async {
        // Marking it beforehand meant a quit while the alert was still waiting
        // for a calm moment muted the release permanently, unseen.
        let body = #"{"version": "99.0.0", "minimumSystemVersion": "999.0"}"#
        let presenter = Presenter()
        presenter.succeeds = false
        let checker = makeChecker(body: body, presenter: presenter)
        await checker.runAutomatic()
        XCTAssertTrue(presenter.shown.isEmpty)

        // Next launch, a moment presents itself: they must still be told.
        presenter.succeeds = true
        await checker.runAutomatic()
        guard case .requiresNewerSystem = presenter.shown.first else {
            return XCTFail("an announcement that was never shown must be retried")
        }
    }

    func testAClaimThatNeverReachedTheScreenIsReleased() async {
        // Otherwise the first silent failure would also silence the manual
        // check that follows it.
        let presenter = Presenter()
        presenter.succeeds = false
        let checker = makeChecker(body: feed("99.0.0"), presenter: presenter)
        await checker.runAutomatic()
        presenter.succeeds = true
        await checker.runManual()
        XCTAssertEqual(presenter.shown.count, 1)
    }

    func testAnOversizedBodyIsAFailureRatherThanMemory() async {
        let presenter = Presenter()
        let huge = #"{"version": "99.0.0", "pad": ""# + String(repeating: "x", count: 200)
        let checker = makeChecker(body: huge, error: URLError(.dataLengthExceedsMaximum),
                                  presenter: presenter)
        await checker.runManual()
        guard case .failed = presenter.shown.first else {
            return XCTFail("a body past the cap must fail the check, not be parsed")
        }
    }

    func testTwoOverlappingChecksProduceOneAlert() async {
        // Both paths waiting on one request used to be able to raise two
        // alerts about the same release, depending on who woke first.
        let gate = Gate()
        let presenter = Presenter()
        let checker = makeChecker(body: feed("99.0.0"), gate: gate, presenter: presenter)
        async let automatic: Void = checker.runAutomatic()
        async let manual: Void = checker.runManual()
        await Task.yield()
        await gate.openUp()
        _ = await (automatic, manual)
        XCTAssertEqual(presenter.shown.count, 1)
        guard case .available = presenter.shown.first else {
            return XCTFail("expected the update to be offered exactly once")
        }
    }
}
