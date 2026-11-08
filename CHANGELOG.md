# Changelog

## 0.2.0 — Tor windows

- **Tor windows** (File → New Tor Window, ⇧⌘N): every site goes through the Tor network, so
  sites see a Tor exit address and your network operator sees only that you use Tor
- Bundles the official Tor 0.4.9.15 (Tor Expert Bundle 16.0), verified by pinned SHA-256 and
  the Tor Browser Developers' GPG signature; started on demand and stopped when Umbra quits
- A separate Tor circuit per site (SOCKS isolation), separate memory-only containers from
  normal windows, no history, trackers still blocked and counted before anything reaches Tor
- `.onion` sites open in Tor windows; normal windows explain and offer to open them in one
- New Tor Identity (⇧⌘U): new circuits and empty containers for every Tor tab
- Tor status badge and panel, Tor-tinted window frame, Tor-specific error messages
- Pages stopped by WebKit's content rules now show "Umbra blocked this page"
- Self-test: 12 new Tor checks against the live Tor network (`UMBRA_SELFTEST_SUITE=tor` runs
  only those)

## 0.1.0 — first preview

- Native macOS browser on WebKit with a SwiftUI interface: tabs (drag to reorder), address
  bar with local-only suggestions, find on page, zoom, downloads, bookmarks, keyboard shortcuts
- One isolated container per site (separate WebKit data store and proxy), forgotten on quit,
  with optional "Stay signed in" per site
- Tracker and ad blocking from EasyPrivacy and EasyList: domain rules enforced and counted by a
  per-site local proxy, path rules and ad-space hiding by WebKit content rules
- Encrypted DNS (DoH) with automatic choice of the fastest of Quad9, Cloudflare and Mullvad
- HTTPS-only with a clear warning, tracking-link cleaning, Global Privacy Control, WebRTC
  blocking, canvas and audio fingerprint noise, Safari-matching user agent
- Privacy panel per page, privacy stats on the new-tab page, zero telemetry
- Built-in end-to-end self-test (`UMBRA_SELFTEST`)
