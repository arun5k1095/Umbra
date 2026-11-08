import SwiftUI
import WebKit

struct ToolbarRow: View {
    @ObservedObject var browser: BrowserState
    @ObservedObject var tab: Tab
    @ObservedObject private var downloads = DownloadManager.shared
    @State private var showDownloads = false

    var body: some View {
        HStack(spacing: 4) {
            navButton("chevron.left", "Back (⌘[)", enabled: tab.canGoBack) { tab.goBack() }
            navButton("chevron.right", "Forward (⌘])", enabled: tab.canGoForward) { tab.goForward() }
            navButton(tab.isLoading ? "xmark" : "arrow.clockwise", tab.isLoading ? "Stop" : "Reload (⌘R)",
                      enabled: tab.webView != nil || tab.problem != nil) { tab.isLoading ? tab.stop() : tab.reload() }
                .padding(.trailing, 4)

            if browser.tor { TorBadge() }
            AddressBar(browser: browser, tab: tab, showShield: $browser.shieldPanelOpen)

            if !downloads.items.isEmpty {
                Button { showDownloads.toggle() } label: {
                    ZStack {
                        Image(systemName: "arrow.down.circle").font(.system(size: 15))
                        if downloads.active > 0 { ProgressRing(value: downloads.items.first?.fraction ?? 0).frame(width: 21, height: 21) }
                    }
                    .frame(width: 30, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(ChromeButtonStyle())
                .help("Downloads")
                .popover(isPresented: $showDownloads, arrowEdge: .bottom) { DownloadsPanel() }
            }

            Menu {
                Button(BookmarkStore.shared.contains(tab.url) ? "Remove Bookmark" : "Bookmark This Page") {
                    if let u = tab.url { BookmarkStore.shared.toggle(u, title: tab.title) }
                }.disabled(tab.url == nil)
                Button("Find on Page…") { browser.findVisible = true }.disabled(tab.webView == nil)
                Divider()
                Button("Zoom In") { tab.setZoom(tab.pageZoom + 0.1) }
                Button("Zoom Out") { tab.setZoom(tab.pageZoom - 0.1) }
                Button("Actual Size") { tab.setZoom(1) }
                Divider()
                SettingsLink { Text("Settings…") }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 14, weight: .semibold)).frame(width: 30, height: 28)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
        .background(WindowDragArea())
        .overlay(alignment: .bottom) {
            if tab.isLoading {
                GeometryReader { g in
                    Rectangle().fill(Color.umbra).frame(width: g.size.width * max(0.06, tab.progress), height: 2)
                        .animation(.easeOut(duration: 0.25), value: tab.progress)
                }
                .frame(height: 2)
            }
        }
    }

    private func navButton(_ symbol: String, _ help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14, weight: .medium)).frame(width: 30, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(ChromeButtonStyle())
        .disabled(!enabled)
        .help(help)
    }
}

struct ProgressRing: View {
    let value: Double
    var body: some View {
        Circle().trim(from: 0, to: value).stroke(Color.umbra, style: StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(-90))
    }
}

struct AddressBar: View {
    @ObservedObject var browser: BrowserState
    @ObservedObject var tab: Tab
    @Binding var showShield: Bool
    @ObservedObject private var settings = AppSettings.shared
    @State private var text = ""
    @State private var suggestions: [Visit] = []
    @State private var highlighted = -1
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: leadingSymbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(leadingColor)
                .frame(width: 14)
                .help(leadingHelp)
            TextField("Search \(settings.searchEngine.label) or enter a website", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
                .onSubmit(go)
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.escape) { focused = false; text = display; return .handled }
            if tab.url != nil && !focused {
                Button { if let u = tab.url { BookmarkStore.shared.toggle(u, title: tab.title) } } label: {
                    Image(systemName: BookmarkStore.shared.contains(tab.url) ? "star.fill" : "star")
                        .font(.system(size: 12)).foregroundStyle(BookmarkStore.shared.contains(tab.url) ? Color.yellow : .secondary)
                        .frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Bookmark (⌘D)")
            }
            ShieldButton(tab: tab, show: $showShield)
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(nsColor: .textBackgroundColor).opacity(focused ? 1 : 0.55)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(focused ? Color.umbra.opacity(0.7) : Color.primary.opacity(0.08), lineWidth: focused ? 2 : 1))
        .overlay(alignment: .topLeading) {
            if focused && !suggestions.isEmpty {
                SuggestionList(items: suggestions, highlighted: highlighted, query: text) { pick($0) }
                    .offset(y: 36)
            }
        }
        .onAppear { text = display; if tab.url == nil && browser.selected === tab { focused = true } }
        .onChange(of: tab.url) { if !focused { text = display } }
        .onChange(of: focused) {
            if focused {
                text = tab.url?.absoluteString ?? ""
                DispatchQueue.main.async { NSApp.sendAction(#selector(NSResponder.selectAll(_:)), to: nil, from: nil) }
            } else {
                suggestions = []; text = display
            }
        }
        .onChange(of: text) {
            guard focused else { return }
            suggestions = text == tab.url?.absoluteString ? [] : HistoryStore.shared.suggestions(for: text)
            highlighted = -1
        }
        .onChange(of: browser.focusAddressToken) { if browser.selected === tab { focused = true } }
    }

    private var display: String {
        guard let u = tab.url else { return "" }
        if tab.problem != nil { return u.absoluteString }
        var host = u.host() ?? u.absoluteString
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let path = u.path() == "/" ? "" : u.path()
        return host + path
    }

    private var leadingSymbol: String {
        if focused || tab.url == nil { return "magnifyingglass" }
        return tab.isSecure ? "lock.fill" : "lock.open.fill"
    }
    private var leadingColor: Color { (focused || tab.url == nil) ? .secondary : (tab.isSecure ? .secondary : .orange) }
    private var leadingHelp: String {
        if tab.url == nil { return "Search or enter a website" }
        return tab.isSecure ? "Secure connection (HTTPS)" : "Not secure: this page isn't fully encrypted"
    }

    private func move(_ d: Int) {
        guard !suggestions.isEmpty else { return }
        highlighted = max(-1, min(suggestions.count - 1, highlighted + d))
    }

    private func go() {
        if highlighted >= 0, suggestions.indices.contains(highlighted) { return pick(suggestions[highlighted]) }
        guard let url = AddressInput.resolve(text) else { return }
        focused = false
        tab.load(url)
    }

    private func pick(_ v: Visit) {
        focused = false
        tab.load(v.url)
    }
}

struct SuggestionList: View {
    let items: [Visit]
    let highlighted: Int
    let query: String
    let onPick: (Visit) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element) { i, v in
                Button { onPick(v) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: v.date == .distantFuture ? "star.fill" : "clock")
                            .font(.system(size: 11)).foregroundStyle(v.date == .distantFuture ? Color.yellow : .secondary).frame(width: 14)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(v.title.isEmpty ? (v.url.host() ?? "") : v.title).font(.system(size: 13)).lineLimit(1)
                            Text(v.url.absoluteString).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(i == highlighted ? Color.umbra.opacity(0.15) : .clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .frame(width: 520, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
    }
}

/// Shows that this is a Tor window and whether Tor is connected; click for details.
struct TorBadge: View {
    @ObservedObject private var tor = TorService.shared
    @State private var show = false

    var body: some View {
        Button { show.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: "network.badge.shield.half.filled").font(.system(size: 12, weight: .semibold))
                Text(label).font(.system(size: 11, weight: .semibold)).monospacedDigit()
            }
            .foregroundStyle(color)
            .padding(.horizontal, 9).frame(height: 24)
            .background(Capsule().fill(color.opacity(0.15)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(.trailing, 4)
        .help("Tor connection")
        .popover(isPresented: $show, arrowEdge: .bottom) { TorPanel().frame(width: 320) }
    }

    private var label: String {
        switch tor.state {
        case .ready: return "Tor"
        case .connecting(let p, _): return "Tor \(p)%"
        case .failed: return "Tor ⚠︎"
        case .off: return "Tor off"
        }
    }
    private var color: Color {
        switch tor.state { case .ready: return .tor; case .failed: return .orange; default: return .secondary }
    }
}

struct TorPanel: View {
    @ObservedObject private var tor = TorService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "network.badge.shield.half.filled").font(.system(size: 24, weight: .semibold)).foregroundStyle(Color.tor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tor Window").font(.headline)
                    TorStatusLine()
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("• Sites see a Tor exit address, not yours.")
                Text("• Your network operator sees only that you use Tor, not which sites.")
                Text("• Every site gets its own circuit and its own memory-only container.")
                Text("• Nothing from this window is kept: no history, no cookies after you close it.")
            }
            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button { tor.newIdentity() } label: { Label("New Identity", systemImage: "arrow.triangle.2.circlepath") }
                    .disabled(!tor.isReady)
                    .help("New circuits and empty containers for every tab in Tor windows (⇧⌘U)")
                Spacer()
                if !tor.version.isEmpty { Text("Tor \(tor.version)").font(.caption).foregroundStyle(.tertiary) }
            }
        }
        .padding(16)
    }
}

struct TorStatusLine: View {
    @ObservedObject private var tor = TorService.shared
    var body: some View {
        switch tor.state {
        case .ready:
            Label("Connected to the Tor network", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.subheadline)
        case .connecting(let p, let s):
            VStack(alignment: .leading, spacing: 4) {
                Text("Connecting to Tor… \(p)%").font(.subheadline).foregroundStyle(.secondary)
                ProgressView(value: Double(p), total: 100).tint(Color.tor).frame(maxWidth: 220)
                if !s.isEmpty { Text(s).font(.caption2).foregroundStyle(.tertiary).lineLimit(1) }
            }
        case .failed(let m):
            Text(m).font(.subheadline).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        case .off:
            Text("Not running").font(.subheadline).foregroundStyle(.secondary)
        }
    }
}

struct ShieldButton: View {
    @ObservedObject var tab: Tab
    @Binding var show: Bool
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        let on = settings.shieldsOn(for: tab.site)
        Button { show.toggle() } label: {
            HStack(spacing: 3) {
                Image(systemName: on ? "shield.lefthalf.filled" : "shield.slash")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(on ? Color.umbra : .secondary)
                if on && tab.blockedCount > 0 {
                    Text("\(tab.blockedCount)").font(.system(size: 11, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(Color.umbra).contentTransition(.numericText())
                }
            }
            .padding(.horizontal, 6).frame(height: 24)
            .background(Capsule().fill(Color.umbra.opacity(on ? 0.12 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(on ? "Privacy protections are on" : "Protections are off for this site")
        .popover(isPresented: $show, arrowEdge: .bottom) { ShieldPanel(tab: tab) }
    }
}

struct DownloadsPanel: View {
    @ObservedObject private var downloads = DownloadManager.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Downloads").font(.headline)
                Spacer()
                Button("Clear") { downloads.clearFinished() }.buttonStyle(.link)
            }
            ForEach(downloads.items) { DownloadRow(item: $0) }
        }
        .padding(14)
        .frame(width: 340)
    }
}

private struct DownloadRow: View {
    @ObservedObject var item: DownloadManager.Item
    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(for: .init(filenameExtension: item.destination.pathExtension) ?? .data))
                .resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.filename).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                switch item.state {
                case .running: ProgressView(value: item.fraction).controlSize(.small)
                case .done: Text("Done").font(.caption).foregroundStyle(.secondary)
                case .failed(let m): Text(m).font(.caption).foregroundStyle(.red).lineLimit(1)
                }
            }
            Spacer()
            if item.state == .running {
                Button { DownloadManager.shared.cancel(item) } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary)
            } else if item.state == .done {
                Button { DownloadManager.shared.reveal(item) } label: { Image(systemName: "magnifyingglass.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Show in Finder")
            }
        }
    }
}
