# 驾驶舱路线段（roadmap）实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 第四本账 `docs/roadmap.md` + 驾驶舱第五分段「路线」，阶段进度渲染时从现状账派生（不落盘）。

**Architecture:** 沿驾驶舱既有形态扩展——`CockpitParser` 加纯函数解析（与 `parseStateFile` 同款裸字段行格式），`CockpitData` 加 `roadmap`，`CockpitView` 加 `Segment.roadmap` 路由到新文件 `CockpitRoadmapView.swift`；进度 = 条目 relpath 对现状账 `CockpitTopic.status` 的桶聚合，复用 `cockpitStatusBucket` / `CockpitUI.color` / `CockpitDistributionBar` / `spawnBrief`。**不建任何自动校验门**（reconcile-check 已撤回）：坏链只在 UI 渲警示色。

**Tech Stack:** Swift / SwiftUI (macOS)，XCTest；spec 见 `docs/superpowers/specs/2026-07-07-cockpit-roadmap-design.md`。

## Global Constraints

- 驾驶舱只是呈现+控制面：不判 drift、不自动排期、不自动翻阶段状态、进度不落盘（cockpit.md 边界）。
- 无自动断言/lefthook 门（2026-06-26 用户撤回 reconcile-check，见 docs/progress.md）。
- roadmap 账仓库级一份；阶段顺序 = 文件顺序；status 词表 `planned / doing / done / dropped`。
- 条目 relpath 坐标系 = `CockpitTopic.expectationRelpath`（`area/key`，相对 `docs/handbook/` 无扩展名）。
- 所有 UI 在 `#if os(macOS)` 内；颜色一律走 `Theme.Palette` / `CockpitUI.color`，不裸 hex。
- 提交小单元、每 task 一 commit，trailer `Co-Authored-By: Claude <noreply@anthropic.com>`。
- 测试/构建命令（在 `apps/pendingcrew/`）：
  - 测试：`xcodebuild -project PendingCrew.xcodeproj -scheme PendingCrew -destination 'platform=macOS' test -only-testing:PendingCrewTests/CockpitRoadmapParserTests`
  - 构建：`xcodebuild -project PendingCrew.xcodeproj -scheme PendingCrew -destination 'platform=macOS' build`

---

### Task 1: 解析 + 模型 + 进度派生（TDD）

**Files:**
- Modify: `apps/pendingcrew/Sources/Models/CockpitModel.swift`
- Test: `apps/pendingcrew/Tests/PendingCrewTests/CockpitRoadmapParserTests.swift`（新建）

**Interfaces:**
- Consumes: `CockpitTopic.expectationRelpath`、`cockpitStatusBucket(_:)`、`CockpitStats.StatusCount`、`CockpitParser` 私有 helpers `headingKey`/`field`（同 enum 内可用）。
- Produces（Task 2 依赖，签名精确）:
  - `struct CockpitPhaseEntry: Equatable { let relpath: String; let note: String }`
  - `struct CockpitPhase: Identifiable, Equatable { let name: String; let status: String; let target: String; let goal: String; let entries: [CockpitPhaseEntry]; var id: String { name } }`
  - `struct CockpitRoadmap: Equatable { let preamble: String; let phases: [CockpitPhase] }`
  - `CockpitParser.parseRoadmapFile(_ content: String) -> CockpitRoadmap`
  - `func cockpitPhaseProgress(_ phase: CockpitPhase, topics: [CockpitTopic]) -> [CockpitStats.StatusCount]`（含 `"unfiled"` 桶）
  - `CockpitData.roadmap: CockpitRoadmap?`（`CockpitLoader.load` 读 `docs/roadmap.md`，缺文件 = nil）

- [ ] **Step 1: 写失败测试**

新建 `apps/pendingcrew/Tests/PendingCrewTests/CockpitRoadmapParserTests.swift`：

```swift
import XCTest
@testable import PendingCrew

final class CockpitRoadmapParserTests: XCTestCase {
    let sample = """
    > 路线账。阶段按文件顺序排先后。

    当前主线:v1 收口。

    ## v1 收口
    status: doing
    target: 2026-08
    目标: 本地闭环全链路真机可用。
    - pendingcrew/concepts/cockpit — 路线段本身
    - pendingcrew/concepts/local-first

    ## v1.1 远端 runner
    status: planned
    目标: fly machine 开通。
    - pendingcrew/concepts/runtime-location-and-machine
    """

    func testParsePreambleAndPhases() {
        let r = CockpitParser.parseRoadmapFile(sample)
        XCTAssertTrue(r.preamble.contains("当前主线:v1 收口。"))
        XCTAssertTrue(r.preamble.contains("路线账"))
        XCTAssertEqual(r.phases.map(\.name), ["v1 收口", "v1.1 远端 runner"])
        let p1 = r.phases[0]
        XCTAssertEqual(p1.status, "doing")
        XCTAssertEqual(p1.target, "2026-08")
        XCTAssertEqual(p1.goal, "本地闭环全链路真机可用。")
        XCTAssertEqual(p1.entries, [
            CockpitPhaseEntry(relpath: "pendingcrew/concepts/cockpit", note: "路线段本身"),
            CockpitPhaseEntry(relpath: "pendingcrew/concepts/local-first", note: ""),
        ])
        XCTAssertEqual(r.phases[1].target, "")
        XCTAssertEqual(r.phases[1].entries.count, 1)
    }

    func testParseEmptyAndNoPhases() {
        XCTAssertEqual(CockpitParser.parseRoadmapFile("").phases.count, 0)
        let r = CockpitParser.parseRoadmapFile("只有一段话,没有阶段。")
        XCTAssertEqual(r.preamble, "只有一段话,没有阶段。")
        XCTAssertTrue(r.phases.isEmpty)
    }

    func testPhaseProgressBucketsAndUnfiled() {
        func topic(_ rel: String, _ status: String) -> CockpitTopic {
            let parts = rel.split(separator: "/", maxSplits: 1).map(String.init)
            return CockpitTopic(area: parts[0], key: parts[1], status: status,
                                summary: "", evidence: "", taskIds: [], taskRaw: "")
        }
        let phase = CockpitPhase(name: "x", status: "doing", target: "", goal: "", entries: [
            CockpitPhaseEntry(relpath: "a/one", note: ""),
            CockpitPhaseEntry(relpath: "a/two", note: ""),
            CockpitPhaseEntry(relpath: "a/three", note: ""),
        ])
        let dist = cockpitPhaseProgress(phase, topics: [topic("a/one", "done"), topic("a/two", "partial, pending-qa")])
        // a/three 无现状条 → unfiled;a/two 含 pending-qa → pending-qa 桶
        XCTAssertEqual(dist, [
            CockpitStats.StatusCount(bucket: "done", count: 1),
            CockpitStats.StatusCount(bucket: "pending-qa", count: 1),
            CockpitStats.StatusCount(bucket: "unfiled", count: 1),
        ])
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run（`apps/pendingcrew/`）: `xcodebuild -project PendingCrew.xcodeproj -scheme PendingCrew -destination 'platform=macOS' test -only-testing:PendingCrewTests/CockpitRoadmapParserTests`
Expected: 编译失败（`CockpitPhaseEntry` 等未定义）。

- [ ] **Step 3: 最小实现**

`CockpitModel.swift`——在 `CockpitStats` 定义之后、`cockpitStatusBucket` 附近加类型与进度派生：

```swift
/// 路线账(docs/roadmap.md,第四本账)——期望的时间切片。阶段顺序 = 文件顺序;
/// 进度不落盘,渲染时由 cockpitPhaseProgress 从现状账派生(spec 2026-07-07)。
struct CockpitPhaseEntry: Equatable {
    let relpath: String   // 期望页 relpath,同 CockpitTopic.expectationRelpath 坐标系
    let note: String      // " — " 后的备注,可空
}

struct CockpitPhase: Identifiable, Equatable {
    let name: String      // "## " 后的阶段名
    let status: String    // planned / doing / done / dropped(人拍板,captain 只提议)
    let target: String    // 可空,粗粒度时间锚,不做到期检测
    let goal: String      // 目标: 一句话
    let entries: [CockpitPhaseEntry]
    var id: String { name }
}

struct CockpitRoadmap: Equatable {
    let preamble: String  // 第一个 "## " 之前的 markdown 原文(主线声明)
    let phases: [CockpitPhase]
}

/// 阶段进度 = 条目在现状账里的 status 桶聚合(纯展示,不判 drift)。
/// 期望页没有现状条 → "unfiled" 桶(未入账,本身是信号)。
func cockpitPhaseProgress(_ phase: CockpitPhase, topics: [CockpitTopic]) -> [CockpitStats.StatusCount] {
    var m: [String: Int] = [:]
    for e in phase.entries {
        if let t = topics.first(where: { $0.expectationRelpath == e.relpath }) {
            m[cockpitStatusBucket(t.status), default: 0] += 1
        } else {
            m["unfiled", default: 0] += 1
        }
    }
    return ["done", "pending-qa", "partial", "planned", "dropped", "other", "unfiled"]
        .compactMap { k in m[k].map { CockpitStats.StatusCount(bucket: k, count: $0) } }
}
```

`CockpitParser` 内加（复用同 enum 的 `headingKey` / `field`）：

```swift
/// 解析 docs/roadmap.md。第一个 "## " 前是 preamble;每节 = 一阶段,
/// 字段裸行(status/target/目标),列表项 = 条目(relpath [— 备注])。
static func parseRoadmapFile(_ content: String) -> CockpitRoadmap {
    var preamble: [String] = []
    var phases: [CockpitPhase] = []
    var name: String?
    var status = "", target = "", goal = ""
    var entries: [CockpitPhaseEntry] = []
    func flush() {
        guard let n = name else { return }
        phases.append(CockpitPhase(name: n, status: status, target: target, goal: goal, entries: entries))
    }
    for line in content.components(separatedBy: "\n") {
        if let h = headingKey(line) {
            flush()
            name = h; status = ""; target = ""; goal = ""; entries = []
            continue
        }
        if name == nil { preamble.append(line); continue }
        if let v = field(line, "status") { status = v }
        else if let v = field(line, "target") { target = v }
        else if let v = field(line, "目标") { goal = v }
        else if let e = entryItem(line) { entries.append(e) }
    }
    flush()
    return CockpitRoadmap(
        preamble: preamble.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
        phases: phases)
}

/// "- <relpath>[ — <note>]" → 条目;其他行忽略。
private static func entryItem(_ line: String) -> CockpitPhaseEntry? {
    let t = line.trimmingCharacters(in: .whitespaces)
    guard t.hasPrefix("- ") else { return nil }
    let body = String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces)
    guard !body.isEmpty else { return nil }
    if let r = body.range(of: " — ") {
        return CockpitPhaseEntry(
            relpath: String(body[..<r.lowerBound]).trimmingCharacters(in: .whitespaces),
            note: String(body[r.upperBound...]).trimmingCharacters(in: .whitespaces))
    }
    return CockpitPhaseEntry(relpath: body, note: "")
}
```

`CockpitData` 加字段（放 `handbookDir` 之后）：

```swift
/// 路线账(docs/roadmap.md);文件不存在为 nil(路线段渲空态引导)。
var roadmap: CockpitRoadmap?
```

`CockpitLoader.load` 里、`return CockpitData(...)` 前加读取，并把 `roadmap:` 传入 init：

```swift
let roadmapFile = crewRoot.appendingPathComponent("docs/roadmap.md")
let roadmap = readString(roadmapFile).map(CockpitParser.parseRoadmapFile)
```

（`CockpitData` 是 struct 默认 memberwise init——`roadmap` 放最后一个参数，`CockpitView.reload` 无需改。）

- [ ] **Step 4: 跑测试确认通过**

Run: 同 Step 2 命令。Expected: `Test Suite 'CockpitRoadmapParserTests' passed`（3 tests）。

- [ ] **Step 5: Commit**

```bash
git add apps/pendingcrew/Sources/Models/CockpitModel.swift apps/pendingcrew/Tests/PendingCrewTests/CockpitRoadmapParserTests.swift
git commit -m "crew: 路线账解析 + 阶段进度派生(CockpitRoadmap, TDD)

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 2: 路线段 UI + dashboard「当前阶段」卡

**Files:**
- Create: `apps/pendingcrew/Sources/Mac/Views/CockpitRoadmapView.swift`
- Modify: `apps/pendingcrew/Sources/Mac/Views/CockpitView.swift`

**Interfaces:**
- Consumes: Task 1 全部类型；`CockpitNav`、`StatusBadge`、`CockpitUI.color`、`MarkdownText(text:variant:)`、`CockpitLoader.readExpectation`、`Theme.Palette`。
- Produces: `struct CockpitRoadmapSegment: View`（init: `data: CockpitData, nav: (CockpitNav) -> Void, onSpawnBrief: (CockpitTopic) -> Void`）。

- [ ] **Step 1: CockpitView 改造**

`CockpitView.swift`：

1. `Segment` enum 加 case（紧跟 dashboard）：`case dashboard = "总览", roadmap = "路线", expectation = "期望", state = "现状", tasks = "任务"`；icon switch 加 `case .roadmap: return "map"`。
2. `content` 路由加：

```swift
case .roadmap:
    CockpitRoadmapSegment(data: data, nav: handleNav, onSpawnBrief: spawnBrief)
```

3. dashboard 行改为传开路线段闭包：

```swift
case .dashboard:
    CockpitDashboard(data: data, detail: crewStore.selectedDetail, nav: handleNav,
                     openRoadmap: { segment = .roadmap })
```

4. `CockpitDashboard` 加属性 `let openRoadmap: () -> Void`，`body` 的 `VStack` 顶部（`statCards` 之前）插入：

```swift
if let roadmap = data.roadmap,
   let current = roadmap.phases.first(where: { cockpitStatusBucket($0.status) == "partial" }) {
    currentPhaseCard(current)
}
```

并在 struct 内加：

```swift
/// 「当前阶段」摘要卡 —— 第一个 doing 阶段 + 派生进度,点击去路线段。
private func currentPhaseCard(_ phase: CockpitPhase) -> some View {
    Button(action: openRoadmap) {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "map").foregroundStyle(Theme.Palette.accent)
                Text("当前阶段").font(.caption.weight(.semibold)).foregroundStyle(Theme.Palette.inkMuted)
                Text(phase.name).font(.callout.weight(.semibold)).foregroundStyle(Theme.Palette.ink)
                if !phase.target.isEmpty {
                    Text(phase.target).font(.caption2.monospaced()).foregroundStyle(Theme.Palette.inkMuted)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(Theme.Palette.inkMuted)
            }
            if !phase.goal.isEmpty {
                Text(phase.goal).font(.caption).foregroundStyle(Theme.Palette.inkMuted).lineLimit(1)
            }
            CockpitDistributionBar(dist: cockpitPhaseProgress(phase, topics: data.topics))
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
}
```

5. `CockpitDistributionBar` 的 `private` 去掉（改 internal，供新文件复用），注释注明。

- [ ] **Step 2: 新建 CockpitRoadmapView.swift**

```swift
#if os(macOS)
import SwiftUI

/// 路线段 —— 渲染第四本账 docs/roadmap.md(阶段骨架人写、进度从现状账实时派生)。
/// 纯呈现 + 复用控制半边:非 done 条目一步生 session 补差;坏链渲警示色靠人读,无自动断言。
struct CockpitRoadmapSegment: View {
    let data: CockpitData
    let nav: (CockpitNav) -> Void
    let onSpawnBrief: (CockpitTopic) -> Void

    var body: some View {
        if let roadmap = data.roadmap {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !roadmap.preamble.isEmpty {
                        MarkdownText(text: roadmap.preamble, variant: .article)
                    }
                    ForEach(roadmap.phases) { phase in phaseCard(phase) }
                }
                .padding(20)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(Theme.Palette.canvas)
        } else {
            emptyGuide
        }
    }

    // MARK: 阶段卡

    private func phaseCard(_ phase: CockpitPhase) -> some View {
        let dist = cockpitPhaseProgress(phase, topics: data.topics)
        let done = dist.first(where: { $0.bucket == "done" })?.count ?? 0
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                StatusBadge(raw: phase.status)
                Text(phase.name).font(.headline)
                if !phase.target.isEmpty {
                    Text(phase.target).font(.caption.monospaced()).foregroundStyle(Theme.Palette.inkMuted)
                }
                Spacer(minLength: 8)
                Text("\(done)/\(phase.entries.count) done")
                    .font(.caption2.monospaced()).foregroundStyle(Theme.Palette.inkMuted)
            }
            if !phase.goal.isEmpty {
                Text(phase.goal).font(.callout).foregroundStyle(Theme.Palette.inkMuted)
            }
            if !phase.entries.isEmpty {
                CockpitDistributionBar(dist: dist)
                VStack(spacing: 0) {
                    ForEach(Array(phase.entries.enumerated()), id: \.offset) { idx, entry in
                        entryRow(entry)
                        if idx < phase.entries.count - 1 { Divider() }
                    }
                }
                .background(Theme.Palette.surfaceMuted, in: RoundedRectangle(cornerRadius: 10))
            } else {
                Text("（此阶段还没挂期望页）").font(.caption).foregroundStyle(Theme.Palette.inkMuted)
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: 条目行

    private func entryRow(_ entry: CockpitPhaseEntry) -> some View {
        let topic = data.topics.first { $0.expectationRelpath == entry.relpath }
        let pageExists = FileManager.default.fileExists(
            atPath: data.handbookDir.appendingPathComponent("\(entry.relpath).md").path)
        let bucket = topic.map { cockpitStatusBucket($0.status) } ?? "unfiled"
        return HStack(alignment: .center, spacing: 10) {
            Button { nav(.topic(entry.relpath)) } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.relpath).font(.system(.callout, design: .monospaced)).lineLimit(1)
                            .foregroundStyle(pageExists ? Theme.Palette.ink : Theme.Palette.danger)
                        if !entry.note.isEmpty {
                            Text(entry.note).font(.caption2).foregroundStyle(Theme.Palette.inkMuted).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    if !pageExists {
                        // 坏链:期望页不存在。纯呈现警示,靠人读后手改 roadmap(无自动断言)。
                        Text("期望页不存在").font(.caption2)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Theme.Palette.danger.opacity(0.18), in: Capsule())
                            .foregroundStyle(Theme.Palette.danger)
                    } else if let topic {
                        StatusBadge(raw: topic.status)
                        Text(topic.summary).font(.caption).foregroundStyle(Theme.Palette.inkMuted)
                            .lineLimit(1).frame(maxWidth: 260, alignment: .trailing)
                    } else {
                        Text("未入账").font(.caption2)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Theme.Palette.inkMuted.opacity(0.15), in: Capsule())
                            .foregroundStyle(Theme.Palette.inkMuted)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if pageExists, bucket != "done" {
                Button { onSpawnBrief(topic ?? syntheticTopic(entry.relpath)) } label: {
                    Image(systemName: "bolt.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.Palette.accent)
                .help("把这条期望当 brief,生 session 补差")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    /// 期望页还没入现状账时,合成一个空 topic 供 spawnBrief 组 brief(期望原文照读)。
    private func syntheticTopic(_ relpath: String) -> CockpitTopic {
        let parts = relpath.split(separator: "/", maxSplits: 1).map(String.init)
        return CockpitTopic(
            area: parts.first ?? relpath, key: parts.count > 1 ? parts[1] : "",
            status: "", summary: "(未入账——期望还没进现状账)",
            evidence: "", taskIds: [], taskRaw: "")
    }

    // MARK: 空态引导

    private var emptyGuide: some View {
        VStack(spacing: 14) {
            Spacer()
            Text("这个仓库还没有路线账").font(.headline)
            Text("在仓库根建 docs/roadmap.md(人定骨架:主线 + 阶段;captain 填血肉)。格式:")
                .font(.caption).foregroundStyle(Theme.Palette.inkMuted)
            Text("""
            > 路线账。阶段按文件顺序排先后。

            当前主线一段话。

            ## v1 收口
            status: doing
            target: 2026-08
            目标: 一句话阶段目标。
            - pendingcrew/concepts/cockpit — 备注可选
            """)
            .font(.caption.monospaced())
            .padding(12)
            .background(Theme.Palette.surfaceMuted, in: RoundedRectangle(cornerRadius: 10))
            .frame(maxWidth: 460)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Palette.canvas)
    }
}
#endif
```

- [ ] **Step 3: 构建验证**

Run（`apps/pendingcrew/`）: `xcodebuild -project PendingCrew.xcodeproj -scheme PendingCrew -destination 'platform=macOS' build`
Expected: BUILD SUCCEEDED。（新 .swift 文件：project.yml 用目录通配，跑 `xcodegen` 后再 build。）

- [ ] **Step 4: Commit**

```bash
git add apps/pendingcrew/Sources/Mac/Views/CockpitRoadmapView.swift apps/pendingcrew/Sources/Mac/Views/CockpitView.swift apps/pendingcrew/PendingCrew.xcodeproj
git commit -m "crew: 驾驶舱第五分段「路线」+ 总览当前阶段卡

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 3: 账本落地 —— docs/roadmap.md 首版 + 世界观 prompt + handbook 回写

**Files:**
- Create: `docs/roadmap.md`
- Modify: `apps/pendingcrew/Resources/Prompts/session-world-model.zh.md`、`session-world-model.en.md`（追加静态小节，无新占位符 → renderer 不用动）
- Modify: `docs/handbook/pendingcrew/concepts/cockpit.md`、`docs/handbook/pendingcrew/concepts/reconciliation.md`（补 roadmap 概念）
- Modify: `docs/state/pendingcrew.md`（concepts/cockpit 现状条刷新）
- Create: `docs/tasks/<yyyymmdd>-<xx>.md`（本 feature 的 task 条目，id 用当天日期）

**Interfaces:**
- Consumes: Task 1 的账本格式定义（spec §账本格式）。
- Produces: 驾驶舱可渲染的真实 `docs/roadmap.md`。

- [ ] **Step 1: 写 docs/roadmap.md 首版**

骨架从现状账（`docs/state/*.md`）与 `docs/progress.md` 的实际推进现状提炼：preamble 写 v1 主线（本地为家收口，链接 `docs/handbook/pendingcrew/vision.md`）；阶段建议：`v1 收口`（doing：cockpit / local-first / session-and-world-model / human-in-the-loop / crew / captain / async-delegation 等当前 partial 页）、`v1.1 远端与云`（planned：runtime-location-and-machine 等）、`v2 治理与规模`（planned：governance / dag-and-responsibility 深水区）。条目 relpath 必须逐一对照 `docs/handbook/` 真实文件核对存在。

- [ ] **Step 2: 世界观 prompt 追加「路线账」小节**

两个语言文件末尾（zh 为准，en 对应翻译）追加：

```markdown
## 路线账(roadmap)

仓库根可能有 `docs/roadmap.md`(第四本账:阶段骨架 + 条目挂期望页;阶段顺序 = 文件顺序)。纪律:

- **人定骨架,你填血肉**:不改开头主线声明、不动阶段划分与顺序、不自己翻阶段 status。
- 刷现状账的同一拍看一眼 roadmap:你刚落的期望页若不在任何阶段,把它归入当前 `status: doing` 的阶段(拿不准就 ask 人)。
- 某阶段条目全绿时,向人**提议**翻阶段 status,不自己翻。
- (captain)派活优先从当前 doing 阶段的非 done 条目里挑 brief。
```

- [ ] **Step 3: handbook 回写 + 现状条 + task 条目**

- `cockpit.md`「用在哪·长什么样」加一条:「**路线段**:渲染 `docs/roadmap.md`(第四本账);阶段进度由现状账实时派生不落盘;非 done 条目一步生 session」;「边界」加:「路线账无自动断言——坏链渲警示色靠人读(reconcile-check 已撤回的定调不变)」。
- `reconciliation.md` 三本账处补一句:「另有**路线账** `docs/roadmap.md`(期望的时间切片:先要哪块、走到哪了);进度是现状账的派生投影,不独立记进度」。
- `docs/state/pendingcrew.md` 的 `## concepts/cockpit` 条:现状/证据句子补路线段(status 保持 `partial, pending-qa`,GUI 活验归 20260626-qa)。
- 新建 `docs/tasks/<yyyymmdd>-<xx>.md`(frontmatter 按 docs/tasks/README.md 格式,status: pending-qa,expects: [pendingcrew/concepts/cockpit],state: [pendingcrew/concepts/cockpit])。

- [ ] **Step 4: Commit**

```bash
git add docs/roadmap.md apps/pendingcrew/Resources/Prompts/session-world-model.zh.md apps/pendingcrew/Resources/Prompts/session-world-model.en.md docs/handbook/pendingcrew/concepts/cockpit.md docs/handbook/pendingcrew/concepts/reconciliation.md docs/state/pendingcrew.md docs/tasks/
git commit -m "docs: 路线账首版 + 世界观 roadmap 纪律 + handbook/现状/task 回写

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 4: 整体验证 + 账本 + 合 main

**Files:**
- Modify: `docs/progress.md`（新条目）
- 可能 Modify: 修复项

- [ ] **Step 1: 全量测试**

Run（`apps/pendingcrew/`）: `xcodebuild -project PendingCrew.xcodeproj -scheme PendingCrew -destination 'platform=macOS' test`
Expected: 全绿（既有 300+ 测试不回归）。

- [ ] **Step 2: GUI 自查（best-effort）**

启动构建产物，选一个工作目录指向本仓库的 crew，进驾驶舱看路线段渲染真 roadmap.md（阶段卡/进度条/未入账灰标/跨账跳转）。被动 screenshot 核对；起不了就记入 20260626-qa 批次，不阻塞合并。

- [ ] **Step 3: 账本更新**

`docs/progress.md` 顶部加条目（日期 2026-07-07，路线段 + 第四本账 + 真机活验尾巴归 #443/20260626-qa）；内置 TaskList 翻 #472 completed。

- [ ] **Step 4: 合 main**

```bash
git rebase main   # 分支未推过
cd <主worktree> && git checkout main 不可行 —— 按 CLAUDE.md 用 git -C 主worktree路径 merge --no-ff feat/cockpit-roadmap -m "Merge feat/cockpit-roadmap — 驾驶舱路线段(第四本账 docs/roadmap.md + 进度派生)"
```

多 commit 特性 → `--no-ff` 保留边界。合并后不删 worktree/分支（用户自己清）、不 push。

---

## Self-Review 记录

- Spec 覆盖：账本格式(T3)、进度派生(T1)、模型解析(T1)、路线段 UI+dashboard 卡(T2)、spawnBrief 复用(T2)、坏链警示(T2)、世界观纪律(T3)、handbook 回写(T3)、验证(T4)。无遗漏。
- 无占位符;类型签名 T1↔T2 一致(`CockpitRoadmapSegment(data:nav:onSpawnBrief:)`、`cockpitPhaseProgress(_:topics:)`)。
- `CockpitData` memberwise init 加了 `roadmap` 参数——`CockpitLoader.load` 是唯一构造点(已在 T1 改),测试里不直接构造 CockpitData,不破。
