import Foundation
import WebKit

/// Builds the script injected at document start into every frame. It runs in the page's
/// world (so it can adjust the APIs page scripts see), before any page script.
enum Shields {
    @MainActor
    static func script(seed: UInt32, site: String, shieldsOn: Bool) -> WKUserScript? {
        let s = AppSettings.shared
        let fp = shieldsOn && s.fingerprintProtection
        let webrtc = shieldsOn && s.blockWebRTC
        let gpc = s.globalPrivacyControl
        guard fp || webrtc || gpc else { return nil }
        let source = template
            .replacingOccurrences(of: "__SEED__", with: String(seed))
            .replacingOccurrences(of: "__FP__", with: fp ? "true" : "false")
            .replacingOccurrences(of: "__WEBRTC__", with: webrtc ? "true" : "false")
            .replacingOccurrences(of: "__GPC__", with: gpc ? "true" : "false")
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
    }

    private static let template = #"""
    (() => {
      const SEED = __SEED__ >>> 0, FP = __FP__, WEBRTC = __WEBRTC__, GPC = __GPC__;
      const natives = new WeakMap();
      const nativeToString = Function.prototype.toString;
      // Overridden functions still report "[native code]", so the shield isn't itself a fingerprint.
      const toStr = function toString() { return natives.has(this) ? natives.get(this) : nativeToString.call(this); };
      natives.set(toStr, nativeToString.call(nativeToString));
      try { Function.prototype.toString = toStr; } catch (e) {}
      const wrap = (proto, name, make) => {
        const orig = proto && proto[name];
        if (typeof orig !== 'function') return;
        const fn = make(orig);
        natives.set(fn, nativeToString.call(orig));
        try { Object.defineProperty(proto, name, { value: fn, writable: true, configurable: true }); } catch (e) {}
      };
      const getter = (proto, name, value) => {
        try {
          const g = function () { return value; };
          natives.set(g, 'function get ' + name + '() {\n    [native code]\n}');
          Object.defineProperty(proto, name, { get: g, configurable: true, enumerable: true });
        } catch (e) {}
      };

      if (GPC) getter(Navigator.prototype, 'globalPrivacyControl', true);

      if (WEBRTC) {
        // WebRTC can reveal your real IP address even through a proxy.
        for (const k of ['RTCPeerConnection', 'webkitRTCPeerConnection', 'RTCDataChannel', 'RTCIceCandidate',
                         'RTCSessionDescription', 'RTCRtpSender', 'RTCRtpReceiver', 'RTCRtpTransceiver']) {
          try { delete window[k]; } catch (e) {}
          try { Object.defineProperty(window, k, { value: undefined, configurable: true }); } catch (e) {}
        }
      }

      if (FP) {
        // Deterministic per site and session: the same drawing gives the same (slightly
        // altered) result, so pages work, but it differs from your real device's output.
        const prng = (s) => () => { s |= 0; s = s + 0x6D2B79F5 | 0; let t = Math.imul(s ^ s >>> 15, 1 | s);
          t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t; return ((t ^ t >>> 14) >>> 0) / 4294967296; };
        const noisePixels = (d) => { const r = prng(SEED); for (let i = 0; i < d.length; i += 4 * 61) { d[i + Math.floor(r() * 3)] ^= 1; } };
        const C2D = window.CanvasRenderingContext2D && CanvasRenderingContext2D.prototype;
        const origGetImageData = C2D && C2D.getImageData;
        wrap(C2D, 'getImageData', (orig) => function (...a) { const img = orig.apply(this, a); noisePixels(img.data); return img; });
        const noisyCopy = (c) => {
          if (!c.width || !c.height || c.width * c.height > 4e6 || !origGetImageData) return c;
          try {
            const t = document.createElement('canvas'); t.width = c.width; t.height = c.height;
            const x = t.getContext('2d'); x.drawImage(c, 0, 0);
            const img = origGetImageData.call(x, 0, 0, t.width, t.height); noisePixels(img.data); x.putImageData(img, 0, 0);
            return t;
          } catch (e) { return c; }
        };
        const HC = window.HTMLCanvasElement && HTMLCanvasElement.prototype;
        wrap(HC, 'toDataURL', (orig) => function (...a) { return orig.apply(noisyCopy(this), a); });
        wrap(HC, 'toBlob', (orig) => function (...a) { return orig.apply(noisyCopy(this), a); });

        const touched = new WeakSet();
        wrap(window.AudioBuffer && AudioBuffer.prototype, 'getChannelData', (orig) => function (...a) {
          const d = orig.apply(this, a);
          if (!touched.has(d)) { touched.add(d); const r = prng(SEED ^ 0x5bd1e995); for (let i = 0; i < d.length; i += 97) d[i] += (r() - 0.5) * 2e-7; }
          return d;
        });
        wrap(window.AnalyserNode && AnalyserNode.prototype, 'getFloatFrequencyData', (orig) => function (arr) {
          orig.call(this, arr); const r = prng(SEED ^ 0x27d4eb2d); for (let i = 0; i < arr.length; i += 7) arr[i] += (r() - 0.5) * 1e-4;
        });
        // A common value instead of your exact core count.
        getter(Navigator.prototype, 'hardwareConcurrency', 8);
      }
    })();
    """#
}

/// Removes tracking parameters and unwraps redirect links before a page loads.
enum LinkCleaner {
    private static let exact: Set<String> = [
        "fbclid", "gclid", "gclsrc", "dclid", "gbraid", "wbraid", "msclkid", "mc_cid", "mc_eid", "igshid", "igsh",
        "yclid", "ymclid", "_hsenc", "_hsmi", "__hssc", "__hstc", "__hsfp", "hsctatracking", "mkt_tok", "oly_anon_id",
        "oly_enc_id", "vero_conv", "vero_id", "wickedid", "twclid", "ttclid", "li_fat_id", "_openstat", "srsltid",
        "epik", "s_kwcid", "ef_id", "_branch_match_id", "_kx", "irclickid", "rb_clickid", "cmpid", "ncid", "sr_share",
        "spm", "scm", "trk", "trkcampaign", "at_campaign", "at_medium", "at_custom1", "pk_campaign", "pk_kwd",
        "piwik_campaign", "matomo_campaign", "mtm_campaign", "mtm_source", "mtm_medium", "_ga", "_gl", "itm_source",
        "itm_medium", "itm_campaign", "guccounter", "guce_referrer", "guce_referrer_sig",
    ]
    private static let prefixes = ["utm_", "pk_", "mtm_", "hmb_", "_hs", "ga_"]
    /// Parameters that only track on specific sites.
    private static let scoped: [String: Set<String>] = [
        "youtube.com": ["si", "feature", "pp"], "youtu.be": ["si", "feature"], "spotify.com": ["si"],
        "twitter.com": ["s", "t", "ref_src", "ref_url"], "x.com": ["s", "t", "ref_src", "ref_url"],
        "instagram.com": ["igsh", "img_index"], "amazon.com": ["ref", "ref_", "pd_rd_r", "pd_rd_w", "pd_rd_wg", "pf_rd_r", "pf_rd_p", "psc", "content-id"],
        "reddit.com": ["share_id", "rdt"], "linkedin.com": ["trackingid", "lipi", "trk"], "tiktok.com": ["_r", "_t", "is_from_webapp", "sender_device"],
        "facebook.com": ["mibextid", "rdid", "share_url"], "bing.com": ["form", "cvid", "qs", "sp", "sk", "sc", "pq"],
    ]
    /// Redirect wrappers: host → query parameter holding the real destination.
    private static let redirects: [String: [String]] = [
        "www.google.com/url": ["q", "url"], "google.com/url": ["q", "url"], "l.facebook.com/l.php": ["u"],
        "lm.facebook.com/l.php": ["u"], "l.instagram.com/": ["u"], "www.youtube.com/redirect": ["q"],
        "www.linkedin.com/redir/redirect": ["url"], "steamcommunity.com/linkfilter/": ["url", "u"],
        "duckduckgo.com/l/": ["uddg"], "out.reddit.com/": ["url"], "slack-redir.net/link": ["url"],
        "www.bing.com/ck/a": ["u"], "away.vk.com/away.php": ["to"],
    ]

    /// Returns a cleaned URL, or nil if nothing changed.
    static func clean(_ url: URL) -> URL? {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false), let host = c.host?.lowercased() else { return nil }
        let hostPath = host + (c.path.isEmpty ? "/" : c.path)
        for (prefix, params) in redirects where hostPath.hasPrefix(prefix) {
            if let target = c.queryItems?.first(where: { params.contains($0.name) })?.value,
               let t = URL(string: target), let scheme = t.scheme, scheme.hasPrefix("http") {
                return clean(t) ?? t
            }
        }
        guard let items = c.queryItems, !items.isEmpty else { return nil }
        let site = PublicSuffix.shared.site(forHost: host)
        let siteScoped = scoped[site] ?? []
        let kept = items.filter { item in
            let n = item.name.lowercased()
            return !(exact.contains(n) || prefixes.contains(where: { n.hasPrefix($0) }) || siteScoped.contains(n))
        }
        guard kept.count != items.count else { return nil }
        c.queryItems = kept.isEmpty ? nil : kept
        return c.url
    }
}

/// Turns what you type in the address bar into a URL or a search.
enum AddressInput {
    @MainActor
    static func resolve(_ raw: String) -> URL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let lower = text.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("about:") {
            if let u = URL(string: text) { return u }
        }
        if !text.contains(" "), looksLikeHost(text) {
            let hostPart = String(text.split(separator: "/").first ?? "")
            let host = String(hostPart.split(separator: ":").first ?? "")
            let scheme = PublicSuffix.isLocal(host) ? "http" : "https"
            if let u = URL(string: "\(scheme)://\(text)") { return u }
        }
        return AppSettings.shared.searchEngine.url(for: text)
    }

    private static func looksLikeHost(_ t: String) -> Bool {
        let hostPart = String(t.split(separator: "/").first ?? "")
        let host = String(hostPart.split(separator: ":").first ?? "").lowercased()
        if host == "localhost" || PublicSuffix.isIPv4(host) { return true }
        guard host.contains("."), !host.hasPrefix("."), !host.hasSuffix(".") else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        guard host.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        let tld = String(host.split(separator: ".").last ?? "")
        return tld.count >= 2 && tld.allSatisfy(\.isLetter)
    }
}
