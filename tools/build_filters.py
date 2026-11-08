#!/usr/bin/env python3
"""Converts EasyList / EasyPrivacy (Adblock Plus syntax) into Umbra's two blocking layers.

Usage: tools/build_filters.py <easylist.txt> <easyprivacy.txt> <out_dir>

Outputs
  host-rules.txt        whole-domain rules, enforced (and counted) by Umbra's local proxy
                        format:  kind|domain|flags|domains
                          kind     A = ad, T = tracker, @ = exception, S = site allowlist
                          flags    3p = third-party only, 1p = first-party only
                          domains  a.com,~b.com  (only on these sites / not on these)
  rules-ads.json        WebKit content rules (path patterns) from EasyList
  rules-privacy.json    WebKit content rules (path patterns) from EasyPrivacy
  rules-cosmetic.json   WebKit css-display-none rules (hides empty ad slots)
  filters-stats.json    counts of what was converted and skipped

WebKit's url-filter is a restricted regex (no alternation), so some rules can't be
expressed and are skipped; every skip is counted in filters-stats.json.
"""
import json, os, re, sys
from collections import Counter, defaultdict

TYPE_MAP = {
    "script": "script", "image": "image", "stylesheet": "style-sheet", "css": "style-sheet",
    "font": "font", "media": "media", "xmlhttprequest": "raw", "xhr": "raw", "websocket": "websocket",
    "ping": "ping", "other": "other", "popup": "popup", "document": "document", "doc": "document",
    "subdocument": "document", "frame": "document", "object": "other",
}
PROXY_SAFE_TYPES = {"script", "raw", "image", "ping", "websocket", "other", "media", "font", "style-sheet"}
ALL_TYPES = ["document", "image", "style-sheet", "script", "font", "raw", "svg-document", "media", "popup", "ping", "websocket", "other"]
# Options we can't honour; rules using them are skipped rather than applied wrongly.
UNSUPPORTED = {"csp", "redirect", "redirect-rule", "rewrite", "removeparam", "replace", "header", "method",
               "generichide", "elemhide", "ghide", "ehide", "specifichide", "shide", "genericblock",
               "permissions", "to", "denyallow", "badfilter", "empty", "mp4", "inline-script", "inline-font",
               "cname", "webrtc", "urltransform", "jsonprune", "hls", "stealth", "content", "extension", "network"}
IGNORED = {"important", "all", "strict1p", "strict3p"}
PROCEDURAL = (":-abp-", ":contains(", ":has-text(", ":xpath(", ":matches-css", ":upward(", ":remove(",
              ":style(", ":watch-attr", ":min-text-length", ":matches-path", ":matches-attr", ":others(",
              "+js(", ":matches-media", ":remove-attr", ":remove-class")
DOMAIN_RE = re.compile(r"^[a-z0-9][a-z0-9.\-_]*[a-z0-9]$")
HOST_ONLY_RE = re.compile(r"^\|\|([a-z0-9][a-z0-9.\-_]*[a-z0-9])\^\|?$")

stats = Counter()


def esc(s):
    return re.sub(r"([.?+()\[\]{}\\])", r"\\\1", s)


def to_url_filter(pat):
    """ABP pattern → WebKit url-filter regex, or None if it can't be expressed."""
    if not pat or pat in ("*", "|", "||"):
        return ".*"
    if not pat.isascii():
        return None
    start = ""
    if pat.startswith("||"):
        start, pat = "^[^:]+://+([^:/]+\\.)?", pat[2:]
    elif pat.startswith("|"):
        start, pat = "^", pat[1:]
    end = ""
    if pat.endswith("|"):
        end, pat = "$", pat[:-1]
    if "|" in pat:
        return None  # alternation isn't supported by WebKit
    pat = pat.strip("*") if not start and not end else pat
    out = []
    for ch in pat:
        if ch == "*":
            out.append(".*")
        elif ch == "^":
            out.append("[^a-zA-Z0-9_.%-]")
        else:
            out.append(esc(ch))
    body = "".join(out)
    if not start and not end and not body:
        return ".*"
    return start + body + end


def parse_domains(value):
    inc, exc = [], []
    for d in value.split("|"):
        d = d.strip().lower()
        if not d:
            continue
        neg = d.startswith("~")
        d = d.lstrip("~")
        if d.endswith(".*") or "*" in d or not d.isascii() or not DOMAIN_RE.match(d):
            return None  # entity wildcards etc. are not supported
        (exc if neg else inc).append(d)
    return inc, exc


def parse_options(opt_str):
    """Returns dict or None if the rule must be skipped."""
    o = {"types": set(), "not_types": set(), "party": None, "inc": [], "exc": [], "case": False}
    if not opt_str:
        return o
    for raw in opt_str.split(","):
        raw = raw.strip()
        if not raw:
            continue
        neg = raw.startswith("~")
        name, _, val = raw.lstrip("~").partition("=")
        name = name.lower()
        if name in ("third-party", "3p"):
            o["party"] = "1p" if neg else "3p"
        elif name in ("first-party", "1p"):
            o["party"] = "3p" if neg else "1p"
        elif name == "domain":
            d = parse_domains(val)
            if d is None:
                return None
            o["inc"], o["exc"] = d
        elif name == "match-case":
            o["case"] = True
        elif name in TYPE_MAP:
            (o["not_types"] if neg else o["types"]).add(TYPE_MAP[name])
        elif name in IGNORED:
            pass
        else:
            if name not in UNSUPPORTED:
                stats["unknown-option:" + name] += 1
            return None
    return o


def wk_rule(url_filter, o, action):
    trig = {"url-filter": url_filter}
    if o["case"]:
        trig["url-filter-is-case-sensitive"] = True
    types = o["types"] or (set(ALL_TYPES) - o["not_types"] if o["not_types"] else set())
    if types:
        trig["resource-type"] = sorted(types)
    if o["party"] == "3p":
        trig["load-type"] = ["third-party"]
    elif o["party"] == "1p":
        trig["load-type"] = ["first-party"]
    if o["inc"]:
        trig["if-domain"] = ["*" + d for d in o["inc"]]
    elif o["exc"]:
        trig["unless-domain"] = ["*" + d for d in o["exc"]]
    return {"trigger": trig, "action": {"type": action}}


def convert(path, kind, host_rules, wk_block, wk_allow, cosmetic):
    for line in open(path, encoding="utf-8", errors="replace"):
        l = line.strip()
        if not l or l.startswith("!") or l.startswith("["):
            continue
        # ---- cosmetic ----
        if any(m in l for m in ("#@#", "#?#", "#$#", "#%#", "#+js", "#@$#", "#@?#")):
            stats["skip:cosmetic-advanced"] += 1
            continue
        if "##" in l:
            doms, sel = l.split("##", 1)
            if not sel or any(p in sel for p in PROCEDURAL) or not sel.isascii():
                stats["skip:cosmetic-procedural"] += 1
                continue
            d = parse_domains(doms.replace(",", "|")) if doms else ([], [])
            if d is None:
                stats["skip:cosmetic-domain"] += 1
                continue
            cosmetic[(tuple(sorted(d[0])), tuple(sorted(d[1])))].append(sel)
            stats["cosmetic"] += 1
            continue
        # ---- network ----
        exception = l.startswith("@@")
        r = l[2:] if exception else l
        if re.match(r"^/.*/(\$.*)?$", r):
            stats["skip:regex"] += 1
            continue
        pat, _, opt = r.partition("$")
        o = parse_options(opt)
        if o is None:
            stats["skip:option"] += 1
            continue
        m = HOST_ONLY_RE.match(pat.lower())
        doc_exception = exception and "document" in o["types"] and m
        if doc_exception and not o["inc"]:
            host_rules.append(f"S|{m.group(1)}||")       # whole site allowlisted
            wk_allow.append({"trigger": {"url-filter": ".*", "if-domain": ["*" + m.group(1)]},
                             "action": {"type": "ignore-previous-rules"}})
            stats["site-allowlist"] += 1
            continue
        if m and not o["types"] and not o["not_types"] and not o["case"]:
            doms = ",".join(o["inc"] + ["~" + x for x in o["exc"]])
            host_rules.append(f"{'@' if exception else kind}|{m.group(1)}|{o['party'] or ''}|{doms}")
            stats["host-exception" if exception else "host"] += 1
            continue
        # Tracker domains whose rule is limited to sub-resource types (e.g. Google Analytics:
        # $script,xmlhttprequest) are also enforced, and counted, at the proxy. Anything the
        # domain serves is tracking. Navigation/popup types stay WebKit-only.
        if (m and kind == "T" and not exception and not o["case"] and o["types"]
                and o["types"] <= PROXY_SAFE_TYPES and not o["not_types"]):
            doms = ",".join(o["inc"] + ["~" + x for x in o["exc"]])
            host_rules.append(f"T|{m.group(1)}|{o['party'] or ''}|{doms}")
            stats["host-promoted"] += 1
        uf = to_url_filter(pat)
        if uf is None:
            stats["skip:pattern"] += 1
            continue
        if uf == ".*" and not (o["types"] or o["inc"] or o["exc"] or o["party"]):
            stats["skip:too-broad"] += 1
            continue
        (wk_allow if exception else wk_block).append(wk_rule(uf, o, "ignore-previous-rules" if exception else "block"))
        stats["wk-exception" if exception else "wk-block"] += 1


def cosmetic_rules(groups, chunk=250):
    rules = []
    for (inc, exc), sels in sorted(groups.items()):
        sels = sorted(set(sels))
        for i in range(0, len(sels), chunk):
            trig = {"url-filter": ".*"}
            if inc:
                trig["if-domain"] = ["*" + d for d in inc]
            elif exc:
                trig["unless-domain"] = ["*" + d for d in exc]
            rules.append({"trigger": trig, "action": {"type": "css-display-none", "selector": ", ".join(sels[i:i + chunk])}})
    return rules


def main():
    easylist, easyprivacy, out = sys.argv[1:4]
    os.makedirs(out, exist_ok=True)
    host = []
    ads_b, ads_a, priv_b, priv_a = [], [], [], []
    cos = defaultdict(list)
    convert(easylist, "A", host, ads_b, ads_a, cos)
    convert(easyprivacy, "T", host, priv_b, priv_a, defaultdict(list))  # EasyPrivacy has ~no cosmetics
    # Exceptions go last so "ignore-previous-rules" can override the blocks before them.
    json.dump(ads_b + ads_a, open(f"{out}/rules-ads.json", "w"), separators=(",", ":"))
    json.dump(priv_b + priv_a, open(f"{out}/rules-privacy.json", "w"), separators=(",", ":"))
    cr = cosmetic_rules(cos)
    json.dump(cr, open(f"{out}/rules-cosmetic.json", "w"), separators=(",", ":"))
    host = sorted(set(host))
    with open(f"{out}/host-rules.txt", "w") as f:
        f.write("# Generated from EasyList + EasyPrivacy (GPL-3.0+ / CC BY-SA 3.0+). See NOTICE.md\n")
        f.write("\n".join(host) + "\n")
    stats["out:rules-ads"] = len(ads_b) + len(ads_a)
    stats["out:rules-privacy"] = len(priv_b) + len(priv_a)
    stats["out:rules-cosmetic"] = len(cr)
    stats["out:host-rules"] = len(host)
    json.dump(dict(sorted(stats.items())), open(f"{out}/filters-stats.json", "w"), indent=1)
    for k, v in sorted(stats.items()):
        if not k.startswith("unknown-option"):
            print(f"{k:28} {v}")
    unk = {k: v for k, v in stats.items() if k.startswith("unknown-option")}
    if unk:
        print("unknown options:", unk)


if __name__ == "__main__":
    main()
