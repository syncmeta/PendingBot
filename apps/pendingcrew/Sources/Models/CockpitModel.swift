import Foundation

/// 驾驶舱(cockpit)的数据模型 + 轻量解析。
///
/// cockpit.md:驾驶舱是[对账](../../../docs/handbook/pendingcrew/concepts/reconciliation.md)的**纯呈现面**——
/// 读三本账(期望 docs/handbook / 现状 docs/state / task docs/tasks)摆出来,**差靠人扫两栏读**,
/// 不替人判 drift、不做一致性检查。状态走 frontmatter `status:` 渲成色块,正文交给 MarkdownText 原样渲、
/// **不另解析**(不把文档解析成 AST)。本文件只做「抽 status / 现状一句话 / task 链」这点轻解析。

// MARK: - Types

/// 一个 topic = 一条现状条(docs/state 的 `## <key>`),并知道它对应的期望页路径。
struct CockpitTopic: Identifiable, Equatable {
    let area: String        // "pendingcrew" / "pendingbot" / "shared"
    let key: String         // "concepts/cockpit" / "vision" / "features/three-pane-ui"
    let status: String      // 原始 status 值,如 "partial, pending-qa"
    let summary: String      // 现状 一句话
    let evidence: String     // 证据
    let taskIds: [String]    // task: 行里抽出的新账本 id(yyyymmdd-xx),用于链 task 卡
    let taskRaw: String      // task: 行原文(展示兜底)

    var id: String { "\(area)/\(key)" }
    /// 期望页相对 docs/handbook 的路径(无扩展名),如 "pendingcrew/concepts/cockpit"。
    var expectationRelpath: String { "\(area)/\(key)" }
}

/// 一个 task = docs/tasks/<id>.md 的 frontmatter。
struct CockpitTask: Identifiable, Equatable {
    let id: String
    let title: String
    let status: String      // todo / doing / pending-qa / done / dropped
    let owner: String
    let crew: String        // 归属 crew(驾驶舱沿 DAG 子树过滤);~ = 无
    let expects: [String]
    let state: [String]
    let deps: [String]
    let updated: String     // 时间戳(dashboard 排「最近」用)
}

/// handbook 目录树节点(期望页以目录形式浏览)。
struct HandbookNode: Identifiable, Equatable {
    let id: String          // 相对 docs/handbook 的路径,如 "pendingcrew/concepts" / "pendingcrew/concepts/crew"
    let name: String        // 显示名(文件夹名 / 页末段)
    let isPage: Bool        // true = .md 页;false = 文件夹
    var children: [HandbookNode]
    var pageRelpath: String? { isPage ? id : nil }   // 渲染:docs/handbook/<id>.md
    /// OutlineGroup 用:叶子返 nil(才不画展开箭头),文件夹返非空。
    var childrenOrNil: [HandbookNode]? { children.isEmpty ? nil : children }
}

/// dashboard 统计(纯展示 rollup)。
struct CockpitStats: Equatable {
    let topicCount: Int
    let taskCount: Int
    let topicStatus: [StatusCount]   // 现状条按桶
    let taskStatus: [StatusCount]    // task 按桶
    let recentTasks: [CockpitTask]   // 按 updated 倒序

    struct StatusCount: Equatable, Identifiable { let bucket: String; let count: Int; var id: String { bucket } }

    static func from(_ data: CockpitData) -> CockpitStats {
        func tally(_ statuses: [String]) -> [StatusCount] {
            var m: [String: Int] = [:]
            for s in statuses { m[cockpitStatusBucket(s), default: 0] += 1 }
            return ["planned", "partial", "pending-qa", "done", "dropped", "other"]
                .compactMap { k in m[k].map { StatusCount(bucket: k, count: $0) } }
        }
        let recent = data.tasks.sorted { $0.updated > $1.updated }.prefix(8)
        return CockpitStats(
            topicCount: data.topics.count,
            taskCount: data.tasks.count,
            topicStatus: tally(data.topics.map(\.status)),
            taskStatus: tally(data.tasks.map(\.status)),
            recentTasks: Array(recent))
    }
}

/// status → 桶(纯展示分组,**不判 drift**)。现状 planned/partial/done(+pending-qa);task todo/doing/…
func cockpitStatusBucket(_ raw: String) -> String {
    let s = raw.lowercased()
    if s.contains("pending-qa") { return "pending-qa" }
    if s.hasPrefix("done") { return "done" }
    if s.hasPrefix("partial") || s == "doing" { return "partial" }
    if s.hasPrefix("planned") || s == "todo" { return "planned" }
    if s == "dropped" { return "dropped" }
    return "other"
}

/// 一次加载出的三本账数据。
struct CockpitData {
    var topics: [CockpitTopic]
    var tasks: [CockpitTask]
    /// 期望 handbook 目录树(期望页以目录形式浏览)。
    var handbookTree: [HandbookNode]
    /// docs/handbook 绝对目录,用于详情页按需读期望页 markdown。
    var handbookDir: URL

    func task(_ id: String) -> CockpitTask? { tasks.first { $0.id == id } }
    var stats: CockpitStats { CockpitStats.from(self) }
}

// MARK: - Pure parsing (Foundation only — swiftc 可单测)

enum CockpitParser {
    /// 解析 docs/state/<area>.md 成 topics。
    static func parseStateFile(area: String, content: String) -> [CockpitTopic] {
        var topics: [CockpitTopic] = []
        var key: String?
        var status = "", summary = "", evidence = "", taskRaw = ""
        func flush() {
            guard let k = key else { return }
            topics.append(CockpitTopic(
                area: area, key: k, status: status, summary: summary,
                evidence: evidence, taskIds: extractTaskIds(taskRaw), taskRaw: taskRaw))
        }
        for line in content.components(separatedBy: "\n") {
            if let h = headingKey(line) {
                flush()
                key = h; status = ""; summary = ""; evidence = ""; taskRaw = ""
                continue
            }
            if key == nil { continue }
            if let v = field(line, "status") { status = v }
            else if let v = field(line, "现状") { summary = v }
            else if let v = field(line, "证据") { evidence = v }
            else if let v = field(line, "task") { taskRaw = v }
        }
        flush()
        return topics
    }

    /// 解析 docs/tasks/<id>.md 的 frontmatter 成 CockpitTask。
    static func parseTaskFile(_ content: String) -> CockpitTask? {
        guard let fm = frontmatter(content) else { return nil }
        let id = fmScalar(fm, "id")
        guard !id.isEmpty else { return nil }
        return CockpitTask(
            id: id,
            title: fmScalar(fm, "title"),
            status: fmScalar(fm, "status"),
            owner: fmScalar(fm, "owner"),
            crew: fmScalar(fm, "crew"),
            expects: fmList(fm, "expects"),
            state: fmList(fm, "state"),
            deps: fmList(fm, "deps"),
            updated: fmScalar(fm, "updated"))
    }

    /// 从现状条 task: 行抽新账本 id(yyyymmdd-xx);#NNN / Tx.y 忽略。
    static func extractTaskIds(_ value: String) -> [String] {
        var out: [String] = []
        let scalars = Array(value)
        var i = 0
        while i < scalars.count {
            // 找 8 位数字 + '-' + 2 位 [a-z0-9]
            if i + 11 <= scalars.count,
               scalars[i...(i + 7)].allSatisfy({ $0.isNumber }),
               scalars[i + 8] == "-",
               isIdSuffix(scalars[i + 9]), isIdSuffix(scalars[i + 10]) {
                // 边界:前一个不是数字/字母,后一个不是字母数字
                let prevOK = i == 0 || !(scalars[i - 1].isNumber || scalars[i - 1].isLetter)
                let nextIdx = i + 11
                let nextOK = nextIdx >= scalars.count || !(scalars[nextIdx].isNumber || scalars[nextIdx].isLetter)
                if prevOK && nextOK {
                    out.append(String(scalars[i...(i + 10)]))
                    i += 11
                    continue
                }
            }
            i += 1
        }
        return out
    }

    // MARK: helpers

    private static func headingKey(_ line: String) -> String? {
        guard line.hasPrefix("## "), !line.hasPrefix("### ") else { return nil }
        return String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
    }

    private static func field(_ line: String, _ name: String) -> String? {
        for sep in [":", "："] {
            let prefix = name + sep
            if line.hasPrefix(prefix) {
                return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private static func isIdSuffix(_ c: Character) -> Bool {
        c.isNumber || (c.isLetter && c.isLowercase)
    }

    /// 抽 frontmatter(首个 `---` … `---` 之间)。
    private static func frontmatter(_ content: String) -> String? {
        let lines = content.components(separatedBy: "\n")
        guard lines.first == "---" else { return nil }
        var body: [String] = []
        for line in lines.dropFirst() {
            if line == "---" { return body.joined(separator: "\n") }
            body.append(line)
        }
        return nil
    }

    private static func fmScalar(_ fm: String, _ key: String) -> String {
        for line in fm.components(separatedBy: "\n") {
            if line.hasPrefix(key + ":") {
                return String(line.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
            }
        }
        return ""
    }

    private static func fmList(_ fm: String, _ key: String) -> [String] {
        let raw = fmScalar(fm, key)
        var inner = raw.trimmingCharacters(in: .whitespaces)
        if inner.hasPrefix("[") { inner.removeFirst() }
        if inner.hasSuffix("]") { inner.removeLast() }
        return inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

// MARK: - Loader (FileManager)

enum CockpitLoader {
    /// 从 crew 的工作目录读三本账。
    static func load(crewRoot: URL) -> CockpitData {
        let stateDir = crewRoot.appendingPathComponent("docs/state", isDirectory: true)
        let tasksDir = crewRoot.appendingPathComponent("docs/tasks", isDirectory: true)
        let handbookDir = crewRoot.appendingPathComponent("docs/handbook", isDirectory: true)

        var topics: [CockpitTopic] = []
        for file in markdownFiles(in: stateDir) {
            let area = file.deletingPathExtension().lastPathComponent
            if let content = readString(file) {
                topics += CockpitParser.parseStateFile(area: area, content: content)
            }
        }

        var tasks: [CockpitTask] = []
        for file in markdownFiles(in: tasksDir) where file.lastPathComponent != "README.md" {
            if let content = readString(file), let t = CockpitParser.parseTaskFile(content) {
                tasks.append(t)
            }
        }

        return CockpitData(
            topics: topics, tasks: tasks,
            handbookTree: handbookTree(handbookDir: handbookDir),
            handbookDir: handbookDir)
    }

    /// 读期望页 markdown(详情页用)。relpath 形如 "pendingcrew/concepts/cockpit"。
    static func readExpectation(handbookDir: URL, relpath: String) -> String? {
        readString(handbookDir.appendingPathComponent("\(relpath).md"))
    }

    /// 期望 handbook 目录树 —— 文件夹/页递归。文件夹在前、页在后,各按名排。
    /// 仓库级一份;per-crew 沿 DAG 切片是显示层的事(cockpit.md:派生无损、零额外存储)。
    static func handbookTree(handbookDir: URL) -> [HandbookNode] {
        buildNodes(dir: handbookDir, prefix: "")
    }

    private static func buildNodes(dir: URL, prefix: String) -> [HandbookNode] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return [] }
        var folders: [HandbookNode] = []
        var pages: [HandbookNode] = []
        for url in items {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                let name = url.lastPathComponent
                let rel = prefix.isEmpty ? name : "\(prefix)/\(name)"
                let kids = buildNodes(dir: url, prefix: rel)
                if !kids.isEmpty {
                    folders.append(HandbookNode(id: rel, name: name, isPage: false, children: kids))
                }
            } else if url.pathExtension == "md" {
                let base = url.deletingPathExtension().lastPathComponent
                if base == "README" { continue }
                let rel = prefix.isEmpty ? base : "\(prefix)/\(base)"
                pages.append(HandbookNode(id: rel, name: base, isPage: true, children: []))
            }
        }
        folders.sort { $0.name < $1.name }
        pages.sort { $0.name < $1.name }
        return folders + pages
    }

    private static func markdownFiles(in dir: URL) -> [URL] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return items.filter { $0.pathExtension == "md" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func readString(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
