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

    private func compileAll() async {
        let store: WKContentRuleListStore? = WKContentRuleListStore.default()
        let names = listNames()
        guard let store = store, !names.isEmpty else {
            Console.log("shield: no content rule store or no bundled lists")
            isReady = true
            return
        }
        for (i, name) in names.enumerated() {
            status = "Setting up the ad blocker (\(i + 1) of \(names.count))…"
            guard let url = Bundle.main.url(forResource: name, withExtension: "json"),
                  let data = try? Data(contentsOf: url),
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
        Console.log("shield: \(lists.count) of \(names.count) lists active")
        isReady = true
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
