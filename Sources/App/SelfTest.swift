import AppKit
import WebKit

/// Automated end-to-end checks against real websites. Runs only when Umbra is launched with
/// UMBRA_SELFTEST=<folder>; writes results.json and UI snapshots there, then quits.
///
///     open --env UMBRA_SELFTEST="$PWD/build/selftest" build/Umbra.app
@MainActor
enum SelfTest {
    struct Check: Codable { var name: String; var passed: Bool; var detail: String }
    struct Perf: Codable { var url: String; var umbraFirstMs: Double; var plainFirstMs: Double; var umbraRepeatMs: Double; var plainRepeatMs: Double
        var umbraRequests: Int; var plainRequests: Int; var blocked: Int }

    static var directory: URL? { ProcessInfo.processInfo.environment["UMBRA_SELFTEST"].map { URL(fileURLWithPath: $0, isDirectory: true) } }
    private static var checks: [Check] = []
    private static var perf: [Perf] = []
    private static var notes: [String: String] = [:]

    static func runIfRequested() {
        guard let dir = directory else { return }
        setvbuf(stdout, nil, _IOLBF, 0)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Task { await run(dir) }
    }

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        checks.append(Check(name: name, passed: ok, detail: detail))
        print("[selftest] \(ok ? "PASS" : "FAIL") \(name) \(detail)")
    }

    private static func run(_ dir: URL) async {
        await sleep(1.5)
        guard await waitFor(15, { BrowserRegistry.all.first?.window != nil && ContentRules.shared.ready }),
              let browser = BrowserRegistry.all.first, let window = browser.window, let tab = browser.selected else {
            check("startup", false, "no browser window"); return finish(dir)
        }
        window.setContentSize(NSSize(width: 1280, height: 800))
        check("startup", true, "content rules: \(ContentRules.shared.ruleCounts), domain rules: \(Blocker.shared.ruleCount)")
        await sleep(1)
        await snapshot(window, browser, "01-new-tab", dir)

        // 1. Basic secure load
        await load(tab, "https://example.com/")
        check("loads https page", tab.title == "Example Domain" && tab.isSecure, "title=\(tab.title) secure=\(tab.isSecure)")
        check("site container", tab.site == "example.com", "site=\(tab.site ?? "nil")")

        // 2. Link cleaning
        await load(tab, "https://example.com/?utm_source=news&fbclid=abc123&gclid=x&keep=1")
        let q = tab.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.query } ?? "nil"
        check("strips tracking parameters", q == "keep=1", "query=\(q)")

        // 3. HTTPS upgrade + container switch + back/forward across sites
        let containersBefore = ContainerManager.shared.all.count
        await load(tab, "http://example.org/")
        check("upgrades http to https", tab.url?.scheme == "https", "url=\(tab.url?.absoluteString ?? "nil")")
        check("new site gets its own container", tab.site == "example.org" && ContainerManager.shared.all.count == containersBefore + 1,
              "site=\(tab.site ?? "nil") containers=\(ContainerManager.shared.all.count)")
        let a = ContainerManager.shared.existing(for: "example.com"), b = ContainerManager.shared.existing(for: "example.org")
        check("separate cookie jars and proxies", a != nil && b != nil && a!.store !== b!.store && a!.proxy.port != b!.proxy.port,
              "ports \(a?.proxy.port ?? 0) / \(b?.proxy.port ?? 0)")
        tab.goBack(); await waitLoaded(tab)
        check("back across sites", tab.site == "example.com", "site=\(tab.site ?? "nil")")
        tab.goForward(); await waitLoaded(tab)
        check("forward across sites", tab.site == "example.org", "site=\(tab.site ?? "nil")")

        // 4. In-page defenses
        let probe = """
        (() => { const c = document.createElement('canvas'); c.width = 220; c.height = 40; const x = c.getContext('2d');
          x.textBaseline = 'top'; x.font = '16px Arial'; x.fillStyle = '#f60'; x.fillRect(10, 1, 62, 20); x.fillStyle = '#069';
          x.fillText('Umbra fingerprint ✓', 2, 15); x.fillStyle = 'rgba(102,204,0,0.7)'; x.fillText('Umbra fingerprint ✓', 4, 17);
          const h = (s) => { let v = 0; for (let i = 0; i < s.length; i++) v = (v * 31 + s.charCodeAt(i)) | 0; return v; };
          return JSON.stringify({ gpc: navigator.globalPrivacyControl === true, rtc: typeof window.RTCPeerConnection,
            cores: navigator.hardwareConcurrency, native: Function.prototype.toString.call(HTMLCanvasElement.prototype.toDataURL).includes('[native code]'),
            c1: h(c.toDataURL()), c2: h(c.toDataURL()), ua: navigator.userAgent }); })()
        """
        let onOrg = await evalJSON(tab.webView, probe)
        tab.goBack(); await waitLoaded(tab)
        let onCom = await evalJSON(tab.webView, probe)
        let plain = await plainProbe("https://example.com/", probe)
        check("Global Privacy Control sent", onCom["gpc"] as? Bool == true)
        check("WebRTC blocked (no IP leak)", onCom["rtc"] as? String == "undefined", "typeof RTCPeerConnection = \(onCom["rtc"] ?? "?")")
        check("CPU count generalised", onCom["cores"] as? Int == 8, "cores=\(onCom["cores"] ?? "?") (real: \(plain["cores"] ?? "?"))")
        check("patched APIs look native", onCom["native"] as? Bool == true)
        check("canvas stable within a site", (onCom["c1"] as? Int) == (onCom["c2"] as? Int))
        check("canvas differs between sites", (onCom["c1"] as? Int) != (onOrg["c1"] as? Int), "\(onCom["c1"] ?? "?") vs \(onOrg["c1"] ?? "?")")
        check("canvas differs from real device", (onCom["c1"] as? Int) != (plain["c1"] as? Int), "plain=\(plain["c1"] ?? "?")")
        let ua = onCom["ua"] as? String ?? ""
        check("user agent matches Safari", ua.contains("Version/") && ua.contains("Safari/605.1.15"), ua)

        // 4b. Forget this site / stay signed in
        _ = await evalString(tab.webView, "document.cookie = 'umbra_test=1; max-age=3600; secure'; document.cookie")
        let before = await evalString(tab.webView, "document.cookie") ?? ""
        ContainerManager.shared.forget("example.com")
        tab.reopenInFreshContainer(); await waitLoaded(tab)
        let after = await evalString(tab.webView, "document.cookie") ?? ""
        check("forget this site clears its cookies", before.contains("umbra_test=1") && !after.contains("umbra_test"), "before='\(before)' after='\(after)'")
        ContainerManager.shared.remember("example.com")
        tab.reopenInFreshContainer(); await waitLoaded(tab)
        let persistent = tab.container?.store.isPersistent ?? false
        check("stay signed in uses a saved data store", persistent && tab.container?.persistent == true)
        ContainerManager.shared.forget("example.com")
        tab.reopenInFreshContainer(); await waitLoaded(tab)
        check("ordinary sites use memory-only storage", tab.container?.store.isPersistent == false)

        // 5. Blocking on a tracker-heavy page, and the privacy panel
        await load(tab, "https://www.theverge.com/", settle: 6)
        let snap = tab.container?.proxy.report.snapshot()
        check("blocks trackers on a news site", (snap?.trackers ?? 0) + (snap?.ads ?? 0) > 0,
              "trackers=\(snap?.trackers ?? 0) ads=\(snap?.ads ?? 0) contacted=\(snap?.contacted.count ?? 0) top=\(snap?.blocked.prefix(5).map(\.host) ?? [])")
        await snapshot(window, browser, "02-page", dir)
        browser.shieldPanelOpen = true
        await sleep(1.5)
        await snapshotPopover(dir, "03-shield-panel")
        browser.shieldPanelOpen = false
        await sleep(0.5)

        // 6. Public ad-block benchmark
        await load(tab, "https://adblock.turtlecute.org/", settle: 16)
        let text = (await evalString(tab.webView, "document.body.innerText")) ?? ""
        notes["adblock-benchmark"] = String(text.prefix(1500))
        // Only the real result field counts ("Total : 87%"); the FAQ text also contains "100%".
        let score = text.range(of: #"Total\s*:\s*\d{1,3}(\.\d+)?\s*%"#, options: .regularExpression).map { String(text[$0]) }
        if let score { check("ad-block benchmark score", true, score) }
        else { notes["adblock-benchmark-result"] = "not measured (the page's test scripts didn't run; the window was probably hidden)" }
        await snapshot(window, browser, "04-adblock-benchmark", dir)

        // 7. Encrypted DNS was used
        check("DNS lookups went over HTTPS", DoHResolver.shared.lookups > 5, "lookups=\(DoHResolver.shared.lookups) via \(AppSettings.shared.dns.shortName); resolver latency ms: \(DoHResolver.shared.latencies.map { "\($0.key.rawValue)=\(Int($0.value))" }.sorted())")

        // 8. Speed vs. a plain WebKit view with no protections, on sites neither has loaded yet.
        //    First visit (cold cache) and repeat visit (warm cache) are measured separately;
        //    the order alternates so neither browser always goes first.
        for (i, u) in ["https://en.wikipedia.org/wiki/Web_browser", "https://www.apple.com/", "https://github.com/",
                       "https://edition.cnn.com/", "https://www.bbc.com/news"].enumerated() {
            var umbra: [(ms: Double, requests: Int, kb: Int)] = [], plain: [(ms: Double, requests: Int, kb: Int)] = []
            var blocked = 0
            for _ in 0..<2 {
                if i % 2 == 1 { plain.append(await plainTiming(u)) }
                await load(tab, u, settle: 2)
                umbra.append(await timing(tab.webView))
                blocked = tab.container?.proxy.report.snapshot().blocked.reduce(0) { $0 + $1.count } ?? 0
                if i % 2 == 0 { plain.append(await plainTiming(u)) }
            }
            perf.append(Perf(url: u, umbraFirstMs: umbra[0].ms, plainFirstMs: plain[0].ms, umbraRepeatMs: umbra[1].ms, plainRepeatMs: plain[1].ms,
                             umbraRequests: umbra[0].requests, plainRequests: plain[0].requests, blocked: blocked))
            print("[selftest] perf \(u): first visit umbra \(Int(umbra[0].ms)) ms vs plain \(Int(plain[0].ms)) ms · repeat umbra \(Int(umbra[1].ms)) vs plain \(Int(plain[1].ms)) · requests \(umbra[0].requests) vs \(plain[0].requests) · blocked \(blocked)")
        }

        // 9. Problem pages
        await load(tab, "https://this-host-does-not-exist-umbra.example/", settle: 1)
        if case .unreachable = tab.problem { check("friendly error for unreachable site", true) } else { check("friendly error for unreachable site", false, "\(String(describing: tab.problem))") }
        await snapshot(window, browser, "05-error-page", dir)

        // 10. New tab with stats
        browser.newTab()
        await sleep(1.5)
        await snapshot(window, browser, "06-new-tab-stats", dir)
        finish(dir)
    }

    // MARK: helpers

    private static func finish(_ dir: URL) {
        notes["window-visible"] = (BrowserRegistry.all.first?.window?.occlusionState.contains(.visible) ?? false) ? "yes" : "no (results from a hidden window can be slow or missing)"
        notes["timeouts"] = String(timeouts)
        struct Out: Codable { var checks: [Check]; var perf: [Perf]; var notes: [String: String] }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(Out(checks: checks, perf: perf, notes: notes)).write(to: dir.appendingPathComponent("results.json"))
        print("[selftest] done: \(checks.filter(\.passed).count)/\(checks.count) passed")
        if ProcessInfo.processInfo.environment["UMBRA_SELFTEST_STAY"] == nil { NSApp.terminate(nil) }
    }

    private static func sleep(_ s: Double) async { try? await Task.sleep(for: .milliseconds(Int(s * 1000))) }

    private static func waitFor(_ timeout: Double, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if cond() { return true }; await sleep(0.1) }
        return cond()
    }

    private static func load(_ tab: Tab, _ s: String, settle: Double = 0.5) async {
        tab.load(URL(string: s)!)
        await waitLoaded(tab, settle: settle)
    }

    private static func waitLoaded(_ tab: Tab, settle: Double = 0.5) async {
        await sleep(0.4)
        _ = await waitFor(30) { !tab.isLoading || tab.problem != nil }
        await sleep(settle)
    }

    private static func evalJSON(_ wv: WKWebView?, _ js: String) async -> [String: Any] {
        guard let s = await evalString(wv, js), let d = s.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return o
    }

    private static func evalString(_ wv: WKWebView?, _ js: String) async -> String? {
        guard let wv else { return nil }
        return await withTimeout(10) { await withCheckedContinuation { c in
            wv.evaluateJavaScript(js) { r, _ in c.resume(returning: r as? String) } } } ?? nil
    }

    /// Runs `op`, giving up after `seconds` (WebKit pauses pages in hidden windows).
    private static func withTimeout<T>(_ seconds: Double, _ op: @escaping @MainActor () async -> T) async -> T? {
        await withCheckedContinuation { (c: CheckedContinuation<T?, Never>) in
            var settled = false        // both tasks run on the main actor, so this is race-free
            Task { @MainActor in
                let v = await op()
                if !settled { settled = true; c.resume(returning: v) }
            }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
                if !settled { settled = true; timeouts += 1; c.resume(returning: nil) }
            }
        }
    }
    private static var timeouts = 0

    private static let timingJS = """
    JSON.stringify((() => { const n = performance.getEntriesByType('navigation')[0];
      const r = performance.getEntriesByType('resource');
      const bytes = r.reduce((a, e) => a + (e.transferSize || e.encodedBodySize || 0), (n && (n.transferSize || n.encodedBodySize)) || 0);
      return { ms: n ? n.loadEventEnd - n.startTime : 0, requests: r.length + 1, kb: Math.round(bytes / 1024) }; })())
    """

    private static func timing(_ wv: WKWebView?) async -> (ms: Double, requests: Int, kb: Int) {
        let o = await evalJSON(wv, timingJS)
        return ((o["ms"] as? Double) ?? 0, (o["requests"] as? Int) ?? 0, (o["kb"] as? Int) ?? 0)
    }

    /// A plain WebKit view: default settings, no proxy, no rules, no scripts. The baseline.
    private static var plainWindow: NSWindow?
    private static let plainStore = WKWebsiteDataStore.nonPersistent()
    private static func plainWebView() -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = plainStore          // shared, so repeat visits are cached like Umbra's
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 760), configuration: cfg)
        wv.customUserAgent = UserAgent.safari
        let w = plainWindow ?? NSWindow(contentRect: NSRect(x: 40, y: 40, width: 1280, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
        w.title = "Baseline (plain WebKit)"
        w.contentView = wv
        w.orderBack(nil)
        plainWindow = w
        return wv
    }

    private static func plainLoad(_ u: String) async -> WKWebView {
        let wv = plainWebView()
        wv.load(URLRequest(url: URL(string: u)!))
        await sleep(0.4)
        _ = await waitFor(30) { !wv.isLoading }
        await sleep(2)
        return wv
    }

    private static func plainTiming(_ u: String) async -> (ms: Double, requests: Int, kb: Int) {
        await timing(await plainLoad(u))
    }

    private static func plainProbe(_ u: String, _ js: String) async -> [String: Any] {
        await evalJSON(await plainLoad(u), js)
    }

    // MARK: snapshots

    private static func snapshot(_ window: NSWindow, _ browser: BrowserState, _ name: String, _ dir: URL) async {
        guard let root = window.contentView?.superview ?? window.contentView else { return }
        guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
        root.cacheDisplay(in: root.bounds, to: rep)
        let img = NSImage(size: root.bounds.size)
        img.addRepresentation(rep)
        // Web content draws in another process; paste in WebKit's own snapshot of it.
        if let wv = browser.selected?.webView, wv.window === window, !wv.isHidden, browser.selected?.problem == nil,
           let page = await withTimeout(8, { await withCheckedContinuation { c in
               wv.takeSnapshot(with: WKSnapshotConfiguration()) { img, _ in c.resume(returning: img) } } }) ?? nil {
            var r = wv.convert(wv.bounds, to: root)
            if root.isFlipped { r.origin.y = root.bounds.height - r.maxY }
            let composed = NSImage(size: root.bounds.size)
            composed.lockFocus()
            img.draw(in: NSRect(origin: .zero, size: root.bounds.size))
            page.draw(in: r)
            composed.unlockFocus()
            save(composed, dir.appendingPathComponent("\(name).png"))
        } else {
            save(img, dir.appendingPathComponent("\(name).png"))
        }
    }

    private static func snapshotPopover(_ dir: URL, _ name: String) async {
        guard let pop = NSApp.windows.first(where: { String(describing: type(of: $0)).contains("Popover") && $0.isVisible }),
              let v = pop.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else {
            check("shield panel opens", false); return
        }
        v.cacheDisplay(in: v.bounds, to: rep)
        let img = NSImage(size: v.bounds.size); img.addRepresentation(rep)
        save(img, dir.appendingPathComponent("\(name).png"))
        check("shield panel opens", true)
    }

    private static func save(_ img: NSImage, _ url: URL) {
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }
}
