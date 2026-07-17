import XCTest
@testable import EditMD

@MainActor
final class PreviewFindModelTests: XCTestCase {

    /// A model wired to recording closures, so the pure state transitions can
    /// be tested without a live WKWebView.
    private func makeModel() -> (PreviewFindModel, Recorder) {
        let model = PreviewFindModel()
        let rec = Recorder()
        model.runSearch = { rec.searches.append($0) }
        model.stepMatch = { rec.steps.append($0) }
        model.clearSearch = { rec.clears += 1 }
        model.currentSelection = { rec.selection }
        return (model, rec)
    }

    private final class Recorder {
        var searches: [String] = []
        var steps: [Int] = []
        var clears = 0
        var selection: String?
    }

    func testSetQueryRunsSearch() {
        let (model, rec) = makeModel()
        model.setQuery("hello")
        XCTAssertEqual(model.query, "hello")
        XCTAssertEqual(rec.searches, ["hello"])
        XCTAssertEqual(rec.clears, 0)
    }

    func testEmptyQueryClearsInsteadOfSearching() {
        let (model, rec) = makeModel()
        model.setQuery("hello")
        model.report(count: 3, index: 1)
        model.setQuery("")
        XCTAssertEqual(rec.clears, 1)
        XCTAssertEqual(model.matchCount, 0)
        XCTAssertEqual(model.currentIndex, 0)
        // No second search issued for the empty string.
        XCTAssertEqual(rec.searches, ["hello"])
    }

    func testReportUpdatesTally() {
        let (model, _) = makeModel()
        model.report(count: 5, index: 2)
        XCTAssertEqual(model.matchCount, 5)
        XCTAssertEqual(model.currentIndex, 2)
    }

    func testStepGuardsOnNoMatches() {
        let (model, rec) = makeModel()
        model.next()
        model.previous()
        XCTAssertTrue(rec.steps.isEmpty)
        model.report(count: 2, index: 1)
        model.next()
        model.previous()
        XCTAssertEqual(rec.steps, [1, -1])
    }

    func testActivateFocusesAndRerunsExistingQuery() {
        let (model, rec) = makeModel()
        model.setQuery("term")
        let focusBefore = model.focusRequest
        model.activate()
        XCTAssertTrue(model.isActive)
        XCTAssertEqual(model.focusRequest, focusBefore + 1)
        // The existing query is searched again on (re)activation.
        XCTAssertEqual(rec.searches, ["term", "term"])
    }

    func testActivateWithoutQueryDoesNotSearch() {
        let (model, rec) = makeModel()
        model.activate()
        XCTAssertTrue(model.isActive)
        XCTAssertTrue(rec.searches.isEmpty)
    }

    func testUseSelectionSeedsQuery() {
        let (model, rec) = makeModel()
        rec.selection = "  picked  "
        model.useSelectionForFind()
        XCTAssertTrue(model.isActive)
        XCTAssertEqual(model.query, "picked", "selection is trimmed before searching")
        XCTAssertEqual(rec.searches, ["picked"])
    }

    func testUseSelectionWithEmptySelectionJustActivates() {
        let (model, rec) = makeModel()
        rec.selection = "   "
        model.useSelectionForFind()
        XCTAssertTrue(model.isActive)
        XCTAssertTrue(model.query.isEmpty)
        XCTAssertTrue(rec.searches.isEmpty)
    }

    func testCloseClearsHighlightsButKeepsQuery() {
        let (model, rec) = makeModel()
        model.setQuery("keep")
        model.report(count: 4, index: 2)
        model.isActive = true
        model.close()
        XCTAssertFalse(model.isActive)
        XCTAssertEqual(model.matchCount, 0)
        XCTAssertEqual(model.currentIndex, 0)
        XCTAssertEqual(rec.clears, 1)
        // Query survives so reopening restores the last search.
        XCTAssertEqual(model.query, "keep")
    }
}
