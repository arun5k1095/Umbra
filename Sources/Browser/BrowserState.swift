import AppKit
import SwiftUI

/// The tabs of one browser window.
@MainActor
final class BrowserState: ObservableObject {
    @Published var tabs: [Tab] = []
    @Published var selectedID: UUID?
    @Published var focusAddressToken = 0
    @Published var findVisible = false
    @Published var shieldPanelOpen = false
    weak var window: NSWindow?
    private var closed: [URL] = []
    private var timer: Timer?

    init(initialURL: URL? = nil) {
        BrowserRegistry.register(self)
        newTab(url: initialURL)
        // Refreshes the shield badge of the visible tab. Cheap: reads one counter.
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.selected?.refreshBlockedCount() }
        }
    }

    deinit { timer?.invalidate() }

    var selected: Tab? { tabs.first { $0.id == selectedID } ?? tabs.first }
    var selectedIndex: Int? { tabs.firstIndex { $0.id == selectedID } }

    @discardableResult
    func newTab(url: URL? = nil, after: Tab? = nil, select: Bool = true) -> Tab {
        let tab = Tab(browser: self, url: url)
        insert(tab, after: after, select: select)
        if url == nil && select { focusAddressBar() }
        return tab
    }

    func insert(_ tab: Tab, after: Tab?, select: Bool) {
        tab.browser = self
        if let after, let i = tabs.firstIndex(where: { $0 === after }) { tabs.insert(tab, at: i + 1) } else { tabs.append(tab) }
        if select || selectedID == nil { selectedID = tab.id }
    }

    func close(_ tab: Tab) {
        guard let i = tabs.firstIndex(where: { $0 === tab }) else { return }
        if let u = tab.url { closed.append(u); if closed.count > 20 { closed.removeFirst() } }
        tab.close()
        tabs.remove(at: i)
        if tabs.isEmpty { window?.close(); return }
        if selectedID == tab.id { selectedID = tabs[min(i, tabs.count - 1)].id }
    }

    func closeSelected() { if let t = selected { close(t) } }

    func reopenClosedTab() { if let u = closed.popLast() { newTab(url: u) } }

    func select(_ tab: Tab) { selectedID = tab.id }

    func select(number: Int) {
        guard !tabs.isEmpty else { return }
        let i = number == 9 ? tabs.count - 1 : number - 1
        if tabs.indices.contains(i) { selectedID = tabs[i].id }
    }

    func selectNext(_ step: Int) {
        guard let i = selectedIndex, !tabs.isEmpty else { return }
        selectedID = tabs[(i + step + tabs.count) % tabs.count].id
    }

    func move(_ tab: Tab, to index: Int) {
        guard let from = tabs.firstIndex(where: { $0 === tab }) else { return }
        let t = tabs.remove(at: from)
        tabs.insert(t, at: min(max(index, 0), tabs.count))
    }

    func focusAddressBar() { focusAddressToken += 1 }
}
