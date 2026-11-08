import Foundation
import WebKit

/// WebKit content blocking for path-level ad and tracker rules and for hiding empty ad
/// slots. The lists are compiled once and cached by WebKit; later launches load in ms.
@MainActor
final class ContentRules {
    static let shared = ContentRules()
    private(set) var lists: [String: WKContentRuleList] = [:]
    private(set) var ready = false
    private(set) var ruleCounts: [String: Int] = [:]

    private let names = ["rules-privacy", "rules-ads", "rules-cosmetic"]

    func load() async {
        guard let store = WKContentRuleListStore.default() else { return }
        for name in names {
            guard let url = Bundle.main.url(forResource: name, withExtension: "json", subdirectory: "lists") ??
                            Bundle.main.url(forResource: name, withExtension: "json") else { continue }
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? Int) ?? 0
            let id = "umbra.\(name).\(size)"
            if let list = try? await store.contentRuleList(forIdentifier: id) {
                lists[name] = list
            } else if let json = try? String(contentsOf: url, encoding: .utf8),
                      let list = try? await store.compileContentRuleList(forIdentifier: id, encodedContentRuleList: json) {
                lists[name] = list
            }
            if let data = try? Data(contentsOf: url), let arr = try? JSONSerialization.jsonObject(with: data) as? [Any] {
                ruleCounts[name] = arr.count
            }
        }
        // Drop compiled lists from older versions.
        if let ids = await store.availableIdentifiers() {
            let keep = Set(names.map { n in lists[n]?.identifier }.compactMap { $0 })
            for id in ids where id.hasPrefix("umbra.") && !keep.contains(id) { try? await store.removeContentRuleList(forIdentifier: id) }
        }
        ready = true
        ContainerManager.shared.refreshAll()
    }

    func install(into ucc: WKUserContentController) {
        let s = AppSettings.shared
        if s.blockTrackers, let l = lists["rules-privacy"] { ucc.add(l) }
        if s.blockAds, let l = lists["rules-ads"] { ucc.add(l) }
        if s.blockAds && s.hideAdSpaces, let l = lists["rules-cosmetic"] { ucc.add(l) }
    }
}
