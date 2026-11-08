import AppKit
import SwiftUI
import WebKit

extension Color {
    static let umbra = Color(red: 0.40, green: 0.33, blue: 0.93)
    static let chrome = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let tor = Color(red: 0.49, green: 0.27, blue: 0.62)
    /// Tor windows get a violet-tinted frame so you always know which kind of window you're in.
    static let torChrome = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.17, green: 0.12, blue: 0.24, alpha: 1)
            : NSColor(red: 0.91, green: 0.88, blue: 0.97, alpha: 1)
    })
}

struct BrowserView: View {
    @StateObject private var browser: BrowserState
    @ObservedObject private var settings = AppSettings.shared

    private let tor: Bool
    init(initialURL: URL? = nil, tor: Bool = false) {
        self.tor = tor
        _browser = StateObject(wrappedValue: BrowserState(initialURL: initialURL, tor: tor))
    }

    var body: some View {
        VStack(spacing: 0) {
            TabStrip(browser: browser)
            if let tab = browser.selected {
                ToolbarRow(browser: browser, tab: tab).id(tab.id).zIndex(2)
            }
            Divider()
            ZStack(alignment: .topTrailing) {
                if let tab = browser.selected {
                    TabContent(browser: browser, tab: tab).id(tab.id)
                }
                if browser.findVisible, let tab = browser.selected {
                    FindBar(browser: browser, tab: tab).padding(10)
                }
            }
        }
        .background(tor ? Color.torChrome : Color.chrome)
        .ignoresSafeArea(.container, edges: .top)
        .background(WindowAccessor { browser.window = $0 })
        .focusedSceneValue(\.browser, browser)
        .onOpenURL { if !tor { browser.newTab(url: $0) } }       // links from other apps never open over Tor by surprise
        .frame(minWidth: 640, minHeight: 420)
    }
}

/// What the selected tab shows: the page, the new-tab page, or a problem page.
struct TabContent: View {
    @ObservedObject var browser: BrowserState
    @ObservedObject var tab: Tab

    var body: some View {
        ZStack {
            if tab.webView != nil { WebContainer(tab: tab).opacity(tab.problem == nil ? 1 : 0) }
            if tab.isNewTabPage { NewTabPage(browser: browser) }
            if let p = tab.problem { ProblemView(tab: tab, problem: p) }
        }
    }
}

/// Hosts the tab's current WKWebView.
struct WebContainer: NSViewRepresentable {
    @ObservedObject var tab: Tab

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {
        guard let wv = tab.webView else { v.subviews.forEach { $0.removeFromSuperview() }; return }
        if wv.superview !== v {
            v.subviews.forEach { $0.removeFromSuperview() }
            wv.frame = v.bounds
            wv.autoresizingMask = [.width, .height]
            v.addSubview(wv)
            DispatchQueue.main.async {
                if let w = v.window, !(w.firstResponder is NSText) { w.makeFirstResponder(wv) }
            }
        }
    }
}

struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            if let w = v.window {
                w.tabbingMode = .disallowed
                w.titlebarAppearsTransparent = true
                onWindow(w)
            }
        }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {}
}

/// Empty chrome areas that move the window and zoom on double-click, like a title bar.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
                if action == "Minimize" { window?.performMiniaturize(nil) } else if action != "None" { window?.performZoom(nil) }
            } else {
                window?.performDrag(with: event)
            }
        }
        override var mouseDownCanMoveWindow: Bool { true }
    }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ v: NSView, context: Context) {}
}

struct BrowserKey: FocusedValueKey { typealias Value = BrowserState }
extension FocusedValues {
    var browser: BrowserState? {
        get { self[BrowserKey.self] }
        set { self[BrowserKey.self] = newValue }
    }
}
