# How Umbra works

Umbra is a native macOS browser built on Apple's WebKit (`WKWebView`), the same engine
as Safari. The whole browser, privacy engine included, is about 3,400 lines of Swift on top of it.

```
 ┌──────────────── Umbra.app ─────────────────────────────────────────────┐
 │  SwiftUI chrome: tabs · address bar · shield panel · settings          │
 │                                                                        │
 │  Tab ──► one WKWebView per site visited ──► that site's Container      │
 │                                                                        │
 │  Container (per site)                                                  │
 │   ├─ WKWebsiteDataStore   memory-only (or saved, if "Stay signed in")  │
 │   ├─ WKUserContentController                                           │
 │   │    ├─ content rules: EasyPrivacy · EasyList · ad-space hiding      │
 │   │    └─ shield script: GPC · WebRTC off · fingerprint noise          │
 │   └─ SOCKS5 proxy on 127.0.0.1:<port> ──┐                              │
 │                                         ▼                              │
 │        Blocker (93k tracker/ad domains, counted per page)              │
 │        DoH resolver (Cloudflare / Quad9 / Mullvad, fastest picked)     │
 │        relay ──────────────────────────────────────────► the internet  │
 └────────────────────────────────────────────────────────────────────────┘
```

## 1. One container per site

A *site* is a registrable domain (eTLD+1) computed with the Public Suffix List:
`maps.google.co.uk` → `google.co.uk`, `alice.github.io` → `alice.github.io`
(`Sources/Privacy/PublicSuffix.swift`).

Each site gets a `Container` (`Sources/Privacy/Containers.swift`):

- its own **`WKWebsiteDataStore`**: cookies, local storage, IndexedDB, cache, service
  workers. By default it is `nonPersistent()`, kept in memory and gone when Umbra quits.
  "Stay signed in" switches the site to `WKWebsiteDataStore(forIdentifier:)`, a saved
  store (macOS 14+).
- its own **local SOCKS5 proxy** (below).
- its own **WebKit configuration**: content rules and the shield script, built for that site,
  including "protections off" when you choose that.

When a page navigates to another site (a link, a redirect or typing in the address bar),
`Tab` cancels the navigation and re-opens it in a **new web view in the target site's
container** (`Sources/Browser/Tab.swift`). A tab keeps the last three sites' web views
alive, so Back and Forward across sites are instant; older ones reload on demand.
Cross-site **POST** submissions stay in the current container, so forms still work.
Script popups (`window.open`, for example sign-in windows) share the opener's container,
because WebKit requires it for the opener link. Ordinary `target=_blank` links open as
normal tabs in the right container, with no opener.

The result is the strongest form of cookie isolation: a tracker embedded on two sites sees
two strangers, because each site's requests come from a different cookie jar. WebKit's own
third-party cookie blocking and storage partitioning still apply on top.

## 2. The per-site proxy

`WKWebsiteDataStore.proxyConfigurations` (macOS 14+) routes all of a store's traffic
through a proxy. Umbra points each container's store at its own SOCKS5 listener on
`127.0.0.1`, set before any page uses the store (`Sources/Privacy/SocksProxy.swift`).

For every connection WebKit opens, the proxy receives the **hostname and port**, never the
content, because HTTPS stays encrypted end to end. It then:

1. asks the **Blocker** whether this host is a known ad or tracker *for this site*. Third-party
   rules only apply when the host's site differs from the container's site, and `$domain=`
   restrictions are honoured. If it is, the connection is refused and **counted** for the
   page's privacy report.
2. resolves the host with **encrypted DNS**.
3. connects and relays bytes in both directions (`NWConnection`, 256 KB reads, `TCP_NODELAY`).

Because the proxy knows which container (and so which site) each connection belongs to, it
can produce per-site, per-page reports. That's something WebKit's content blockers can't do:
WebKit has no public API that says what a content rule list blocked.

Trade-off: SOCKS carries TCP only, so pages use HTTP/1.1 and HTTP/2 but not HTTP/3 (QUIC).

## 3. Blocking in two layers

`tools/build_filters.py` converts EasyList and EasyPrivacy (Adblock Plus syntax) into:

| Layer | What | How many | Counted? |
|---|---|---|---|
| Proxy (`host-rules.txt`) | whole-domain rules, `\|\|tracker.com^` | ~93,600 | yes |
| WebKit content rules | path patterns, resource-type rules, exceptions | ~16,400 | no |
| WebKit cosmetic rules | hides empty ad slots (`css-display-none`) | ~23,800 selectors in 5,474 rules | no |

WebKit rejects an entire rule list if one rule is invalid, so `tools/validate_rules.swift`
compiles every list with the real WebKit engine and bisects out anything it rejects. Lists
compile once (under a second each) and WebKit caches them by identifier, so later launches
load them in milliseconds.

EasyPrivacy rules that restrict a whole tracker domain to sub-resource types (for example
`||google-analytics.com^$script,xmlhttprequest`) are *also* enforced by the proxy, so they're
counted. Rules about page navigations and pop-ups stay WebKit-only, so they can't break browsing.

## 4. Encrypted DNS

`Sources/Privacy/DoHResolver.swift` implements DNS over HTTPS (RFC 8484) with `URLSession`
(HTTP/2, one keep-alive connection):

- **Automatic** (the default) measures Quad9, Cloudflare and Mullvad at launch and whenever
  the network changes, and uses the fastest. On the development machine that was Cloudflare
  at 41 ms against about 190–210 ms for the others, a 5× difference per new hostname.
- Endpoints are IP-based (`9.9.9.9`, `1.1.1.1`), so no plain-DNS lookup is needed to bootstrap.
- A and AAAA are queried in parallel; **the connection starts as soon as the IPv4 answer
  arrives**, and IPv6 just extends the cache.
- Answers are cached by TTL (60 s to 1 h), concurrent lookups share one request, and the
  connection is kept warm every 25 s.
- If encrypted DNS fails, the lookup fails. It **never silently falls back** to plain DNS.

## 5. The shield script

`Sources/Privacy/Shields.swift` injects one script at document start, into every frame, in
the page's own JavaScript world, before any page script runs:

- **Global Privacy Control:** `navigator.globalPrivacyControl === true`.
- **WebRTC off:** `RTCPeerConnection` and related APIs are removed, so a page can't discover
  your real IP address with ICE candidates, a leak that would bypass the proxy.
- **Fingerprinting noise:** canvas reads (`getImageData`, `toDataURL`, `toBlob`) and audio reads
  (`getChannelData`, `getFloatFrequencyData`) get a tiny deterministic perturbation seeded **per
  site per session**. The same drawing reads back the same within a site, so pages work, but
  differently on every other site and from your real device. `hardwareConcurrency` reports 8.
- Patched functions still report `[native code]` from `Function.prototype.toString`, so the
  patching itself isn't an easy fingerprint.

The **user agent** is copied from the installed Safari (`Version/27.0.1 Safari/605.1.15` on the
development machine), so Umbra looks like the largest group of Mac users rather than a rare
browser.

## 6. Link cleaning and HTTPS-only

Before a page loads (`decidePolicyFor navigationAction`), Umbra:

- strips tracking parameters such as `utm_*`, `fbclid`, `gclid`, `msclkid`, `mc_eid`, `igshid` and
  Hubspot/Marketo/Matomo IDs, plus site-specific ones (YouTube `si`, Amazon `pd_rd_*` and others),
  and unwraps redirect links (Google `/url?q=`, `l.facebook.com`, YouTube `/redirect`,
  `out.reddit.com`, DuckDuckGo `/l/` and others).
- rewrites `http://` to `https://` (local hosts excepted). If the secure version fails, it shows a
  clear warning with "Continue Without HTTPS" instead of silently downgrading.

## 7. What Umbra itself sends

Nothing except what you ask for. There is no telemetry, no crash reporting, no update check and
no search suggestions (typing never leaves the Mac until you press Return). The only traffic
Umbra starts on its own is encrypted DNS (resolver timing at launch, plus a keep-alive), and
site icons, which go through the site's own container proxy with no cookies. Tor connects to
the Tor network only after you open a Tor window. Downloads are
tagged as coming from the web, so Gatekeeper checks them.

Data on disk: settings, bookmarks, aggregate daily counters (numbers only: never sites or
domains), the list of "stay signed in" sites with their WebKit data stores, and history only if
you turn on "Remember history".

## 8. Tor windows

File → New Tor Window (⇧⌘N) opens a window whose every site goes through the Tor network
(`Sources/Privacy/Tor.swift`).

- **The Tor program** is the official Tor Expert Bundle, fetched by `scripts/fetch-tor.sh`
  (pinned SHA-256, plus the Tor Browser Developers' GPG signature when gpg is installed) and
  bundled in `Contents/Helpers/`. Umbra starts it the first time a Tor window opens, with a
  SOCKS port on `127.0.0.1` chosen by Tor, and reads its progress from Tor's log. It stops
  when Umbra quits; if Umbra crashes, `__OwningControllerProcess` makes Tor exit too. Tor's
  data folder (`~/Library/Application Support/Umbra/Tor`) holds only Tor's relay directory
  cache and guard choice, which makes later starts take about 3 s instead of 15–40 s.
- **Chaining:** Tor windows have their own containers, and each container's proxy works as
  before (blocking and counting first). Then, instead of encrypted DNS and a direct
  connection, it opens a SOCKS5 connection to Tor and asks for the **hostname**, so the name
  is resolved at the Tor exit and no DNS lookup leaves the Mac. A request Tor fails right
  away is retried once on a fresh circuit.
- **A circuit per site:** the proxy authenticates to Tor with the site as the username and a
  per-session key as the password. Tor's `IsolateSOCKSAuth` puts different credentials on
  different circuits, so two sites see different exit addresses and can't link your visits.
  **New Identity** (⇧⌘U) changes the key and empties every Tor container.
- **Separation from normal windows:** a site in a Tor window gets a different container from
  the same site in a normal window, always memory-only (no "Stay signed in"). Tor windows
  keep no history, and links from other apps never open in a Tor window.
- **Onion services:** `.onion` addresses skip the HTTPS upgrade (onion connections are
  already end-to-end encrypted) and show as secure. In a normal window, Umbra never tries to
  look one up: it explains and offers to open the address in a Tor window.

What Tor windows **don't** do: they don't make Umbra look like Tor Browser. Tor Browser
makes every user look identical (window size, fonts, user agent). Umbra's fingerprint
defenses are weaker, so a determined site could still tell Umbra users apart. For
anonymity against strong adversaries, use Tor Browser.

## 9. Limitations

- **No HTTP/3** through the proxy (TCP only).
- **No extensions**, no password AutoFill (WKWebView doesn't offer them to third-party apps), no
  sync.
- The privacy report **counts proxy-level blocks only**. WebKit's content rules block more
  that can't be counted.
- **Fingerprinting defenses are partial.** They raise the bar against common scripts, but a
  determined fingerprinter can still use screen size, fonts and timing. For anonymity against
  strong adversaries, use Tor Browser.
- **IPv4 is preferred**; IPv6 is used when a host has no IPv4 address.
- **Tor windows** are slower than direct browsing (every connection crosses three relays),
  don't support bridges for networks that block Tor, and don't provide Tor Browser's
  uniform fingerprint.
