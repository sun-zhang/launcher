import os

/// 统一日志入口（Console.app 可按 subsystem 过滤）。
/// P-5：日志不得记录用户键盘输入——搜索串仅在 selftest 排障时记录且可关。
public enum Log {
    static let subsystem = "com.launcherz.app"
    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let index = Logger(subsystem: subsystem, category: "index")
    public static let trigger = Logger(subsystem: subsystem, category: "trigger")
    public static let panel = Logger(subsystem: subsystem, category: "panel")
    public static let layout = Logger(subsystem: subsystem, category: "layout")
    public static let selftest = Logger(subsystem: subsystem, category: "selftest")
}
