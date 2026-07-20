import Testing
import Foundation
@testable import EditMD

@Suite("Document history Back/Forward")
@MainActor
struct DocumentHistoryTests {

    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/vault/\(name).md")
    }

    @Test("Visits build a browser-style back stack")
    func recordsVisits() {
        let h = DocumentHistory(observingWindows: false)
        #expect(!h.canGoBack && !h.canGoForward)

        h.recordVisit(url("a"))
        #expect(!h.canGoBack)
        h.recordVisit(url("b"))
        #expect(h.canGoBack && !h.canGoForward)

        var landed: URL?
        h.goBack { landed = $0.url }
        #expect(landed == url("a"))
        #expect(h.canGoForward)
    }

    @Test("Re-recording the current file is not a new visit")
    func dedupCurrent() {
        let h = DocumentHistory(observingWindows: false)
        h.recordVisit(url("a"))
        h.recordVisit(url("a"))
        #expect(!h.canGoBack)
    }

    @Test("A new visit truncates the forward tail")
    func truncatesForwardTail() {
        let h = DocumentHistory(observingWindows: false)
        h.recordVisit(url("a"))
        h.recordVisit(url("b"))
        h.recordVisit(url("c"))
        h.goBack { _ in }            // now at b, forward = c
        h.recordVisit(url("d"))      // replaces the forward tail
        #expect(!h.canGoForward)

        var landed: URL?
        h.goBack { landed = $0.url }
        #expect(landed == url("b"))
    }

    @Test("Back restores the caret offset the reader left behind")
    func restoresOffset() {
        let h = DocumentHistory(observingWindows: false)
        var caret = 0
        h.currentOffsetProvider = { caret }

        h.recordVisit(url("a"))
        caret = 240                  // reader scrolled/clicked deep in A
        h.recordVisit(url("b"))      // leaving A stamps offset 240

        var back: DocumentHistory.Visit?
        h.goBack { back = $0 }
        #expect(back?.url == url("a"))
        #expect(back?.offset == 240)
    }

    @Test("Forward remembers where Back was pressed")
    func stampsOnNavigate() {
        let h = DocumentHistory(observingWindows: false)
        var caret = 0
        h.currentOffsetProvider = { caret }

        h.recordVisit(url("a"))
        h.recordVisit(url("b"))
        caret = 99                   // reader is deep in B
        h.goBack { _ in }            // leaving B stamps offset 99

        var fwd: DocumentHistory.Visit?
        h.goForward { fwd = $0 }
        #expect(fwd?.url == url("b"))
        #expect(fwd?.offset == 99)
    }
}
