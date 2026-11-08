// Compiles WebKit content-rule JSON with the real WebKit engine. WebKit rejects a whole
// list if any single rule is invalid, so on failure this bisects to find and drop the
// bad rules, then writes the cleaned list back.
//
// Usage: swift tools/validate_rules.swift rules-a.json [rules-b.json …]
import Foundation
import WebKit

let store = WKContentRuleListStore(url: FileManager.default.temporaryDirectory
    .appendingPathComponent("umbra-rule-validate-\(getpid())", isDirectory: true))!

func compile(_ rules: [Any], id: String) -> (ok: Bool, error: String) {
    let data = try! JSONSerialization.data(withJSONObject: rules)
    var done = false, ok = false, msg = ""
    store.compileContentRuleList(forIdentifier: id, encodedContentRuleList: String(decoding: data, as: UTF8.self)) { list, err in
        ok = list != nil
        msg = err.map { "\($0)" } ?? ""
        done = true
    }
    while !done { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    store.removeContentRuleList(forIdentifier: id) { _ in }
    return (ok, msg)
}

/// Returns the subset of rules that compile, dropping bad ones by bisection.
func clean(_ rules: [Any], depth: Int = 0, dropped: inout [Any]) -> [Any] {
    if rules.isEmpty { return [] }
    if compile(rules, id: "probe").ok { return rules }
    if rules.count == 1 { dropped.append(rules[0]); return [] }
    let mid = rules.count / 2
    return clean(Array(rules[..<mid]), depth: depth + 1, dropped: &dropped)
         + clean(Array(rules[mid...]), depth: depth + 1, dropped: &dropped)
}

var allOK = true
for path in CommandLine.arguments.dropFirst() {
    let url = URL(fileURLWithPath: path)
    let rules = try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [Any]
    let t0 = Date()
    let first = compile(rules, id: "full")
    let secs = Date().timeIntervalSince(t0)
    if first.ok {
        print(String(format: "✓ %@: %d rules compile (%.2f s)", url.lastPathComponent, rules.count, secs))
        continue
    }
    print("✗ \(url.lastPathComponent) failed (\(first.error)); finding bad rules…")
    var dropped: [Any] = []
    let good = clean(rules, dropped: &dropped)
    for d in dropped.prefix(10) {
        let s = String(decoding: try! JSONSerialization.data(withJSONObject: d), as: UTF8.self)
        print("  dropped: \(s.prefix(200))")
    }
    let out = try! JSONSerialization.data(withJSONObject: good)
    try! out.write(to: url)
    let recheck = compile(good, id: "full")
    print("  kept \(good.count), dropped \(dropped.count); recompile \(recheck.ok ? "OK" : "FAILED")")
    allOK = allOK && recheck.ok
}
exit(allOK ? 0 : 1)
