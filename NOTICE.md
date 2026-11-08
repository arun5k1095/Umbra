# Third-party notices

Umbra's own code is MIT licensed (see `LICENSE`). It ships these data files:

## EasyList and EasyPrivacy

`Resources/lists/` is generated from **EasyList** and **EasyPrivacy**
(https://easylist.to), © The EasyList authors, dual licensed under the
**GNU General Public License v3.0 or later** and **Creative Commons
Attribution-ShareAlike 3.0 or later** (https://easylist.to/pages/licence.html).
Umbra redistributes the converted lists under CC BY-SA 3.0: they were converted
to WebKit content-blocking rules and a domain list by `tools/build_filters.py`
(rules WebKit can't express were dropped; see `Resources/lists/filters-stats.json`).

## Public Suffix List

`Resources/public_suffix_list.dat` is the **Public Suffix List**
(https://publicsuffix.org), licensed under the **Mozilla Public License 2.0**
(https://mozilla.org/MPL/2.0/). It is redistributed unmodified.

## Tor

Tor windows use the **Tor** program from the Tor Project's *Tor Expert Bundle*
(https://www.torproject.org), bundled unmodified in `Umbra.app/Contents/Helpers/` (re-signed
ad-hoc so macOS will run it) and run as a separate process. Tor is distributed under the
**3-clause BSD license**; this build reports that it is covered by the **GNU General Public
License v3** because it includes GPL-licensed components. Source code:
https://gitlab.torproject.org/tpo/core/tor. It links **libevent** (3-clause BSD) and includes
**OpenSSL** (Apache 2.0) and **zlib**. The full license texts are in
`Umbra.app/Contents/Resources/Licenses/`. Umbra is not affiliated with or endorsed by the Tor
Project. `scripts/fetch-tor.sh` shows exactly which bundle is used and how it is verified.

## WebKit

Umbra renders pages with Apple's system WebKit framework, which is part of macOS
and is not redistributed.
