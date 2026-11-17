import Foundation

/// A tiny logger for development builds. It prints to the Xcode console and keeps nothing.
enum Console {
    static func log(_ message: String) {
        #if DEBUG
        print("[PanelSnap] \(message)")
        #endif
    }
}
