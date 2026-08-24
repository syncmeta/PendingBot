// Standalone test for PresetEpoch — the client-side constant behind the preset
// onboarding conversations' deliberately-epoch timestamps — and for how
// RelativeMessageTime renders it.
//
// The preset messages are stamped at 1970-01-02 12:34 Beijing time on purpose:
// the badge is a designed marker, not a stale timestamp. The stamp is NOT
// timezone-locked for display (product call): a UTC+8 screen reads 12:34,
// other zones read their own clock. These cases pin both halves so neither
// drifts by accident.
//
// This branch has no iOS unit-test target yet, and both types are
// Foundation-only, so they're exercised by compiling them together:
//
//     apps/pendingbot/Tests/run-preset-epoch-tests.sh
//
// The device timezone comes from TEST_TZ so the same binary can be run once
// per zone — formatters capture the default zone at first use, so one process
// can only speak for one device.

import Foundation

let deviceZone = TimeZone(identifier: ProcessInfo.processInfo.environment["TEST_TZ"] ?? "Asia/Shanghai")!

// ── tiny harness ────────────────────────────────────────────────────────
var failures = 0
var checks = 0

func expectEqual(_ actual: String, _ expected: String, _ what: String, line: Int = #line) {
    checks += 1
    if actual != expected {
        failures += 1
        print("✘ \(what) (line \(line))")
        print("    expected \(expected)")
        print("    actual   \(actual)")
    }
}

func expectTrue(_ cond: Bool, _ what: String, line: Int = #line) {
    checks += 1
    if !cond {
        failures += 1
        print("✘ \(what) (line \(line))")
    }
}

func utc(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int = 0) -> Date {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
}

let now = utc(2026, 6, 1, 0, 0)

func pill(_ date: Date) -> String {
    RelativeMessageTime.format(date, now: now, style: .pill)
}

@main
struct PresetEpochTimeTests {
    static func main() {
        NSTimeZone.default = deviceZone

        // ── the constant ────────────────────────────────────────────────

        expectTrue(PresetEpoch.base == utc(1970, 1, 2, 4, 34),
                   "基准戳 = 1970-01-02 12:34 北京时间 = 04:34 UTC")
        expectTrue(PresetEpoch.windowEnd == utc(1971, 1, 1, 0, 0),
                   "纪元窗口的右边界是 1971-01-01 UTC")

        // ── preseeded-vs-real criterion ─────────────────────────────────
        // The old `< 1970-01-02` boundary would call the new stamps real
        // replies; the window is a whole year wide, so moving the base around
        // inside 1970 can never flip it again.

        expectTrue(PresetEpoch.isPreseeded(PresetEpoch.base),
                   "基准戳算预置")
        expectTrue(PresetEpoch.isPreseeded(PresetEpoch.base.addingTimeInterval(59)),
                   "同一分钟里最靠后的槽位也算预置")
        expectTrue(PresetEpoch.isPreseeded(utc(1970, 1, 1, 5, 0)),
                   "还没被重新盖戳的老预置消息(1970-01-01)仍算预置")
        expectTrue(!PresetEpoch.isPreseeded(PresetEpoch.windowEnd),
                   "窗口右边界本身不算预置")
        expectTrue(!PresetEpoch.isPreseeded(utc(2026, 1, 15, 3, 0)),
                   "真实消息不算预置")

        // ── rendering ───────────────────────────────────────────────────

        switch deviceZone.identifier {
        case "Asia/Shanghai":
            // 作者拍板的那块屏幕 —— 这才是 12:34 该出现的地方。
            expectEqual(pill(PresetEpoch.base), "1970年1月2日 12:34",
                        "UTC+8 的设备上,预设消息读作 1970年1月2日 12:34")
            expectEqual(pill(PresetEpoch.base.addingTimeInterval(50)), "1970年1月2日 12:34",
                        "最靠后的 slug 槽位仍读作 12:34")
            expectEqual(pill(PresetEpoch.base.addingTimeInterval(50.999)), "1970年1月2日 12:34",
                        "同一会话最后一条消息仍读作 12:34")
            expectEqual(pill(utc(2026, 1, 15, 3, 0)), "1月15日 11:00",
                        "真实消息走设备本地时区")
        case "America/New_York":
            // 不锁时区的已知代价,写下来免得以后被当成 bug 修掉。
            expectEqual(pill(PresetEpoch.base), "1970年1月1日 23:34",
                        "别的时区读到的是它自己的钟点(选 B 的已知代价)")
            expectEqual(pill(utc(2026, 1, 15, 3, 0)), "1月14日 22:00",
                        "真实消息走设备本地时区")
        default:
            print("✘ 未预期的 TEST_TZ=\(deviceZone.identifier)")
            exit(1)
        }

        // ── report ──────────────────────────────────────────────────────

        if failures == 0 {
            print("✔ PresetEpoch [\(deviceZone.identifier)] — \(checks) checks passed")
            exit(0)
        } else {
            print("✘ PresetEpoch [\(deviceZone.identifier)] — \(failures)/\(checks) checks FAILED")
            exit(1)
        }
    }
}
