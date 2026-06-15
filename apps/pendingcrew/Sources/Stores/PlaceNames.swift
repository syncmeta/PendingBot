import Foundation

/// CrewGround 离线地名池 —— 从 bundle 里的 `crewground_places.txt` 读一批
/// 世界城市名（每行一个）。新建 crew 选 CrewGround 时随机挑一个未占用的名字
/// 做 `~/CrewGround/<name>` 子目录。
///
/// 离线兜底：CrewGround 在未登录态也要能用，所以不依赖服务端
/// `random_place_name()` RPC，纯本地列表。读不到 bundle 资源时回落
/// `["Atlantis"]`（永远有一个名字可用，不至于建不出目录）。
enum PlaceNames {
    static let all: [String] = {
        guard let url = Bundle.main.url(forResource: "crewground_places", withExtension: "txt"),
              let raw = try? String(contentsOf: url, encoding: .utf8) else {
            return ["Atlantis"]
        }
        let names = raw.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return names.isEmpty ? ["Atlantis"] : names
    }()
}
