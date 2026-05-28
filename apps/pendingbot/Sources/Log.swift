import OSLog

/// Convenience factory so per-file loggers don't have to repeat the
/// app's bundle id as the subsystem.
///
///     private let log = Logger.category("push")
///     log.error("APNS registration failed: \(error.localizedDescription)")
///
/// Logger writes to the unified system log — visible in Xcode's
/// console during dev runs and in Console.app for installed builds
/// (filter on subsystem `com.pendingname.pendingbot`). Replaces the
/// older `print("[tag] …")` pattern.
extension Logger {
    static func category(_ category: String) -> Logger {
        Logger(subsystem: "com.pendingname.pendingbot", category: category)
    }
}
