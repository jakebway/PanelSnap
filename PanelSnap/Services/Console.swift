import Foundation
import SwiftUI
import UIKit
import MachO

/// A tiny in-app log, shown in Settings > Console. Safe to call from any thread.
final class Console: ObservableObject {
    static let shared = Console()
    @Published private(set) var lines: [String] = []

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func log(_ message: String) {
        let line = stamp.string(from: Date()) + "  " + message
        DispatchQueue.main.async {
            let c = Console.shared
            c.lines.append(line)
            if c.lines.count > 800 { c.lines.removeFirst(c.lines.count - 800) }
        }
    }

    func clear() { lines.removeAll() }
    var text: String { return lines.joined(separator: "\n") }

    // MARK: diagnostics

    private static func version(_ v: UInt32) -> String {
        return "\(v >> 16).\((v >> 8) & 0xff).\(v & 0xff)"
    }

    /// Reads the SDK this binary was linked against straight from its Mach-O header.
    static func linkedSDK() -> String {
        guard let header = _dyld_get_image_header(0) else { return "unknown" }
        let raw = UnsafeRawPointer(header)
        let count = raw.load(as: mach_header_64.self).ncmds
        var ptr = raw.advanced(by: MemoryLayout<mach_header_64>.size)
        for _ in 0..<count {
            let lc = ptr.load(as: load_command.self)
            if lc.cmd == 0x32 { // LC_BUILD_VERSION
                let b = ptr.load(as: build_version_command.self)
                return "platform \(b.platform), minos \(version(b.minos)), sdk \(version(b.sdk))"
            }
            ptr = ptr.advanced(by: Int(lc.cmdsize))
        }
        return "no build-version command"
    }

    static func logEnvironment(reason: String) {
        log("---- diagnostics (\(reason)) ----")
        let dev = UIDevice.current
        log("device: \(dev.model), iOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        log("binary linked: \(linkedSDK())")
        let info = Bundle.main.infoDictionary ?? [:]
        for k in ["DTPlatformVersion", "DTSDKName", "DTXcode", "MinimumOSVersion", "UIDeviceFamily",
                  "UIFileSharingEnabled", "LSSupportsOpeningDocumentsInPlace", "UIUserInterfaceStyle"] {
            log("plist \(k): \(info[k].map { "\($0)" } ?? "(missing)")")
        }
        log("plist UILaunchScreen: \(info["UILaunchScreen"].map { "\($0)" } ?? "(missing)")")
        DispatchQueue.main.async {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            if scenes.isEmpty { log("no window scenes yet") }
            for s in scenes {
                let scr = s.screen
                log("screen: bounds \(fmt(scr.bounds)) native \(fmt(scr.nativeBounds)) scale \(scr.scale)")
                log("scene: bounds \(fmt(s.coordinateSpace.bounds)) size class h=\(s.traitCollection.horizontalSizeClass.rawValue) v=\(s.traitCollection.verticalSizeClass.rawValue)")
                for w in s.windows {
                    log("window: frame \(fmt(w.frame)) safe \(insets(w.safeAreaInsets)) key=\(w.isKeyWindow) root=\(w.rootViewController.map { "\(type(of: $0))" } ?? "nil")")
                    if let root = w.rootViewController {
                        log("root view: \(fmt(root.view.frame)) presenting=\(root.presentedViewController.map { "\(type(of: $0))" } ?? "none")")
                    }
                }
            }
            log("Documents tree:")
            for l in tree(Paths.documents, depth: 2) { log("  " + l) }
            log("---- end ----")
        }
    }

    private static func fmt(_ r: CGRect) -> String {
        return "x\(Int(r.minX)) y\(Int(r.minY)) w\(Int(r.width)) h\(Int(r.height))"
    }

    private static func insets(_ i: UIEdgeInsets) -> String {
        return "t\(Int(i.top)) l\(Int(i.left)) b\(Int(i.bottom)) r\(Int(i.right))"
    }

    private static func tree(_ url: URL, depth: Int) -> [String] {
        let fm = FileManager.default
        var out: [String] = []
        let items = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [])) ?? []
        if items.isEmpty { return ["(empty)"] }
        for item in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let v = try? item.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if v?.isDirectory == true {
                out.append(item.lastPathComponent + "/")
                if depth > 0 { out += tree(item, depth: depth - 1).map { "  " + $0 } }
            } else {
                let mb = Double(v?.fileSize ?? 0) / 1_048_576
                out.append(item.lastPathComponent + String(format: "  (%.1f MB)", mb))
            }
        }
        return out
    }
}
