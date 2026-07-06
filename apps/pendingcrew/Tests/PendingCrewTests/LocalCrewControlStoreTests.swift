import XCTest

final class LocalCrewControlStoreTests: XCTestCase {
    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("crewctl-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func testRequestThenPeek() {
        let s = LocalCrewControlStore(directory: tempDir())
        s.requestRename(crewId: "local-abc", name: "鉴权重构")
        XCTAssertEqual(s.pendingRename(crewId: "local-abc"), "鉴权重构")
    }

    func testRequestTrimsAndRejectsEmpty() {
        let s = LocalCrewControlStore(directory: tempDir())
        s.requestRename(crewId: "c", name: "  深色模式  ")
        XCTAssertEqual(s.pendingRename(crewId: "c"), "深色模式")
        s.requestRename(crewId: "blank", name: "   \n  ")
        XCTAssertNil(s.pendingRename(crewId: "blank"))
    }

    func testDrainReturnsAndDeletes() {
        let s = LocalCrewControlStore(directory: tempDir())
        s.requestRename(crewId: "local-abc", name: "语音重连")
        let drained = s.drainRenames()
        XCTAssertEqual(drained.count, 1)
        XCTAssertEqual(drained[0].crewId, "local-abc")
        XCTAssertEqual(drained[0].title, "语音重连")
        // 排空后文件已删 —— 再 drain / peek 为空。
        XCTAssertNil(s.pendingRename(crewId: "local-abc"))
        XCTAssertTrue(s.drainRenames().isEmpty)
    }

    func testLastWriteWins() {
        let s = LocalCrewControlStore(directory: tempDir())
        s.requestRename(crewId: "c", name: "旧名")
        s.requestRename(crewId: "c", name: "新名")
        let drained = s.drainRenames()
        XCTAssertEqual(drained.count, 1)
        XCTAssertEqual(drained[0].title, "新名")
    }

    func testCrewsIsolated() {
        let s = LocalCrewControlStore(directory: tempDir())
        s.requestRename(crewId: "local-a", name: "甲")
        s.requestRename(crewId: "local-b", name: "乙")
        let map = Dictionary(uniqueKeysWithValues: s.drainRenames().map { ($0.crewId, $0.title) })
        XCTAssertEqual(map["local-a"], "甲")
        XCTAssertEqual(map["local-b"], "乙")
    }

    func testPersistsAcrossInstances() {
        let dir = tempDir()
        LocalCrewControlStore(directory: dir).requestRename(crewId: "c", name: "持久")
        XCTAssertEqual(LocalCrewControlStore(directory: dir).pendingRename(crewId: "c"), "持久")
    }

    func testEnqueueStartSessionThenDrain() {
        let s = LocalCrewControlStore(directory: tempDir())
        s.enqueueStartSession(crewId: "local-a", brief: "修登录", runner: "claude", isolation: true)
        let cmds = s.drainCommands()
        XCTAssertEqual(cmds.count, 1)
        XCTAssertEqual(cmds[0].kind, "start_session")
        XCTAssertEqual(cmds[0].crewId, "local-a")
        XCTAssertEqual(cmds[0].brief, "修登录")
        XCTAssertEqual(cmds[0].runner, "claude")
        XCTAssertEqual(cmds[0].isolation, true)
        // 排空后再 drain 为空(文件已删)
        XCTAssertTrue(s.drainCommands().isEmpty)
    }

    func testEnqueueMultipleCommandsAllDrained() {
        let s = LocalCrewControlStore(directory: tempDir())
        s.enqueueStartSession(crewId: "c", brief: "活一", runner: nil, isolation: nil)
        s.enqueueStartSession(crewId: "c", brief: "活二", runner: "codex", isolation: false)
        s.enqueueCreateChildCrew(crewId: "c", brief: "拆一块", title: "支付")
        let cmds = s.drainCommands()
        XCTAssertEqual(cmds.count, 3)
        XCTAssertEqual(cmds.filter { $0.kind == "start_session" }.count, 2)
        XCTAssertEqual(cmds.filter { $0.kind == "create_child_crew" }.count, 1)
        XCTAssertEqual(cmds.first { $0.kind == "create_child_crew" }?.title, "支付")
    }

    func testEnqueueRejectsEmptyBrief() {
        let s = LocalCrewControlStore(directory: tempDir())
        s.enqueueStartSession(crewId: "c", brief: "   \n ", runner: nil, isolation: nil)
        s.enqueueCreateChildCrew(crewId: "c", brief: "", title: nil)
        XCTAssertTrue(s.drainCommands().isEmpty)
    }

    // MARK: - Attention（raise_attention / clear_attention → 侧栏黄点）

    func testRequestAttentionThenPeek() {
        let s = LocalCrewControlStore(directory: tempDir())
        s.requestAttention(crewId: "local-abc", reason: "需要人类拍板部署时机")
        XCTAssertEqual(s.pendingAttention(crewId: "local-abc")?.reason, "需要人类拍板部署时机")
    }

    func testRequestAttentionTrimsAndRejectsEmpty() {
        let s = LocalCrewControlStore(directory: tempDir())
        s.requestAttention(crewId: "c", reason: "  额度到顶了  ")
        XCTAssertEqual(s.pendingAttention(crewId: "c")?.reason, "额度到顶了")
        s.requestAttention(crewId: "blank", reason: "   \n  ")
        XCTAssertNil(s.pendingAttention(crewId: "blank"))
    }

    func testClearAttentionWritesNilReason() {
        let s = LocalCrewControlStore(directory: tempDir())
        s.requestClearAttention(crewId: "c")
        let pending = s.pendingAttention(crewId: "c")
        XCTAssertNotNil(pending)       // clear 也是一条待应用变更
        XCTAssertNil(pending?.reason)  // reason nil = 熄灭
    }

    func testDrainAttentionsReturnsAndDeletes() {
        let s = LocalCrewControlStore(directory: tempDir())
        s.requestAttention(crewId: "local-abc", reason: "卡在权限上")
        let drained = s.drainAttentions()
        XCTAssertEqual(drained.count, 1)
        XCTAssertEqual(drained[0].crewId, "local-abc")
        XCTAssertEqual(drained[0].reason, "卡在权限上")
        // 排空后文件已删 —— 再 drain / peek 为空。
        XCTAssertNil(s.pendingAttention(crewId: "local-abc"))
        XCTAssertTrue(s.drainAttentions().isEmpty)
    }

    // raise 后 clear：last-write-wins 只留最后的熄灭态。
    func testAttentionLastWriteWinsRaiseThenClear() {
        let s = LocalCrewControlStore(directory: tempDir())
        s.requestAttention(crewId: "c", reason: "有问题")
        s.requestClearAttention(crewId: "c")
        let drained = s.drainAttentions()
        XCTAssertEqual(drained.count, 1)
        XCTAssertNil(drained[0].reason)
    }

    func testAttentionAndRenameDoNotInterfere() {
        let s = LocalCrewControlStore(directory: tempDir())
        s.requestRename(crewId: "c", name: "起个名")
        s.requestAttention(crewId: "c", reason: "要人看")
        // drainAttentions 只拿 attention,不碰 rename;反之亦然。
        XCTAssertEqual(s.drainAttentions().count, 1)
        XCTAssertEqual(s.pendingRename(crewId: "c"), "起个名")
        XCTAssertEqual(s.drainRenames().count, 1)
        XCTAssertTrue(s.drainAttentions().isEmpty)
    }

    func testAttentionPersistsAcrossInstances() {
        let dir = tempDir()
        LocalCrewControlStore(directory: dir).requestAttention(crewId: "c", reason: "持久")
        XCTAssertEqual(LocalCrewControlStore(directory: dir).pendingAttention(crewId: "c")?.reason, "持久")
    }

    func testCommandsAndRenamesDoNotInterfere() {
        let s = LocalCrewControlStore(directory: tempDir())
        s.requestRename(crewId: "c", name: "起个名")
        s.enqueueStartSession(crewId: "c", brief: "干活", runner: nil, isolation: nil)
        // drainCommands 只拿命令,不碰 rename
        XCTAssertEqual(s.drainCommands().count, 1)
        XCTAssertEqual(s.pendingRename(crewId: "c"), "起个名")
        // drainRenames 只拿 rename,不碰命令(命令已被上面 drain 掉,这里重造一条验证隔离)
        s.enqueueStartSession(crewId: "c", brief: "再干", runner: nil, isolation: nil)
        XCTAssertEqual(s.drainRenames().count, 1)
        XCTAssertEqual(s.drainCommands().count, 1)
    }
}
