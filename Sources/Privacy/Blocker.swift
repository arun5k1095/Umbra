import Foundation

/// Whole-domain ad and tracker blocking, enforced inside Umbra's local proxy so every
/// block can be counted and shown. Rules come from Resources/lists/host-rules.txt
/// (generated from EasyList and EasyPrivacy by tools/build_filters.py).
final class Blocker: @unchecked Sendable {
    static let shared = Blocker()

    enum Category: String { case ad = "Ad", tracker = "Tracker" }
    enum Verdict { case allow, block(Category, rule: String) }

    private struct Rule {
        var category: Category
        var party: UInt8        // 0 any, 1 third-party only, 2 first-party only
        var onlyOn: [String]    // limit to these sites
        var notOn: [String]     // never on these sites
    }

    private var rules: [String: [Rule]] = [:]
    private var exceptions: [String: [Rule]] = [:]
    private var siteAllowlist = Set<String>()
    private(set) var ruleCount = 0

    private init() {
        guard let url = Bundle.main.url(forResource: "host-rules", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let f = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 4 else { continue }
            let domain = f[1]
            if f[0] == "S" { siteAllowlist.insert(domain); continue }
            var only: [String] = [], not: [String] = []
            for d in f[3].split(separator: ",") {
                if d.hasPrefix("~") { not.append(String(d.dropFirst())) } else { only.append(String(d)) }
            }
            let rule = Rule(category: f[0] == "A" ? .ad : .tracker,
                            party: f[2] == "3p" ? 1 : (f[2] == "1p" ? 2 : 0), onlyOn: only, notOn: not)
            if f[0] == "@" { exceptions[domain, default: []].append(rule) }
            else { rules[domain, default: []].append(rule); ruleCount += 1 }
        }
    }

    /// Should a connection to `host` be blocked on a page from `site`?
    func check(host rawHost: String, site: String, ads: Bool, trackers: Bool) -> Verdict {
        guard ads || trackers else { return .allow }
        let host = rawHost.lowercased()
        if PublicSuffix.isLocal(host) || siteAllowlist.contains(site) { return .allow }
        let hostSite = PublicSuffix.shared.site(forHost: host)
        let thirdParty = hostSite != site

        for candidate in Self.parents(of: host) {
            guard let list = rules[candidate] else { continue }
            // Visiting a listed domain directly (e.g. opening doubleclick.net) is allowed.
            if !thirdParty && candidate == site { continue }
            for r in list where applies(r, site: site, thirdParty: thirdParty) {
                if (r.category == .ad && !ads) || (r.category == .tracker && !trackers) { continue }
                if isExcepted(host, site: site, thirdParty: thirdParty) { return .allow }
                return .block(r.category, rule: candidate)
            }
        }
        return .allow
    }

    private func isExcepted(_ host: String, site: String, thirdParty: Bool) -> Bool {
        for candidate in Self.parents(of: host) {
            if let ex = exceptions[candidate], ex.contains(where: { applies($0, site: site, thirdParty: thirdParty) }) { return true }
        }
        return false
    }

    private func applies(_ r: Rule, site: String, thirdParty: Bool) -> Bool {
        if r.party == 1 && !thirdParty { return false }
        if r.party == 2 && thirdParty { return false }
        if !r.onlyOn.isEmpty && !r.onlyOn.contains(where: { Self.matches(site, $0) }) { return false }
        if r.notOn.contains(where: { Self.matches(site, $0) }) { return false }
        return true
    }

    private static func matches(_ site: String, _ domain: String) -> Bool {
        site == domain || site.hasSuffix("." + domain) || domain.hasSuffix("." + site)
    }

    /// a.b.example.com → [a.b.example.com, b.example.com, example.com, com]
    static func parents(of host: String) -> [String] {
        var out: [String] = [host]
        var idx = host.startIndex
        while let dot = host[idx...].firstIndex(of: ".") {
            idx = host.index(after: dot)
            out.append(String(host[idx...]))
        }
        return out
    }
}

/// Who runs well-known trackers, so the privacy report can say "Google" rather than a hostname.
enum TrackerOwners {
    private static let owners: [String: String] = [
        "google-analytics.com": "Google", "googletagmanager.com": "Google", "doubleclick.net": "Google",
        "googlesyndication.com": "Google", "googleadservices.com": "Google", "googletagservices.com": "Google",
        "google.com": "Google", "gstatic.com": "Google", "youtube.com": "Google", "app-measurement.com": "Google",
        "facebook.net": "Meta", "facebook.com": "Meta", "fbcdn.net": "Meta", "instagram.com": "Meta",
        "amazon-adsystem.com": "Amazon", "criteo.com": "Criteo", "criteo.net": "Criteo",
        "scorecardresearch.com": "Comscore", "quantserve.com": "Quantcast", "hotjar.com": "Hotjar",
        "segment.io": "Segment", "segment.com": "Segment", "mixpanel.com": "Mixpanel", "amplitude.com": "Amplitude",
        "newrelic.com": "New Relic", "nr-data.net": "New Relic", "taboola.com": "Taboola", "outbrain.com": "Outbrain",
        "adnxs.com": "Microsoft (Xandr)", "bing.com": "Microsoft", "clarity.ms": "Microsoft",
        "linkedin.com": "LinkedIn", "licdn.com": "LinkedIn", "twitter.com": "X", "x.com": "X", "ads-twitter.com": "X",
        "tiktok.com": "TikTok", "tiktokcdn.com": "TikTok", "snapchat.com": "Snap", "pinterest.com": "Pinterest",
        "yandex.ru": "Yandex", "yandex.net": "Yandex", "adsrvr.org": "The Trade Desk", "rubiconproject.com": "Magnite",
        "pubmatic.com": "PubMatic", "openx.net": "OpenX", "casalemedia.com": "Index Exchange", "moatads.com": "Oracle Moat",
        "chartbeat.com": "Chartbeat", "chartbeat.net": "Chartbeat", "optimizely.com": "Optimizely", "fullstory.com": "FullStory",
        "branch.io": "Branch", "adjust.com": "Adjust", "appsflyer.com": "AppsFlyer", "onetrust.com": "OneTrust",
        "cookielaw.org": "OneTrust", "sentry.io": "Sentry", "datadoghq.com": "Datadog", "braze.com": "Braze",
    ]

    static func owner(of host: String) -> String? {
        for p in Blocker.parents(of: host.lowercased()) { if let o = owners[p] { return o } }
        return nil
    }
}
