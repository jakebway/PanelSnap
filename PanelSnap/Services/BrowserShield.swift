import Foundation
import WebKit

/// The browser's ad blocker. The filter lists (built from EasyList by Scripts/build_adblock.py) are bundled as
/// WebKit content-blocker JSON, compiled once on the device and then cached by WebKit, so later launches are instant.
/// Every list compiles on its own: if one ever fails, the others still protect the page.
@MainActor
final class BrowserShield: ObservableObject {
    static let shared = BrowserShield()

    @Published private(set) var isReady = false
    @Published private(set) var status = ""
    private(set) var lists: [WKContentRuleList] = []
    private var running: Task<Void, Never>?

    func prepare() async {
        if isReady { return }
        if let running = running { await running.value; return }
        let task = Task { await self.compileAll() }
        running = task
        await task.value
    }

    // MARK: Where the lists come from
    // A complete, downloaded set (see `refreshIfDue`) wins over the set bundled with the app.

    private static let updatesFolder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("AdBlock", isDirectory: true)
    }()
    private static let feed = "https://raw.githubusercontent.com/jakebway/panelsnap/adblock-lists/"

    private func downloadedNames() -> [String]? {
        guard let data = try? Data(contentsOf: Self.updatesFolder.appendingPathComponent("manifest.json")),
              let m = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = m["files"] as? [String], !files.isEmpty else { return nil }
        let names = files.map { ($0 as NSString).deletingPathExtension }
        for n in names where !FileManager.default.fileExists(atPath: Self.updatesFolder.appendingPathComponent(n + ".json").path) {
            return nil
        }
        return names
    }

    private func listData(_ name: String, downloaded: Bool) -> Data? {
        if downloaded { return try? Data(contentsOf: Self.updatesFolder.appendingPathComponent(name + ".json")) }
        guard let url = Bundle.main.url(forResource: name, withExtension: "json") else { return nil }
        return try? Data(contentsOf: url)
    }

    private func listNames() -> [String] {
        var names: [String] = []
        var n = 1
        while Bundle.main.url(forResource: "shield-net-\(n)", withExtension: "json") != nil {
            names.append("shield-net-\(n)")
            n += 1
        }
        if Bundle.main.url(forResource: "shield-hide", withExtension: "json") != nil { names.append("shield-hide") }
        return names
    }

    /// Fetches newer lists (at most once a day, in the background, only when the published set changed). They are used
    /// from the next time the browser opens. If anything goes wrong the lists already in use are left alone.
    func refreshIfDue() async {
        let defaults = UserDefaults.standard
        if let last = defaults.object(forKey: "shieldCheckedAt") as? Date, Date().timeIntervalSince(last) < 20 * 3600 { return }
        guard let manifestURL = URL(string: Self.feed + "manifest.json"),
              let (mdata, mresp) = try? await URLSession.shared.data(from: manifestURL),
              (mresp as? HTTPURLResponse)?.statusCode == 200,
              let m = try? JSONSerialization.jsonObject(with: mdata) as? [String: Any],
              let version = m["version"] as? String, let files = m["files"] as? [String], !files.isEmpty,
              files.allSatisfy({ $0.hasPrefix("shield-") && $0.hasSuffix(".json") && !$0.contains("/") }) else { return }
        defaults.set(Date(), forKey: "shieldCheckedAt")
        if defaults.string(forKey: "shieldVersion") == version, downloadedNames() != nil { return }
        let staging = Self.updatesFolder.deletingLastPathComponent().appendingPathComponent("AdBlock-new", isDirectory: true)
        try? FileManager.default.removeItem(at: staging)
        try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        for f in files {
            guard let u = URL(string: Self.feed + f),
                  let (data, resp) = try? await URLSession.shared.data(from: u),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let rules = try? JSONSerialization.jsonObject(with: data) as? [Any], !rules.isEmpty else {
                Console.log("shield: update failed at \(f); keeping the current lists")
                try? FileManager.default.removeItem(at: staging)
                return
            }
            try? data.write(to: staging.appendingPathComponent(f))
        }
        try? mdata.write(to: staging.appendingPathComponent("manifest.json"))
        try? FileManager.default.removeItem(at: Self.updatesFolder)
        do { try FileManager.default.moveItem(at: staging, to: Self.updatesFolder) } catch { return }
        defaults.set(version, forKey: "shieldVersion")
        Console.log("shield: downloaded lists \(version)")
        // Compile them now, so they are ready (and used by new pages) without waiting for a relaunch.
        await compileAll(force: true)
    }

    private func compileAll(force: Bool = false) async {
        let store: WKContentRuleListStore? = WKContentRuleListStore.default()
        let downloaded = downloadedNames()
        let names = downloaded ?? listNames()
        if force { lists = [] }
        guard let store = store, !names.isEmpty else {
            Console.log("shield: no content rule store or no bundled lists")
            isReady = true
            return
        }
        for (i, name) in names.enumerated() {
            status = "Setting up the ad blocker (\(i + 1) of \(names.count))…"
            guard let data = listData(name, downloaded: downloaded != nil),
                  let json = String(data: data, encoding: .utf8) else { continue }
            // The size is part of the identifier, so a refreshed list is compiled again automatically.
            let id = "panelsnap.shield.\(name).\(data.count)"
            if let cached = await lookUp(store, id) {
                lists.append(cached)
                continue
            }
            if let fresh = await compile(store, id, json) {
                lists.append(fresh)
            }
        }
        Console.log("shield: \(lists.count) of \(names.count) lists active\(downloaded != nil ? " (updated set)" : "")")
        isReady = true
        // Forget compiled lists that are no longer in use, so old versions do not pile up.
        if let store = store {
            let keep = Set(names.compactMap { n in listData(n, downloaded: downloaded != nil).map { "panelsnap.shield.\(n).\($0.count)" } })
            let all: [String] = await withCheckedContinuation { cont in
                store.getAvailableContentRuleListIdentifiers { cont.resume(returning: $0 ?? []) }
            }
            for id in all where id.hasPrefix("panelsnap.shield.") && !keep.contains(id) {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    store.removeContentRuleList(forIdentifier: id) { _ in cont.resume() }
                }
            }
        }
    }

    private func lookUp(_ store: WKContentRuleListStore, _ id: String) async -> WKContentRuleList? {
        await withCheckedContinuation { cont in
            store.lookUpContentRuleList(forIdentifier: id) { list, _ in cont.resume(returning: list) }
        }
    }

    private func compile(_ store: WKContentRuleListStore, _ id: String, _ json: String) async -> WKContentRuleList? {
        await withCheckedContinuation { cont in
            store.compileContentRuleList(forIdentifier: id, encodedContentRuleList: json) { list, error in
                if let error = error { Console.log("shield: \(id) failed to compile: \(error.localizedDescription)") }
                cont.resume(returning: list)
            }
        }
    }
}
