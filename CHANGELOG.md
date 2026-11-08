# Changelog

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
