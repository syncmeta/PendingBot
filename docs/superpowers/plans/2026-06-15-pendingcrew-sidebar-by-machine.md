# PendingCrew 侧栏按 machine 组织 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 Mac 侧栏从「Crew 平铺树 + 死占位 Machines」改成按机器分组（每台机器一组、crew 挂其下），并把多机器读取链路真正接通。

**Architecture:** 机器是账号概念走 edge（登录时真注册本机 + 真拉 `GET /v1/machines`，绕开 crew backend）；crew 仍本地优先（Mac = `LocalBackend`，本机 crew 全归「本机」组）。其它机器是真机器但其 crew 内容不在 Mac 上（local-first，无 edge-mirror）→ 显示为「遥控查看（稍后）」。分组用一个纯函数 helper（可单测）。

**Tech Stack:** Swift / SwiftUI（macOS），XCTest，xcodegen。前置 spec：`docs/superpowers/specs/2026-06-15-pendingcrew-sidebar-by-machine-design.md`。

**所有命令的工作目录：** `/Users/hey/Untitled/Pendingname/PendingBot/dev/.claude/worktrees/musing-montalcini-648c46/apps/pendingcrew`（下称 `$PC`）。CLAUDE.md 提醒：shell cwd 可能被拉回 session worktree，命令一律用绝对路径或先 `cd "$PC"`。

---

## File Structure

| 文件 | 责任 | 动作 |
|---|---|---|
| `Sources/Models/CrewSummary.swift` | crew 列表模型 | 加 `machineId` |
| `Sources/Stores/LocalCrewStore.swift` | 本地 crew 存储 | `summary` 透传 machineId |
| `Sources/Support/MachineGrouping.swift` | **新**：crew→机器分组纯函数 | 新建 |
| `Tests/PendingCrewTests/MachineGroupingTests.swift` | **新**：分组单测 | 新建 |
| `project.yml` | xcodegen 工程定义 | 把 MachineGrouping 加进 test bundle |
| `Sources/Stores/CrewStore.swift` | crew/machine 状态 | `registerSelfMachine`/`refreshMachines` 改走 edge |
| `Sources/Mac/Views/CrewDAGTreeView.swift` | DAG 折叠树 | 接受限定 crew 子集 |
| `Sources/Mac/Views/CrewSidebarView.swift` | 侧栏 | 机器分组布局 + 去占位 |
| `Sources/Mac/Views/MacRootView.swift` | 三栏外壳 | 首屏拉机器清单 |
| `apps/edge/src/routes/crews.ts` | edge crew 列表 | （可选尾巴）返回 machineId |

---

## Task 1: `CrewSummary` 带上 machineId + 本地透传

**Files:**
- Modify: `Sources/Models/CrewSummary.swift`
- Modify: `Sources/Stores/LocalCrewStore.swift:377-390`

- [ ] **Step 1: 给 `CrewSummary` 加 `machineId` 字段**

`Sources/Models/CrewSummary.swift` —— 在 `captainAgentKind` 之后加属性、init 参数、decoder、CodingKeys。

属性（紧接现有 `let captainAgentKind: String?` 之后）：

```swift
    /// crew 所属机器（nil = 本机/本地）。**Mac 本地路径**由 `LocalCrewStore` 透传
    /// `LocalCrew.machineId`；edge `GET /v1/crews` 缺键时兜 nil（向后兼容）。
    /// 侧栏「按机器分组」的分组键。
    let machineId: String?
```

memberwise init —— 在参数表末尾加 `machineId: String? = nil`，函数体末尾加赋值：

```swift
        captainAgentKind: String? = nil,
        machineId: String? = nil
    ) {
```
```swift
        self.captainAgentKind = captainAgentKind
        self.machineId = machineId
    }
```

decoder（`init(from:)`）末尾加：

```swift
        machineId = try c.decodeIfPresent(String.self, forKey: .machineId)
```

CodingKeys 加 `machineId`：

```swift
    private enum CodingKeys: String, CodingKey {
        case id, title, responsibleSubjectId, runtimeLocation
        case captainBotId, status, createdAt, updatedAt, parentCrewIds
        case captainAgentKind, machineId
    }
```

- [ ] **Step 2: `LocalCrewStore.summary` 透传 machineId**

`Sources/Stores/LocalCrewStore.swift` 的 `var summary: CrewSummary`（约 377-390 行），在 `captainAgentKind: captainAgentKind` 后加一行：

```swift
    var summary: CrewSummary {
        CrewSummary(
            id: id,
            title: title,
            responsibleSubjectId: responsibleSubjectId,
            runtimeLocation: runtimeLocation,
            captainBotId: captainBotId,
            status: "active",
            createdAt: createdAt,
            updatedAt: updatedAt,
            parentCrewIds: parentCrewIds,
            captainAgentKind: captainAgentKind,
            machineId: machineId
        )
    }
```

- [ ] **Step 3: 编译验证（随 Task 2 的 xcodegen 后统一 build；此处先确认无语法错）**

本步不单独 build（test bundle 还没接 MachineGrouping）。继续 Task 2，编译在 Task 2 Step 5 统一跑。

- [ ] **Step 4: 提交**

```bash
cd "$PC" && git add Sources/Models/CrewSummary.swift Sources/Stores/LocalCrewStore.swift
git commit -m "pendingcrew: CrewSummary 带 machineId + 本地透传

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 2: `MachineGrouping` 纯函数 helper + 单测（TDD）

**Files:**
- Create: `Sources/Support/MachineGrouping.swift`
- Create: `Tests/PendingCrewTests/MachineGroupingTests.swift`
- Modify: `project.yml`（test bundle sources）

- [ ] **Step 1: 先写失败测试**

`Tests/PendingCrewTests/MachineGroupingTests.swift` —— **不**用 `@testable import`：`Machine` / `CrewSummary` / `MachineGrouping` 都按工程惯例直接编进 test bundle（见 Step 4 的 project.yml），同模块可见。

```swift
import XCTest
import Foundation

final class MachineGroupingTests: XCTestCase {

    // MARK: - helpers
    private func machine(_ id: String, device: String?, kind: String = "computer",
                         name: String = "M") -> Machine {
        Machine(id: id, kind: kind, deviceId: device, displayName: name,
                flyMachineId: nil, status: "online", lastSeenAt: nil)
    }
    private func crew(_ id: String, machineId: String?) -> CrewSummary {
        CrewSummary(id: id, title: id, responsibleSubjectId: "s",
                    runtimeLocation: "local_host", captainBotId: nil, status: nil,
                    createdAt: "", updatedAt: "", parentCrewIds: [],
                    captainAgentKind: nil, machineId: machineId)
    }

    func testNilMachineIdGoesToLocal() {
        let local = machine("m-local", device: "dev-1", name: "本机")
        let groups = MachineGrouping.group(
            crews: [crew("c1", machineId: nil)],
            machines: [local], localDeviceId: "dev-1")
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].machine?.id, "m-local")
        XCTAssertEqual(groups[0].crews.map(\.id), ["c1"])
    }

    func testMatchingMachineIdRoutesToThatMachine() {
        let local = machine("m-local", device: "dev-1", name: "本机")
        let peer = machine("m-peer", device: "dev-2", name: "Peer")
        let groups = MachineGrouping.group(
            crews: [crew("c1", machineId: "m-peer")],
            machines: [local, peer], localDeviceId: "dev-1")
        let peerGroup = groups.first { $0.machine?.id == "m-peer" }
        XCTAssertEqual(peerGroup?.crews.map(\.id), ["c1"])
    }

    func testCrewMachineIdEqualToLocalDeviceIdResolvesToLocal() {
        // 本地合成机器 id == deviceId 的历史路径：crew.machineId 写成 deviceId 也认本机。
        let local = machine("dev-1", device: "dev-1", name: "本机")
        let groups = MachineGrouping.group(
            crews: [crew("c1", machineId: "dev-1")],
            machines: [local], localDeviceId: "dev-1")
        XCTAssertEqual(groups.first?.crews.map(\.id), ["c1"])
    }

    func testEmptyMachineStillAppearsAsGroup() {
        let local = machine("m-local", device: "dev-1", name: "本机")
        let peer = machine("m-peer", device: "dev-2", name: "Peer")
        let groups = MachineGrouping.group(
            crews: [crew("c1", machineId: nil)],
            machines: [local, peer], localDeviceId: "dev-1")
        XCTAssertEqual(groups.count, 2)
        let peerGroup = groups.first { $0.machine?.id == "m-peer" }
        XCTAssertNotNil(peerGroup)
        XCTAssertTrue(peerGroup!.crews.isEmpty)
    }

    func testLocalMachineSortsFirst() {
        let local = machine("m-local", device: "dev-1", name: "ZZZ本机")
        let peer = machine("m-peer", device: "dev-2", name: "AAA")
        let fly = machine("m-fly", device: nil, kind: "fly", name: "fly")
        let groups = MachineGrouping.group(
            crews: [], machines: [fly, peer, local], localDeviceId: "dev-1")
        XCTAssertEqual(groups.map { $0.machine?.id }, ["m-local", "m-peer", "m-fly"])
    }

    func testUnresolvedCrewGoesToOtherBucket() {
        let local = machine("m-local", device: "dev-1", name: "本机")
        let groups = MachineGrouping.group(
            crews: [crew("c1", machineId: "ghost")],
            machines: [local], localDeviceId: "dev-1")
        let other = groups.last
        XCTAssertNil(other?.machine)
        XCTAssertEqual(other?.crews.map(\.id), ["c1"])
    }

    func testNoOtherBucketWhenAllResolved() {
        let local = machine("m-local", device: "dev-1", name: "本机")
        let groups = MachineGrouping.group(
            crews: [crew("c1", machineId: nil)],
            machines: [local], localDeviceId: "dev-1")
        XCTAssertFalse(groups.contains { $0.machine == nil })
    }
}
```

- [ ] **Step 2: 跑测试确认失败（编译失败：MachineGrouping 未定义）**

```bash
cd "$PC" && xcodebuild test -project PendingCrew.xcodeproj -scheme PendingCrew \
  -destination 'platform=macOS' -only-testing:PendingCrewTests/MachineGroupingTests 2>&1 | tail -25
```
Expected: 编译失败，`cannot find 'MachineGrouping' in scope`（或 test bundle 没含该文件）。

- [ ] **Step 3: 写实现**

`Sources/Support/MachineGrouping.swift`（纯 Foundation、无 `#if`、不碰 store/SwiftUI）：

```swift
import Foundation

/// 把扁平 crew 列表按所属机器分组，给 Mac 侧栏「按机器组织」用。
/// 纯函数、平台无关、可单测 —— 不碰 store / SwiftUI。
enum MachineGrouping {
    /// 一个机器分组。`machine == nil` 是「其它/解析不到」兜底桶。
    struct Group: Identifiable, Equatable {
        let machine: Machine?
        let crews: [CrewSummary]
        var id: String { machine?.id ?? "__other__" }
    }

    /// - crews: 当前可见 crew（Mac = 本地本机 crew）。
    /// - machines: 合并后的机器清单（本机 + 账号其它机器）。
    /// - localDeviceId: `DeviceIdentity.current`，用来认「本机」那台。
    ///
    /// 规则：
    /// - `crew.machineId == nil` → 归本机（localDeviceId 对应的机器；无本机则落其它桶）。
    /// - `crew.machineId == 某 machine.id` → 该机器；指向本机 deviceId/id 也认本机。
    /// - 都不匹配 → 末尾「其它」桶（仅非空时出现）。
    /// - 机器顺序：本机置顶 → 其它 computer → fly → 未知 kind；同级按 displayName。
    /// - 空机器也出组（含本机空）。
    static func group(
        crews: [CrewSummary],
        machines: [Machine],
        localDeviceId: String
    ) -> [Group] {
        let localMachine = machines.first { $0.deviceId == localDeviceId }
        let byId = Dictionary(machines.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        func resolve(_ crew: CrewSummary) -> String? {
            if let mid = crew.machineId {
                if byId[mid] != nil { return mid }
                if let local = localMachine, mid == local.deviceId || mid == local.id {
                    return local.id
                }
                return nil
            }
            return localMachine?.id
        }

        var bucket: [String: [CrewSummary]] = [:]
        var other: [CrewSummary] = []
        for crew in crews {
            if let mid = resolve(crew) { bucket[mid, default: []].append(crew) }
            else { other.append(crew) }
        }

        func rank(_ m: Machine) -> Int {
            if m.deviceId == localDeviceId { return 0 }
            switch m.kindEnum {
            case .computer: return 1
            case .fly: return 2
            case .none: return 3
            }
        }
        let ordered = machines.sorted { lhs, rhs in
            let (rl, rr) = (rank(lhs), rank(rhs))
            if rl != rr { return rl < rr }
            return lhs.displayName.localizedCompare(rhs.displayName) == .orderedAscending
        }

        var groups = ordered.map { Group(machine: $0, crews: bucket[$0.id] ?? []) }
        if !other.isEmpty { groups.append(Group(machine: nil, crews: other)) }
        return groups
    }
}
```

- [ ] **Step 4: 把 MachineGrouping 编进 test bundle**

`project.yml`，在 `PendingCrewTests` 的 `sources:` 里、`Sources/Support/FamilyCredentialStore.swift` 那行之后，加：

```yaml
      # 机器分组纯函数（依赖 Models 里的 Machine / CrewSummary，已编进 bundle）。
      - path: Sources/Support/MachineGrouping.swift
```

再重新生成工程：

```bash
cd "$PC" && xcodegen
```
Expected: `Created project at .../PendingCrew.xcodeproj`。

- [ ] **Step 5: 跑测试确认通过**

```bash
cd "$PC" && xcodebuild test -project PendingCrew.xcodeproj -scheme PendingCrew \
  -destination 'platform=macOS' -only-testing:PendingCrewTests/MachineGroupingTests 2>&1 | tail -25
```
Expected: `** TEST SUCCEEDED **`，7 个用例全过。
（若报 `Machine`/`CrewSummary` 重复定义或不可见：确认 test bundle sources 仍含 `Sources/Models`，且本测试文件没有 `@testable import PendingCrew`。）

- [ ] **Step 6: 提交**

```bash
cd "$PC" && git add Sources/Support/MachineGrouping.swift \
  Tests/PendingCrewTests/MachineGroupingTests.swift project.yml PendingCrew.xcodeproj
git commit -m "pendingcrew: MachineGrouping 纯函数分组 + 单测

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 3: `CrewStore` 机器注册/清单改走 edge

**Files:**
- Modify: `Sources/Stores/CrewStore.swift:108-126`

让账号级的「注册本机 / 拉机器清单」走 edge（`AppModel.loggedAPIClient()`），不再打 `LocalBackend` 的 no-op/合成单机；crew 数据源不动。

- [ ] **Step 1: 重写 `refreshMachines()`**

把现有 `refreshMachines()`（约 108-118 行）整体替换为：

```swift
    /// 拉机器清单：本机始终在；登录态额外并入账号其它机器（edge `GET /v1/machines`）。
    /// 机器是账号概念 → 走 edge，**不**经 crew backend（crew 仍本地优先）。
    /// 失败静默回落「仅本机」—— 机器清单只是侧栏分组数据源，拉不到不挡用。
    func refreshMachines() async {
        let localMachine = Machine(
            id: DeviceIdentity.current,
            kind: Machine.Kind.computer.rawValue,
            deviceId: DeviceIdentity.current,
            displayName: DeviceIdentity.displayName,
            flyMachineId: nil,
            status: "online",
            lastSeenAt: nil
        )
        guard appModel.isAuthenticated, let api = try? appModel.loggedAPIClient() else {
            machines = [localMachine]
            return
        }
        do {
            let remote = try await api.listMachines()
            // edge 已含本机行（deviceId == 本机）则用 edge 行，否则把合成本机置顶补上。
            machines = remote.contains { $0.deviceId == DeviceIdentity.current }
                ? remote
                : [localMachine] + remote
        } catch {
            machines = [localMachine]
        }
    }
```

- [ ] **Step 2: 重写 `registerSelfMachine()`**

把现有 `registerSelfMachine()`（约 122-126 行）整体替换为：

```swift
    /// 把本机真注册进账号 machine 表（edge，幂等 upsert by device_id）。登录后调。
    /// 失败静默 —— best-effort，不挡用户用 app。未登录直接跳过（返回 nil）。
    @discardableResult
    func registerSelfMachine() async -> String? {
        guard appModel.isAuthenticated, let api = try? appModel.loggedAPIClient() else {
            return nil
        }
        return try? await api.registerSelfMachine()
    }
```

- [ ] **Step 3: 编译验证**

```bash
cd "$PC" && xcodebuild -project PendingCrew.xcodeproj -scheme PendingCrew \
  -destination 'platform=macOS' build 2>&1 | tail -15
```
Expected: `** BUILD SUCCEEDED **`。

- [ ] **Step 4: 提交**

```bash
cd "$PC" && git add Sources/Stores/CrewStore.swift
git commit -m "pendingcrew: 机器注册/清单走 edge(账号级),crew 仍本地

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 4: `CrewDAGTreeView` 接受限定 crew 子集

**Files:**
- Modify: `Sources/Mac/Views/CrewDAGTreeView.swift:16-51`

让树渲染指定子集（某机器的 crew），而不是全量 `crewStore.crews`。组内根 = 子集里无父、或父不在本组的 crew。

- [ ] **Step 1: 改 `CrewDAGTreeView` 用注入子集**

把 `struct CrewDAGTreeView` 顶部（16-33 行）替换为：

```swift
struct CrewDAGTreeView: View {
    /// 本组要渲染的 crew 子集（某台机器的 crew）。
    let crews: [CrewSummary]

    var body: some View {
        // childMap: parentId → 该父下直接子 crew。限定在子集内算。
        let childMap = Self.buildChildMap(crews)
        let ids = Set(crews.map(\.id))
        // 组内根 = 无父，或父不在本组（跨机器父边 → 在本组当根）。
        let roots = crews.filter { crew in
            crew.parentCrewIds.isEmpty || !crew.parentCrewIds.contains(where: ids.contains)
        }

        ForEach(roots) { crew in
            CrewDAGNode(
                crew: crew,
                childMap: childMap,
                crewsById: Self.byId(crews),
                ancestors: []
            )
        }
    }
```

（删掉原来的 `@EnvironmentObject private var crewStore: CrewStore` 与 `let crews = crewStore.crews`/`let roots = crews.filter { $0.parentCrewIds.isEmpty }`。`buildChildMap` / `byId` 静态方法、`CrewDAGNode` 都不动 —— `CrewDAGNode` 仍自带 `@EnvironmentObject crewStore` 做选中。）

- [ ] **Step 2: 编译验证（会因 CrewSidebarView 旧调用点报错，预期）**

```bash
cd "$PC" && xcodebuild -project PendingCrew.xcodeproj -scheme PendingCrew \
  -destination 'platform=macOS' build 2>&1 | tail -15
```
Expected: 失败，`CrewSidebarView.swift` 里 `CrewDAGTreeView()`（无参）报缺 `crews:`。Task 5 修复后即过。**本步不提交**，与 Task 5 一起提交（同一编译单元）。

---

## Task 5: `CrewSidebarView` 机器分组布局

**Files:**
- Modify: `Sources/Mac/Views/CrewSidebarView.swift`（body List 段 19-41、删 `machinesRow` 118-151、删 `emptyRow` 243-260、加分组视图 + `@State collapsed`）
- Modify: `Sources/Mac/Views/MacRootView.swift:86-95`

- [ ] **Step 1: 加折叠态 + 换 body 的 List**

`CrewSidebarView` 顶部 `@State` 区，紧接 `@State private var showingLogin = false` 后加：

```swift
    /// 折叠起来的机器分组 id 集合（默认全展开）。
    @State private var collapsedMachineIds: Set<String> = []
```

把 `body` 里的整段 `List { Section{…Crew…} … Section{…Machines…} }`（19-41 行，即从 `List {` 到对应的 `}` 收尾、`.listStyle(.sidebar)` 之前）替换为：

```swift
            List {
                ForEach(machineGroups) { group in
                    Section {
                        sectionBody(group)
                    } header: {
                        machineHeader(group)
                    }
                }
            }
```

- [ ] **Step 2: 加分组派生 + 子视图，删旧占位/空行**

删除 `machinesRow`（118-151 行）整段、`emptyRow`（243-260 行）整段。

在 `CrewSidebarView` 里（如放在 `body` 之后、`identityFooter` 之前）新增：

```swift
    // MARK: - 机器分组

    private var machineGroups: [MachineGrouping.Group] {
        MachineGrouping.group(
            crews: crewStore.crews,
            machines: crewStore.machines,
            localDeviceId: DeviceIdentity.current
        )
    }

    @ViewBuilder
    private func sectionBody(_ group: MachineGrouping.Group) -> some View {
        if collapsedMachineIds.contains(group.id) {
            EmptyView()
        } else if group.crews.isEmpty {
            machineEmptyRow(group)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        } else {
            CrewDAGTreeView(crews: group.crews)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        }
    }

    @ViewBuilder
    private func machineHeader(_ group: MachineGrouping.Group) -> some View {
        let machine = group.machine
        let isLocal = machine?.deviceId == DeviceIdentity.current
        let collapsed = collapsedMachineIds.contains(group.id)
        HStack(spacing: 6) {
            Button {
                if collapsed { collapsedMachineIds.remove(group.id) }
                else { collapsedMachineIds.insert(group.id) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(collapsed ? 0 : 90))
                        .foregroundStyle(.secondary)
                    Image(systemName: machine?.displayIcon(isLocal: isLocal) ?? "questionmark.folder")
                        .foregroundStyle(.secondary)
                    Text(machine?.displayName ?? "其它")
                        .lineLimit(1)
                    if isLocal {
                        Text("本机")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Theme.Palette.surfaceMuted))
                    }
                    if let m = machine {
                        Circle()
                            .fill(machineOnline(m) ? Color.green : Color.secondary.opacity(0.4))
                            .frame(width: 6, height: 6)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer(minLength: 4)
            if isLocal {
                Button { showingCreateSheet = true } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .help("在本机新建 crew")
            }
        }
    }

    private func machineOnline(_ m: Machine) -> Bool {
        m.deviceId == DeviceIdentity.current || m.status == "online"
    }

    @ViewBuilder
    private func machineEmptyRow(_ group: MachineGrouping.Group) -> some View {
        let isLocal = group.machine?.deviceId == DeviceIdentity.current
        VStack(alignment: .leading, spacing: 4) {
            if isLocal {
                if crewStore.loadingList {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("加载中…").foregroundStyle(.secondary)
                    }
                } else {
                    Text("还没有 crew").font(.callout).foregroundStyle(.secondary)
                    Text("点 + 新建第一个").font(.caption).foregroundStyle(.tertiary)
                }
            } else {
                // 其它机器：local-first,本机看不到其 crew 内容 → 遥控投影是后续(#242)。
                HStack(spacing: 6) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(.tertiary)
                    Text("遥控查看（稍后）").font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
    }
```

（保留 toolbar 的全局「+」/刷新、`identityFooter`、所有 `.sheet`/`.confirmationDialog`/`.onChange` 不动。toolbar 刷新按钮顺带刷机器：见 Step 3。）

- [ ] **Step 3: 刷新按钮 + 首屏顺带拉机器清单**

`CrewSidebarView` toolbar 刷新按钮（约 62 行）改成同时刷机器：

```swift
                Button {
                    Task {
                        await crewStore.refreshList()
                        await crewStore.refreshMachines()
                    }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
```

`Sources/Mac/Views/MacRootView.swift` 的 `.task`（86-95 行），在 `await crewStore.refreshSubjects()` 之后、`relayAgent.start(...)` 之前加两行（首屏已登录时也注册本机 + 拉机器清单；未登录时 register 是 no-op、机器清单回落仅本机）：

```swift
            await crewStore.refreshList()
            await crewStore.refreshSubjects()
            // 首屏注册本机 + 拉机器清单（侧栏按机器分组的数据源）。
            _ = await crewStore.registerSelfMachine()
            await crewStore.refreshMachines()
```

- [ ] **Step 4: 编译验证**

```bash
cd "$PC" && xcodebuild -project PendingCrew.xcodeproj -scheme PendingCrew \
  -destination 'platform=macOS' build 2>&1 | tail -15
```
Expected: `** BUILD SUCCEEDED **`。

- [ ] **Step 5: 提交**

```bash
cd "$PC" && git add Sources/Mac/Views/CrewDAGTreeView.swift \
  Sources/Mac/Views/CrewSidebarView.swift Sources/Mac/Views/MacRootView.swift
git commit -m "pendingcrew: 侧栏按 machine 分组(本机组+其它机器组+折叠)

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 6（可选尾巴）: edge `GET /v1/crews` 返回 machineId

**Files:**
- Modify: `apps/edge/src/routes/crews.ts:272-291`

Mac 本任务不读 edge crew，所以这步不是 Mac 生效所必需；但补齐契约让 iPad / 未来遥控投影能按机器分组。**可跳过**（跳过则在收尾说明）。

- [ ] **Step 1: list 查询补 `machine_id` + 响应 map**

`apps/edge/src/routes/crews.ts` 的 `GET /v1/crews` 列表块：`.select(...)`（约 273 行）补 `machine_id`，`.map(...)`（约 285 行）加 `machineId`：

```ts
    .select('conversation_id, responsible_subject_id, captain_bot_id, runtime_location, machine_id, title, created_at, updated_at, status')
```
```ts
  const crews = (rows ?? []).map((row) => ({
    id: row.conversation_id,
    title: row.title ?? '机组',
    responsibleSubjectId: row.responsible_subject_id,
    runtimeLocation: row.runtime_location,
    machineId: row.machine_id,
    captainBotId: row.captain_bot_id,
    status: row.status,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  }));
```

- [ ] **Step 2: typecheck + 测试**

新 worktree 先确保依赖在（`prepare` 脚本 exit 1 可忽略）：

```bash
cd /Users/hey/Untitled/Pendingname/PendingBot/dev/.claude/worktrees/musing-montalcini-648c46 \
  && bun install 2>&1 | tail -5
bun --filter='@pendingbot/edge' run typecheck 2>&1 | tail -15
cd apps/edge && ./node_modules/.bin/vitest run 2>&1 | tail -20
```
Expected: typecheck 0 错；vitest 全过（若 `temporary_group_meta` 无 `machine_id` 列导致 schema 类型报错 → 确认 #335 迁移已应用、`schema.ts` 已 regen；本任务不改 DB）。

- [ ] **Step 3: 提交**

```bash
cd /Users/hey/Untitled/Pendingname/PendingBot/dev/.claude/worktrees/musing-montalcini-648c46 \
  && git add apps/edge/src/routes/crews.ts
git commit -m "edge: GET /v1/crews 返回 machineId(给 iPad/遥控投影分组)

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 7: 整体验证 + 账本对账

**Files:** 无代码改动（验证 + 文档）

- [ ] **Step 1: 全量 Mac build + 单测**

```bash
cd "$PC" && xcodebuild test -project PendingCrew.xcodeproj -scheme PendingCrew \
  -destination 'platform=macOS' -only-testing:PendingCrewTests/MachineGroupingTests 2>&1 | tail -8
cd "$PC" && xcodebuild -project PendingCrew.xcodeproj -scheme PendingCrew \
  -destination 'platform=macOS' build 2>&1 | tail -8
```
Expected: 测试 `** TEST SUCCEEDED **`，build `** BUILD SUCCEEDED **`。

- [ ] **Step 2: 真起 app 看分组（视觉验证）**

用最新产物路径起 app（取 DerivedData 最新 mtime 的 `PendingCrew.app`），未登录态应看到：**一个「本机」组**（带桌面图标 + 「本机」标 + 绿点 + 「+」）裹住现有 crew 树；无 crew 时组内是「还没有 crew · 点 + 新建」。点机器头折叠/展开正常。

```bash
APP=$(find ~/Library/Developer/Xcode/DerivedData -name 'PendingCrew.app' -path '*Debug*' -type d 2>/dev/null | xargs -I{} stat -f '%m %N' {} | sort -rn | head -1 | cut -d' ' -f2-)
echo "launching: $APP" && open "$APP"
```
截图核对（不要用 computer-use 抢鼠标；用 `screencapture` 自截窗或交给用户看）：

```bash
sleep 3 && screencapture -o ~/Desktop/pendingcrew-sidebar.png && echo saved
```
（登录态 + 第二台机器才会出现「其它机器组（遥控查看 · 稍后）」—— 无第二台设备时这是预期的看不到，不算缺陷。）

- [ ] **Step 3: 账本对账**

- `TaskUpdate`：把本计划相关进度落到 task 系统（可新建一条「sidebar-by-machine」或挂到 #342 crew-machine 系列）。`completed` 仅在 Step 1/2 验证过后。
- `docs/tech-debt.md`：记一条 —— **「Mac 侧栏其它机器组内容为空」是已知缺口**，根因 local-first 无 edge crew-mirror，其它机器 crew 的可见/可控属遥控投影（指向 #242 遥控 v1）；本任务只做到「机器可被寻址 + 真注册/真清单」。
- `docs/progress.md`：顶部「最近对账」日期更新，提一句 sidebar 按机器分组已落（数据层接通 + UI）。

- [ ] **Step 4: 提交账本**

```bash
cd /Users/hey/Untitled/Pendingname/PendingBot/dev/.claude/worktrees/musing-montalcini-648c46 \
  && git add docs/tech-debt.md docs/progress.md
git commit -m "docs: sidebar-by-machine 账本对账 + 其它机器组空内容缺口入 tech-debt

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## 自检（写计划后对照 spec）

- **Spec coverage**：心智模型（机器=账号/edge，crew=本地）→ Task 3；本机 crew 本地优先 → 不动 crew backend（Task 3 注释）；侧栏机器分组 + 本机「+」+ 其它组遥控提示 + 折叠 → Task 5；空机器出组 → Task 2 规则 + Task 5 emptyRow；DAG 限本组 → Task 4；machineId 前向兼容 → Task 1 + Task 6（可选）；分组 helper 单测 → Task 2；非目标（遥控投影/建/上云/iPad 侧栏）→ 未列任务，Task 7 记缺口。✅ 全覆盖。
- **Placeholder scan**：无 TBD/TODO；每个代码步给了完整代码。✅
- **Type consistency**：`MachineGrouping.group(crews:machines:localDeviceId:)`、`MachineGrouping.Group{machine,crews,id}`、`CrewDAGTreeView(crews:)`、`CrewSummary(... machineId:)`、`Machine(id:kind:deviceId:displayName:flyMachineId:status:lastSeenAt:)`、`crewStore.refreshMachines()`/`registerSelfMachine()` 全计划一致。✅
