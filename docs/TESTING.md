# Testing

## Automated end-to-end self-test

Umbra has a built-in test mode that drives the real browser against real websites, checks
each protection, compares speed with a plain WebKit view (no proxy, no rules, no scripts),
saves UI snapshots and quits:

```bash
./build.sh
open --env UMBRA_SELFTEST="$PWD/build/selftest" build/Umbra.app
# results: build/selftest/results.json and *.png
```

Keep the window visible while it runs: WebKit pauses pages in hidden windows (for example
when another app is full screen), which slows or skips the timing and benchmark steps. The
results record whether the window was visible.

| Check | How |
|---|---|
| Secure page loads | example.com: title, HTTPS, site container `example.com` |
| Tracking parameters stripped | `?utm_source=…&fbclid=…&gclid=…&keep=1` arrives as `?keep=1` |
| HTTPS upgrade | `http://example.org/` loads as `https://` |
| Container per site | example.org gets a new container: a different data store and proxy port |
| Back / Forward across sites | moves between the two containers' web views |
| Global Privacy Control | `navigator.globalPrivacyControl === true` |
| WebRTC blocked | `typeof RTCPeerConnection === "undefined"` |
| CPU count generalised | `navigator.hardwareConcurrency === 8` |
| Patches look native | `Function.prototype.toString(toDataURL)` contains `[native code]` |
| Canvas fingerprint | stable within a site, different across sites, different from a plain WebKit view |
| User agent | matches the installed Safari |
| Forget this site | a cookie set on the site is gone after "Forget this site" |
| Stay signed in | the site moves to a saved data store; ordinary sites stay memory-only |
| Blocking on a news site | theverge.com: trackers and ads refused and counted |
| Shield panel | opens and renders |
| Ad-block benchmark | adblock.turtlecute.org total score (needs a visible window) |
| Encrypted DNS | lookups went over DoH; resolver latencies recorded |
| Speed | 5 sites, each loaded twice per browser in alternating order, averaged |
| Error pages | an unreachable host shows Umbra's explanation page |

## Tools

```bash
python3 tools/build_filters.py easylist.txt easyprivacy.txt out/   # convert filter lists
swiftc -O tools/validate_rules.swift -o build/validate_rules       # compile-check rules with WebKit
build/validate_rules out/rules-*.json                              # drops any rule WebKit rejects
```

## Checking privacy yourself

- **Fingerprinting:** https://coveryourtracks.eff.org
- **DNS leaks:** https://www.dnsleaktest.com (extended test). Only your encrypted resolver should appear, not your ISP's.
- **WebRTC leaks:** https://browserleaks.com/webrtc. No local or public IP should be shown.
- **Ad blocking:** https://adblock.turtlecute.org
