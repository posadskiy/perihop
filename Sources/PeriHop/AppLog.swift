import os

/// Unified logging so a user's problem report can be diagnosed from
/// Console.app after the fact, instead of only from a transient in-app
/// error box that's gone once dismissed.
enum AppLog {
    static let bluetooth = Logger(subsystem: "com.posadskiy.perihop", category: "Bluetooth")
    static let switchFlow = Logger(subsystem: "com.posadskiy.perihop", category: "SwitchFlow")
    static let config = Logger(subsystem: "com.posadskiy.perihop", category: "Config")
}
