import XCTest
// AgentQuota.swift 直接编进 PendingCrewTests target。

/// 额度解析单测（#455 批 P4）：claude `/usage` 文本 + codex rollout rate_limits。
/// fixture 均取自 2026-07-05 本机实测输出（非臆造）。
final class AgentQuotaTests: XCTestCase {

    // MARK: - claude /usage 文本

    func testClaudeUsageParsesAllWindows() {
        let text = """
        Current session: 80% used · resets Jul 5 at 4:39am (Asia/Shanghai)
        Current week (all models): 23% used · resets Jul 5 at 10:59am (Asia/Shanghai)
        Current week (Fable): 18% used · resets Jul 5 at 10:59am (Asia/Shanghai)
        Last 24h · 758 requests · 4 sessions
        """
        let snap = ClaudeUsageTextParser.parse(text)
        XCTAssertEqual(snap?.agent, "claude")
        XCTAssertEqual(snap?.windows.count, 3)
        XCTAssertEqual(snap?.windows[0].label, "session")
        XCTAssertEqual(snap?.windows[0].usedPercent, 80)
        XCTAssertEqual(snap?.windows[0].resetsAt, "Jul 5 at 4:39am (Asia/Shanghai)")
        XCTAssertEqual(snap?.windows[1].label, "周(全模型)")
        XCTAssertEqual(snap?.windows[2].label, "周(Fable)")
        XCTAssertEqual(snap?.summary, "session 80% · 周(全模型) 23% · 周(Fable) 18%")
    }

    func testClaudeUsageNoMatchReturnsNil() {
        XCTAssertNil(ClaudeUsageTextParser.parse("Last 24h · 5 requests\nnothing here"))
        XCTAssertNil(ClaudeUsageTextParser.parse(""))
    }

    func testClaudeUnknownWindowLabelKeptVerbatim() {
        let snap = ClaudeUsageTextParser.parse("Some new window: 5% used · resets soon")
        XCTAssertEqual(snap?.windows.first?.label, "Some new window")
        XCTAssertEqual(snap?.windows.first?.usedPercent, 5)
    }

    // MARK: - codex rollout rate_limits

    func testCodexRolloutParsesLatestRateLimits() {
        let jsonl = """
        {"timestamp":"t1","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":5.0,"window_minutes":300,"resets_at":1782030455},"secondary":{"used_percent":15.0,"window_minutes":10080,"resets_at":1782380334},"plan_type":"prolite"}}}
        {"timestamp":"t2","type":"event_msg","payload":{"type":"other"}}
        {"timestamp":"t3","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":9.0,"window_minutes":300,"resets_at":1782030455},"secondary":{"used_percent":16.0,"window_minutes":10080,"resets_at":1782380334},"plan_type":"prolite"}}}
        """
        let snap = CodexRolloutQuotaParser.parse(jsonl)
        XCTAssertEqual(snap?.agent, "codex")
        // 取最后一条（最新）：9% / 16%。
        XCTAssertEqual(snap?.windows.map(\.usedPercent), [9, 16])
        XCTAssertEqual(snap?.windows.map(\.label), ["5小时窗", "周窗"])
        XCTAssertNotNil(snap?.windows[0].resetsAt)
    }

    func testCodexRolloutSecondaryNullStillParses() {
        // free 计划实测 secondary 可为 null。
        let jsonl = """
        {"payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":3.0,"window_minutes":10080,"resets_at":1783787895},"secondary":null,"plan_type":"free"}}}
        """
        let snap = CodexRolloutQuotaParser.parse(jsonl)
        XCTAssertEqual(snap?.windows.count, 1)
        XCTAssertEqual(snap?.windows[0].label, "周窗")
        XCTAssertEqual(snap?.windows[0].usedPercent, 3)
    }

    func testCodexRolloutNoRateLimitsReturnsNil() {
        XCTAssertNil(CodexRolloutQuotaParser.parse("{\"payload\":{\"type\":\"token_count\"}}"))
        XCTAssertNil(CodexRolloutQuotaParser.parse(""))
    }

    // MARK: - 窗口取值（侧栏四段显示 / 自动挂钩用）

    func testFiveHourAndWeeklyWindowSelection() {
        let claude = ClaudeUsageTextParser.parse("""
        Current session: 80% used · resets Jul 5 at 4:39am (Asia/Shanghai)
        Current week (all models): 23% used · resets Jul 5 at 10:59am (Asia/Shanghai)
        Current week (Fable): 18% used · resets Jul 5 at 10:59am (Asia/Shanghai)
        """)
        XCTAssertEqual(claude?.fiveHourWindow?.usedPercent, 80)
        XCTAssertEqual(claude?.weeklyWindow?.usedPercent, 23)   // 全模型总窗,非 Fable 分窗
        let codex = CodexRolloutQuotaParser.parse("""
        {"payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":9.0,"window_minutes":300,"resets_at":1782030455},"secondary":{"used_percent":16.0,"window_minutes":10080,"resets_at":1782380334}}}}
        """)
        XCTAssertEqual(codex?.fiveHourWindow?.usedPercent, 9)
        XCTAssertEqual(codex?.weeklyWindow?.usedPercent, 16)
    }

    // MARK: - claude 重置时刻人话解析（撞墙自动挂钩用）

    func testClaudeResetTimeParsesWithTimezone() throws {
        // now = 2026-07-04 18:00 UTC；"Jul 5 at 4:39am (Asia/Shanghai)" =
        // 2026-07-04 20:39 UTC —— 未来最近年份推断应取 2026。
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = cal.date(from: DateComponents(year: 2026, month: 7, day: 4, hour: 18))!
        let d = try XCTUnwrap(ClaudeResetTimeParser.parse("Jul 5 at 4:39am (Asia/Shanghai)", now: now))
        var sh = Calendar(identifier: .gregorian)
        sh.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let parts = sh.dateComponents([.year, .month, .day, .hour, .minute], from: d)
        XCTAssertEqual([parts.year, parts.month, parts.day, parts.hour, parts.minute],
                       [2026, 7, 5, 4, 39])
        XCTAssertGreaterThan(d, now)
    }

    func testClaudeResetTimeYearRollover() throws {
        // 12 月底看 "Jan 2 at 3pm" → 应推断成明年,不是今年一月(已过去)。
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = cal.date(from: DateComponents(year: 2026, month: 12, day: 30))!
        let d = try XCTUnwrap(ClaudeResetTimeParser.parse("Jan 2 at 3pm (UTC)", now: now))
        XCTAssertEqual(cal.component(.year, from: d), 2027)
    }

    func testClaudeResetTimeGarbageReturnsNil() {
        XCTAssertNil(ClaudeResetTimeParser.parse("soon-ish"))
        XCTAssertNil(ClaudeResetTimeParser.parse(""))
    }

    // MARK: - snapshot codec（quota.json 给 helper get_quota 读）

    func testSnapshotRoundTripsThroughJSON() throws {
        let snap = AgentQuotaSnapshot(
            agent: "claude",
            windows: [AgentQuotaWindow(label: "session", usedPercent: 80, resetsAt: "soon")],
            fetchedAt: "2026-07-05T01:00:00Z")
        let data = try JSONEncoder().encode(snap)
        let back = try JSONDecoder().decode(AgentQuotaSnapshot.self, from: data)
        XCTAssertEqual(back, snap)
    }
}
