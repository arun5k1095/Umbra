import SwiftUI
import WebKit

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            PrivacySettings().tabItem { Label("Privacy", systemImage: "shield.lefthalf.filled") }
            SitesSettings().tabItem { Label("Sites", systemImage: "square.on.square.dashed") }
            AboutSettings().tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 520)
    }
}

private struct GeneralSettings: View {
    @ObservedObject private var s = AppSettings.shared
    var body: some View {
        Form {
            Section {
                Picker("Search engine", selection: $s.searchEngine) {
                    ForEach(SearchEngine.allCases) { e in Text(e.label).tag(e) }
                }
                Text(s.searchEngine.privacyNote).font(.caption).foregroundStyle(.secondary)
                Text("Umbra never sends what you type until you press Return: no search suggestions are fetched.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Show bookmarks on the new tab page", isOn: $s.showBookmarksOnNewTab)
                Toggle(isOn: $s.rememberHistory) {
                    Text("Remember browsing history after quitting")
                    Text("Off: history lives only in memory and is gone when you quit.").font(.caption)
                }
            }
            Section {
                Toggle(isOn: $s.javaScript) {
                    Text("Allow JavaScript")
                    Text("Turning this off breaks most modern sites but removes most tracking techniques.").font(.caption)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct PrivacySettings: View {
    @ObservedObject private var s = AppSettings.shared
    var body: some View {
        Form {
            Section("Blocking") {
                Toggle(isOn: $s.blockTrackers) { Text("Block trackers"); Text("EasyPrivacy: analytics, beacons, data brokers").font(.caption) }
                Toggle(isOn: $s.blockAds) { Text("Block ads"); Text("EasyList").font(.caption) }
                Toggle("Hide empty ad spaces", isOn: $s.hideAdSpaces).disabled(!s.blockAds)
            }
            Section("Connection") {
                Picker("Encrypted DNS", selection: $s.dns) {
                    ForEach(DNSProvider.allCases) { Text($0.label).tag($0) }
                }
                Toggle(isOn: $s.httpsOnly) { Text("HTTPS-only"); Text("Always try the encrypted version of a site first, and warn before using an unencrypted one.").font(.caption) }
                Toggle(isOn: $s.blockWebRTC) { Text("Block WebRTC"); Text("Stops pages from discovering your real IP address. Video calls need protections off for that site.").font(.caption) }
            }
            Section("Tracking techniques") {
                Toggle(isOn: $s.fingerprintProtection) { Text("Fingerprinting protection"); Text("Adds per-site noise to canvas and audio readings and hides your exact CPU count.").font(.caption) }
                Toggle(isOn: $s.cleanLinks) { Text("Clean tracking links"); Text("Removes utm_, fbclid, gclid and similar, and skips redirect wrappers.").font(.caption) }
                Toggle(isOn: $s.globalPrivacyControl) { Text("Send Global Privacy Control"); Text("Tells sites you don't consent to your data being sold or shared.").font(.caption) }
            }
            Section("Safety") {
                Toggle(isOn: $s.fraudWarnings) { Text("Warn about fraudulent websites"); Text("Off by default: it checks hashed parts of URLs with Apple's Safe Browsing service.").font(.caption) }
            }
        }
        .formStyle(.grouped)
    }
}

private struct SitesSettings: View {
    @ObservedObject private var s = AppSettings.shared
    @State private var confirmClear = false
    var body: some View {
        Form {
            Section {
                if s.rememberedSites.isEmpty {
                    Text("None. Every site is forgotten when you quit.").foregroundStyle(.secondary)
                }
                ForEach(s.rememberedSites.keys.sorted(), id: \.self) { site in
                    HStack {
                        Text(site)
                        Spacer()
                        Button("Forget") { ContainerManager.shared.forget(site) }.buttonStyle(.link)
                    }
                }
            } header: { Text("Stay signed in") } footer: {
                Text("Turn this on for a site from the shield menu in the address bar.").font(.caption)
            }
            Section("Protections turned off") {
                if s.shieldsOff.isEmpty { Text("None").foregroundStyle(.secondary) }
                ForEach(s.shieldsOff.sorted(), id: \.self) { site in
                    HStack {
                        Text(site)
                        Spacer()
                        Button("Turn back on") { s.shieldsOff.remove(site); ContainerManager.shared.existing(for: site)?.apply() }.buttonStyle(.link)
                    }
                }
            }
            Section {
                Button("Forget all browsing data now…", role: .destructive) { confirmClear = true }
                Button("Clear history") { HistoryStore.shared.clearAll() }
                Button("Reset privacy statistics") { Stats.shared.reset() }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Forget all browsing data?", isPresented: $confirmClear) {
            Button("Forget Everything", role: .destructive) {
                ContainerManager.shared.forgetAllUnremembered()
                for site in s.rememberedSites.keys { ContainerManager.shared.forget(site) }
                HistoryStore.shared.clearAll()
                DoHResolver.shared.clearCache()
            }
        } message: { Text("Signs you out of every site, including ones set to stay signed in, and clears history. Open pages keep working until they reload.") }
    }
}

private struct AboutSettings: View {
    var body: some View {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–"
        let rules = ContentRules.shared.ruleCounts.values.reduce(0, +)
        VStack(spacing: 14) {
            Image(systemName: "shield.lefthalf.filled").font(.system(size: 46, weight: .semibold)).foregroundStyle(Color.umbra)
            Text("Umbra \(version)").font(.title2.weight(.semibold))
            Text("A private, open-source browser for the Mac, built on Apple's WebKit.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow { Text("Domain block rules").foregroundStyle(.secondary); Text(Blocker.shared.ruleCount.formatted()) }
                GridRow { Text("Content rules").foregroundStyle(.secondary); Text(rules.formatted()) }
                GridRow { Text("Telemetry").foregroundStyle(.secondary); Text("None. Umbra never phones home.") }
                GridRow { Text("Filter lists").foregroundStyle(.secondary); Text("EasyList, EasyPrivacy (GPL-3.0 / CC BY-SA)") }
                GridRow { Text("Site boundaries").foregroundStyle(.secondary); Text("Public Suffix List (MPL-2.0)") }
            }
            .font(.system(size: 12))
            .padding(.top, 6)
            Spacer()
        }
        .padding(30)
    }
}
