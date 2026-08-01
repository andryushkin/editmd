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

    func testTagPrefixAndSuffixDoNotDerailTheNumbers() {
        XCTAssertEqual(AppVersion.compare("v0.48.0", "0.48.0"), .orderedSame)
        XCTAssertEqual(AppVersion.compare("0.48.0-beta1", "0.47.14"), .orderedDescending)
    }

    func testGarbageComparesAsZeroRatherThanCrashing() {
        XCTAssertEqual(AppVersion.compare("", ""), .orderedSame)
        XCTAssertEqual(AppVersion.compare("nonsense", "0.0.0"), .orderedSame)
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

    func testOnlyHTTPLinksSurvive() throws {
        // A document off the network must not be able to hand NSWorkspace a
        // file: path or somebody else's registered scheme.
        let feed = try decode("""
        {"version": "0.48.0", "page": "file:///Applications/Calculator.app",
         "notes": "editmd://new?name=x"}
        """)
        XCTAssertNil(feed.page)
        XCTAssertNil(feed.notes)
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
}
