import XCTest
@testable import EditMD

final class AgentActivityTests: XCTestCase {

    func testPromptPaletteWithOpenMarks() {
        let ctx = AgentPromptContext(
            activeFilePath: "/vault/a.md",
            workspaceRootPath: "/vault",
            openMarkCount: 2,
            agentLaunchCommand: "cd '/vault' && claude -p \"/smotr -pr\"",
            ideConnected: false
        )
        let items = buildAgentPromptItems(ctx)
        XCTAssertTrue(items.contains { $0.id == "process-queue" })
        XCTAssertTrue(items.contains { $0.id == "review-file" })
        XCTAssertTrue(items.contains { $0.id == "connect-editmd" })
        let queue = items.first { $0.id == "process-queue" }!
        XCTAssertTrue(queue.command.contains("claude"))
        // The vault-graph prompt teaches «ask EditMD, don't walk».
        let vault = items.first { $0.id == "vault-graph" }
        XCTAssertNotNil(vault)
        XCTAssertTrue(vault!.command.contains("editmdctl index status"))
        XCTAssertTrue(vault!.command.contains("Do NOT"))
    }

    func testPromptPaletteEmptyStartsInstall() {
        let ctx = AgentPromptContext(
            activeFilePath: nil,
            workspaceRootPath: nil,
            openMarkCount: 0,
            agentLaunchCommand: "claude -p \"/smotr -pr\"",
            ideConnected: true
        )
        let items = buildAgentPromptItems(ctx)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].id, "install-start")
    }

    func testHarnessStatusEnumRawValues() {
        XCTAssertEqual(AgentHarnessStatus.active.rawValue, "active")
        XCTAssertEqual(AgentHarnessStatus(rawValue: "blocked"), .blocked)
        XCTAssertNil(AgentHarnessStatus(rawValue: "nope"))
    }

    @MainActor
    func testApplyHarnessStatusUpdatesModel() {
        let model = AgentActivityModel.shared
        model.applyHarnessStatus(.active, label: "thinking", harness: "codex")
        XCTAssertEqual(model.harnessStatus, .active)
        XCTAssertEqual(model.harnessLabel, "thinking")
        XCTAssertEqual(model.harnessName, "codex")
        model.applyHarnessStatus(.idle, label: "", harness: "codex")
        XCTAssertEqual(model.harnessStatus, .idle)
    }
}
