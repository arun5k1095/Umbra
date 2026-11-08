import Foundation
import SwiftUI

enum SearchEngine: String, CaseIterable, Identifiable {
    case duckduckgo, startpage, brave, ecosia, google, bing
    var id: String { rawValue }
    var label: String {
        switch self {
        case .duckduckgo: return "DuckDuckGo"
        case .startpage: return "Startpage"
        case .brave: return "Brave Search"
        case .ecosia: return "Ecosia"
        case .google: return "Google"
        case .bing: return "Bing"
        }
    }
    var privacyNote: String {
        switch self {
        case .duckduckgo, .startpage, .brave: return "Doesn't profile you"
        case .ecosia: return "Plants trees; limited tracking"
        case .google, .bing: return "Builds an ad profile from your searches"
        }
    }
    func url(for query: String) -> URL? {
        var c: URLComponents
        switch self {
        case .duckduckgo: c = URLComponents(string: "https://duckduckgo.com/")!; c.queryItems = [.init(name: "q", value: query)]
        case .startpage: c = URLComponents(string: "https://www.startpage.com/do/search")!; c.queryItems = [.init(name: "q", value: query)]
        case .brave: c = URLComponents(string: "https://search.brave.com/search")!; c.queryItems = [.init(name: "q", value: query)]
        case .ecosia: c = URLComponents(string: "https://www.ecosia.org/search")!; c.queryItems = [.init(name: "q", value: query)]
        case .google: c = URLComponents(string: "https://www.google.com/search")!; c.queryItems = [.init(name: "q", value: query)]
        case .bing: c = URLComponents(string: "https://www.bing.com/search")!; c.queryItems = [.init(name: "q", value: query)]
        }
        return c.url
    }
}

/// User settings. Every privacy option defaults to the most private choice that still lets
/// ordinary sites work.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    @Published var searchEngine: SearchEngine { didSet { d.set(searchEngine.rawValue, forKey: "searchEngine") } }
    @Published var blockAds: Bool { didSet { save("blockAds", blockAds) } }
    @Published var blockTrackers: Bool { didSet { save("blockTrackers", blockTrackers) } }
    @Published var hideAdSpaces: Bool { didSet { save("hideAdSpaces", hideAdSpaces) } }
    @Published var dns: DNSProvider { didSet { d.set(dns.rawValue, forKey: "dns"); push(); DoHResolver.shared.clearCache() } }
    @Published var httpsOnly: Bool { didSet { save("httpsOnly", httpsOnly) } }
    @Published var cleanLinks: Bool { didSet { save("cleanLinks", cleanLinks) } }
    @Published var fingerprintProtection: Bool { didSet { save("fingerprintProtection", fingerprintProtection) } }
    @Published var blockWebRTC: Bool { didSet { save("blockWebRTC", blockWebRTC) } }
    @Published var globalPrivacyControl: Bool { didSet { save("globalPrivacyControl", globalPrivacyControl) } }
    @Published var javaScript: Bool { didSet { save("javaScript", javaScript) } }
    @Published var fraudWarnings: Bool { didSet { save("fraudWarnings", fraudWarnings) } }
    @Published var rememberHistory: Bool { didSet { save("rememberHistory", rememberHistory); if !rememberHistory { HistoryStore.shared.clearSaved() } } }
    @Published var showBookmarksOnNewTab: Bool { didSet { save("showBookmarksOnNewTab", showBookmarksOnNewTab) } }
    /// Sites whose cookies and logins survive quitting: site → data store UUID.
    @Published var rememberedSites: [String: String] { didSet { d.set(rememberedSites, forKey: "rememberedSites") } }
    /// Sites where the user turned protections off.
    @Published var shieldsOff: Set<String> { didSet { d.set(Array(shieldsOff), forKey: "shieldsOff"); push() } }

    private init() {
        d.register(defaults: [
            "blockAds": true, "blockTrackers": true, "hideAdSpaces": true, "httpsOnly": true, "cleanLinks": true,
            "fingerprintProtection": true, "blockWebRTC": true, "globalPrivacyControl": true, "javaScript": true,
            "fraudWarnings": false, "rememberHistory": false, "showBookmarksOnNewTab": true,
        ])
        searchEngine = SearchEngine(rawValue: d.string(forKey: "searchEngine") ?? "") ?? .duckduckgo
        blockAds = d.bool(forKey: "blockAds")
        blockTrackers = d.bool(forKey: "blockTrackers")
        hideAdSpaces = d.bool(forKey: "hideAdSpaces")
        dns = DNSProvider(rawValue: d.string(forKey: "dns") ?? "") ?? .automatic
        httpsOnly = d.bool(forKey: "httpsOnly")
        cleanLinks = d.bool(forKey: "cleanLinks")
        fingerprintProtection = d.bool(forKey: "fingerprintProtection")
        blockWebRTC = d.bool(forKey: "blockWebRTC")
        globalPrivacyControl = d.bool(forKey: "globalPrivacyControl")
        javaScript = d.bool(forKey: "javaScript")
        fraudWarnings = d.bool(forKey: "fraudWarnings")
        rememberHistory = d.bool(forKey: "rememberHistory")
        showBookmarksOnNewTab = d.bool(forKey: "showBookmarksOnNewTab")
        rememberedSites = d.dictionary(forKey: "rememberedSites") as? [String: String] ?? [:]
        shieldsOff = Set(d.stringArray(forKey: "shieldsOff") ?? [])
        push()
    }

    private func save(_ key: String, _ value: Bool) {
        d.set(value, forKey: key)
        push()
        ContainerManager.shared.refreshAll()
    }

    /// Publishes the switches the proxy reads off the main thread.
    func push() {
        LivePrivacy.shared.config = .init(blockAds: blockAds, blockTrackers: blockTrackers, dns: dns, shieldsOff: shieldsOff)
    }

    func shieldsOn(for site: String?) -> Bool { site.map { !shieldsOff.contains($0) } ?? true }
}
