import AppKit
import SwiftUI
import WebKit

@main
struct UmbraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup(id: "browser") {
            BrowserView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 820)
        .handlesExternalEvents(matching: ["*"])
        .commands { BrowserCommands() }

        // Tor windows: every site goes through the Tor network.
        WindowGroup("Tor Window", id: "tor", for: URL.self) { $url in
            BrowserView(initialURL: url, tor: true)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 820)
        .handlesExternalEvents(matching: [])

        Settings { SettingsView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        _ = AppSettings.shared
        _ = Blocker.shared                  // loads the domain rules off the first page load's path
        // WebKit crashes if a saved data store is removed before WebKit has started, so
        // start it first and run queued deletions a moment later.
        _ = WKWebView(frame: .zero)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { PendingDeletion.run() }
        DoHResolver.shared.start()
        Task { await ContentRules.shared.load() }
        SelfTest.runIfRequested()
        // ⌘W closes the tab (the window closes with its last tab).
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if mods == .command, event.charactersIgnoringModifiers == "w",
               let window = NSApp.keyWindow, let browser = BrowserRegistry.browser(for: window) {
                browser.closeSelected()
                return nil
            }
            return event
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Stats.shared.save()
        ContainerManager.shared.forgetAllUnremembered()
        TorService.shared.stop()
    }
}

/// Finds the BrowserState behind a window (for shortcuts handled outside SwiftUI).
@MainActor
enum BrowserRegistry {
    static func browser(for window: NSWindow) -> BrowserState? {
        all.first { $0.window === window }
    }
    private static var refs = NSHashTable<AnyObject>.weakObjects()
    static var all: [BrowserState] { refs.allObjects.compactMap { $0 as? BrowserState } }
    static func register(_ b: BrowserState) { refs.add(b) }
}

struct BrowserCommands: Commands {
    @FocusedValue(\.browser) private var browser
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Window") { openWindow(id: "browser") }.keyboardShortcut("n")
            Button("New Tor Window") { openWindow(id: "tor") }.keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button("New Tab") { browser?.newTab() }.keyboardShortcut("t")
            Button("Reopen Closed Tab") { browser?.reopenClosedTab() }.keyboardShortcut("t", modifiers: [.command, .shift])
            Button("Open Location…") { browser?.focusAddressBar() }.keyboardShortcut("l")
            Divider()
            Button("Close Tab") { browser?.closeSelected() }
            Button("New Tor Identity") { TorService.shared.newIdentity() }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(browser?.tor != true)
        }
        CommandGroup(after: .textEditing) {
            Divider()
            Button("Find…") { browser?.findVisible = true }.keyboardShortcut("f")
            Button("Find Next") { NotificationCenter.default.post(name: .umbraFindNext, object: false) }.keyboardShortcut("g")
            Button("Find Previous") { NotificationCenter.default.post(name: .umbraFindNext, object: true) }.keyboardShortcut("g", modifiers: [.command, .shift])
        }
        CommandGroup(before: .toolbar) {
            Button("Reload Page") { browser?.selected?.reload() }.keyboardShortcut("r")
            Button("Stop") { browser?.selected?.stop() }.keyboardShortcut(".")
            Divider()
            Button("Zoom In") { if let t = browser?.selected { t.setZoom(t.pageZoom + 0.1) } }.keyboardShortcut("=")
            Button("Zoom Out") { if let t = browser?.selected { t.setZoom(t.pageZoom - 0.1) } }.keyboardShortcut("-")
            Button("Actual Size") { browser?.selected?.setZoom(1) }.keyboardShortcut("0")
            Divider()
        }
        CommandMenu("History") {
            Button("Back") { browser?.selected?.goBack() }.keyboardShortcut("[")
            Button("Forward") { browser?.selected?.goForward() }.keyboardShortcut("]")
            Divider()
            Button("Clear History") { HistoryStore.shared.clearAll() }
        }
        CommandMenu("Bookmarks") {
            Button("Bookmark This Page") {
                if let t = browser?.selected, let u = t.url { BookmarkStore.shared.toggle(u, title: t.title) }
            }.keyboardShortcut("d")
        }
        CommandGroup(before: .windowArrangement) {
            Button("Show Next Tab") { browser?.selectNext(1) }.keyboardShortcut(.tab, modifiers: .control)
            Button("Show Previous Tab") { browser?.selectNext(-1) }.keyboardShortcut(.tab, modifiers: [.control, .shift])
            ForEach(1..<10) { n in
                Button(n == 9 ? "Last Tab" : "Tab \(n)") { browser?.select(number: n) }.keyboardShortcut(KeyEquivalent(Character("\(n)")))
            }
            Divider()
        }
    }
}
