import SwiftUI
import WebKit

/// The shield popover: what Umbra did on this page, in plain words, plus per-site controls.
struct ShieldPanel: View {
    @ObservedObject var tab: Tab
    @ObservedObject private var settings = AppSettings.shared
    @State private var snap: SiteReport.Snapshot?
    @State private var showConnections = false
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        let site = tab.site ?? ""
        let on = settings.shieldsOn(for: tab.site)
        let remembered = settings.rememberedSites[site] != nil
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: on ? "shield.lefthalf.filled" : "shield.slash")
                    .font(.system(size: 26, weight: .semibold)).foregroundStyle(on ? Color.umbra : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(site.isEmpty ? "New Tab" : site).font(.headline).lineLimit(1)
                    Text(on ? "Protected" : "Protections off for this site").font(.subheadline).foregroundStyle(on ? Color.umbra : .orange)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { on }, set: { v in
                    if v { settings.shieldsOff.remove(site) } else { settings.shieldsOff.insert(site) }
                    ContainerManager.shared.apply(site: site)
                    tab.reload()
                })).toggleStyle(.switch).labelsHidden().disabled(site.isEmpty)
                    .help("Turn protections off if this site doesn't work")
            }

            if on, let s = snap {
                HStack(spacing: 10) {
                    StatTile(value: s.trackers, label: "Trackers", color: .umbra)
                    StatTile(value: s.ads, label: "Ads", color: .pink)
                    StatTile(value: s.contacted.count, label: "Servers contacted", color: .gray)
                }
                if !s.blocked.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Blocked on this page").font(.caption).foregroundStyle(.secondary)
                        ForEach(s.blocked.prefix(8), id: \.host) { e in
                            HStack(spacing: 6) {
                                Circle().fill(e.category == .ad ? Color.pink : Color.umbra).frame(width: 6, height: 6)
                                Text(TrackerOwners.owner(of: e.host).map { "\($0) · \(e.host)" } ?? e.host)
                                    .font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                if e.count > 1 { Text("×\(e.count)").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit() }
                            }
                        }
                        if s.blocked.count > 8 { Text("and \(s.blocked.count - 8) more").font(.caption).foregroundStyle(.secondary) }
                        Text("Counts connections Umbra refused. Ad and tracker files stopped inside WebKit's filters aren't counted, so the real number is higher.")
                            .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("Nothing on this page tried to track you through a known tracker or ad server.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                DisclosureGroup(isExpanded: $showConnections) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(s.contacted, id: \.self) { h in
                            Text(h).font(.system(size: 11, design: .monospaced)).foregroundStyle(h == site || h.hasSuffix("." + site) ? .secondary : .primary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Text("Servers this page connected to").font(.caption)
                }
            }

            Divider()
            VStack(alignment: .leading, spacing: 8) {
                InfoRow(symbol: tab.isSecure ? "lock.fill" : "lock.open.fill", color: tab.isSecure ? .green : .orange,
                        text: tab.isSecure ? "Encrypted connection (HTTPS)" : "This page isn't fully encrypted")
                if tab.tor {
                    InfoRow(symbol: "network.badge.shield.half.filled", color: .tor,
                            text: "Through Tor on this site's own circuit. The site sees a Tor address, and your network sees only Tor.")
                } else {
                    InfoRow(symbol: settings.dns == .system ? "network" : "lock.shield", color: settings.dns == .system ? .orange : .green,
                            text: settings.dns == .system ? "DNS lookups aren't encrypted" : "DNS encrypted via \(settings.dns.shortName)")
                }
                InfoRow(symbol: "square.on.square.dashed", color: .green, text: "Sealed off from other sites' cookies")
                if on && settings.fingerprintProtection { InfoRow(symbol: "hand.raised.fill", color: .green, text: "Fingerprinting made harder") }
            }

            if !tab.tor {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: Binding(get: { remembered }, set: { v in
                    if v { ContainerManager.shared.remember(site) } else { ContainerManager.shared.forget(site) }
                    tab.reopenInFreshContainer()
                })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Stay signed in to \(site.isEmpty ? "this site" : site)").font(.system(size: 12, weight: .medium))
                        Text(remembered ? "Cookies and logins for this site are kept after you quit." :
                                "Cookies and logins are forgotten when you quit Umbra.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch).controlSize(.small).disabled(site.isEmpty)
                Button(role: .destructive) {
                    ContainerManager.shared.forget(site)
                    tab.reopenInFreshContainer()
                } label: { Label("Forget this site now", systemImage: "trash") }
                    .buttonStyle(.link).disabled(site.isEmpty)
            }
            }
        }
        .padding(16)
        .frame(width: 340)
        .onAppear { snap = tab.container?.proxy.report.snapshot() }
        .onReceive(timer) { _ in snap = tab.container?.proxy.report.snapshot() }
    }
}

private struct StatTile: View {
    let value: Int, label: String, color: Color
    var body: some View {
        VStack(spacing: 2) {
            Text("\(value)").font(.system(size: 22, weight: .semibold, design: .rounded)).foregroundStyle(color).monospacedDigit()
                .contentTransition(.numericText())
            Text(label).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9).fill(color.opacity(0.08)))
    }
}

private struct InfoRow: View {
    let symbol: String, color: Color, text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color).frame(width: 16)
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct NewTabPage: View {
    @ObservedObject var browser: BrowserState
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var bookmarks = BookmarkStore.shared
    @State private var tick = 0
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                Spacer(minLength: 50)
                if browser.tor {
                    VStack(spacing: 10) {
                        Image(systemName: "network.badge.shield.half.filled")
                            .font(.system(size: 54, weight: .semibold))
                            .foregroundStyle(LinearGradient(colors: [.tor, .purple], startPoint: .top, endPoint: .bottom))
                        Text("Tor Window").font(.system(size: 34, weight: .bold, design: .rounded))
                        Text("Sites see a Tor address instead of yours. Your network operator sees only that you use Tor.")
                            .font(.system(size: 14)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 520)
                        TorStatusLine().padding(.top, 4)
                    }
                } else {
                VStack(spacing: 10) {
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.system(size: 54, weight: .semibold))
                        .foregroundStyle(LinearGradient(colors: [.umbra, .purple], startPoint: .top, endPoint: .bottom))
                    Text("Umbra").font(.system(size: 34, weight: .bold, design: .rounded))
                    Text("Private by default. Nothing about you leaves this Mac unless you send it.")
                        .font(.system(size: 14)).foregroundStyle(.secondary)
                }
                }
                Button { browser.focusAddressBar() } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        Text("Search \(settings.searchEngine.label) or enter a website").foregroundStyle(.secondary)
                        Spacer()
                        Text("⌘L").font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 16).frame(width: 560, height: 46)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.surface))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
                    .shadow(color: .black.opacity(0.06), radius: 8, y: 3)
                }
                .buttonStyle(.plain)

                HStack(spacing: 14) {
                    BigStat(value: Stats.shared.today(.tracker), label: "Trackers blocked today", symbol: "eye.slash.fill", color: .umbra)
                    BigStat(value: Stats.shared.today(.ad), label: "Ads blocked today", symbol: "rectangle.badge.xmark", color: .pink)
                    BigStat(value: Stats.shared.today(.linkCleaned), label: "Links cleaned", symbol: "link", color: .teal)
                    BigStat(value: Stats.shared.today(.httpsUpgrade), label: "Upgraded to HTTPS", symbol: "lock.fill", color: .green)
                }
                .id(tick)
                .frame(width: 640)

                if settings.showBookmarksOnNewTab && !bookmarks.items.isEmpty {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(96), spacing: 16), count: 6), spacing: 16) {
                        ForEach(bookmarks.items) { b in
                            Button { browser.selected?.load(b.url) } label: {
                                VStack(spacing: 6) {
                                    Text(String((b.url.host() ?? "?").replacingOccurrences(of: "www.", with: "").prefix(1)).uppercased())
                                        .font(.system(size: 20, weight: .semibold, design: .rounded)).foregroundStyle(Color.umbra)
                                        .frame(width: 52, height: 52)
                                        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color.umbra.opacity(0.10)))
                                    Text(b.title).font(.system(size: 11)).lineLimit(1).frame(width: 90)
                                }
                            }
                            .buttonStyle(.plain)
                            .contextMenu { Button("Remove Bookmark", role: .destructive) { bookmarks.remove(b) } }
                        }
                    }
                    .frame(width: 640)
                }

                HStack(spacing: 18) {
                    if browser.tor {
                        Label("Separate Tor circuit per site", systemImage: "point.3.connected.trianglepath.dotted")
                        Label("No history", systemImage: "clock.badge.xmark")
                        Label("Nothing kept after closing", systemImage: "clock.arrow.circlepath")
                    } else {
                        Label(settings.dns == .system ? "DNS not encrypted" : "Encrypted DNS · \(settings.dns.shortName)", systemImage: "lock.shield")
                        Label("Each site sealed in its own container", systemImage: "square.on.square.dashed")
                        Label("Forgotten when you quit", systemImage: "clock.arrow.circlepath")
                    }
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 40)
            }
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.35))
        .onReceive(timer) { _ in tick += 1 }
    }
}

private struct BigStat: View {
    let value: Int, label: String, symbol: String, color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(color)
            Text(value.formatted()).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.surface))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
    }
}

struct ProblemView: View {
    @ObservedObject var tab: Tab
    let problem: Tab.Problem
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var tor = TorService.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: symbol).font(.system(size: 44, weight: .semibold)).foregroundStyle(color)
            Text(title).font(.system(size: 22, weight: .semibold))
            Text(message).font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
            HStack(spacing: 10) {
                if tab.canGoBack { Button("Go Back") { tab.problem = nil; tab.goBack() } }
                switch problem {
                case .insecure(let u):
                    Button("Continue Without HTTPS") { tab.allowInsecure(u) }
                case .blocked(let u, _):
                    Button("Load Anyway") { tab.allowBlockedPage(u) }
                case .needsTor(let u):
                    Button("Open in Tor Window") { openWindow(id: "tor", value: u) }.keyboardShortcut(.defaultAction)
                default:
                    Button("Try Again") { tab.reload() }.keyboardShortcut(.defaultAction)
                }
            }
            .controlSize(.large)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.chrome)
    }

    private var host: String {
        switch problem {
        case .insecure(let u), .unreachable(let u, _), .blocked(let u, _), .needsTor(let u): return u.host() ?? u.absoluteString
        case .crashed: return tab.site ?? ""
        }
    }
    private var symbol: String {
        switch problem {
        case .insecure: return "lock.open.trianglebadge.exclamationmark"
        case .unreachable: return "wifi.exclamationmark"
        case .blocked: return "hand.raised.fill"
        case .needsTor: return "network.badge.shield.half.filled"
        case .crashed: return "exclamationmark.triangle.fill"
        }
    }
    private var color: Color {
        switch problem { case .blocked: return .umbra; case .needsTor: return .tor; case .crashed: return .orange; default: return .orange }
    }
    private var title: String {
        switch problem {
        case .insecure: return "\(host) doesn't support a secure connection"
        case .unreachable: return "Can't open this page"
        case .blocked: return "Umbra blocked this page"
        case .needsTor: return "Onion sites open in a Tor window"
        case .crashed: return "This page stopped working"
        }
    }
    private var message: String {
        switch problem {
        case .insecure:
            return "Umbra tried the encrypted (HTTPS) version first, but it isn't available. Without it, anyone on your network could see or change what you send to this site."
        case .unreachable(_, let detail):
            if tab.tor {
                let status: String
                switch tor.state {
                case .failed(let m): status = " " + m
                case .connecting(let p, _): status = " Tor is still connecting (\(p)%)."
                default: status = ""
                }
                return "\(host) couldn't be reached: \(detail).\(status)"
            }
            let dns = settings.dns == .system ? "" : " Your lookups are encrypted via \(settings.dns.shortName); if the problem continues, try another DNS provider in Settings."
            return "\(host) couldn't be reached: \(detail).\(dns)"
        case .blocked(_, let h):
            return "\(h) is on a list of known trackers or ad servers. Loading it anyway turns protections off for this site."
        case .needsTor:
            return "\(host) is an onion service: it can only be reached through the Tor network. Normal windows never use Tor, so open it in a Tor window."
        case .crashed:
            return "The page used too much memory or hit an error. Reloading usually fixes it."
        }
    }
}

struct FindBar: View {
    @ObservedObject var browser: BrowserState
    @ObservedObject var tab: Tab
    @State private var query = ""
    @State private var found: Bool?
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find on page", text: $query)
                .textFieldStyle(.plain).frame(width: 200).focused($focused)
                .onSubmit { find(backwards: NSEvent.modifierFlags.contains(.shift)) }
                .onChange(of: query) { find(backwards: false) }
                .onKeyPress(.escape) { close(); return .handled }
            if found == false { Text("Not found").font(.caption).foregroundStyle(.secondary) }
            Button { find(backwards: true) } label: { Image(systemName: "chevron.up") }.buttonStyle(.borderless)
            Button { find(backwards: false) } label: { Image(systemName: "chevron.down") }.buttonStyle(.borderless)
            Button { close() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
        .onAppear { focused = true }
        .onReceive(NotificationCenter.default.publisher(for: .umbraFindNext)) { n in find(backwards: (n.object as? Bool) ?? false) }
    }

    private func find(backwards: Bool) {
        guard !query.isEmpty, let wv = tab.webView else { found = nil; return }
        let cfg = WKFindConfiguration()
        cfg.backwards = backwards
        cfg.wraps = true
        wv.find(query, configuration: cfg) { r in found = r.matchFound }
    }

    private func close() { browser.findVisible = false; if let wv = tab.webView { wv.window?.makeFirstResponder(wv) } }
}

extension Notification.Name { static let umbraFindNext = Notification.Name("umbraFindNext") }
