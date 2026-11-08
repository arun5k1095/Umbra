import Foundation

/// Works out a host's *site* (registrable domain, eTLD+1) using the Public Suffix List:
/// maps.google.co.uk → google.co.uk, alice.github.io → alice.github.io.
/// Umbra gives every site its own isolated storage and proxy, so this decides what
/// counts as "the same site". Thread-safe; used from proxy queues.
final class PublicSuffix: @unchecked Sendable {
    static let shared = PublicSuffix()

    private var rules = Set<String>()
    private var wildcards = Set<String>()      // "*.ck" stored as "ck"
    private var exceptions = Set<String>()     // "!www.ck" stored as "www.ck"
    private var cache: [String: String] = [:]
    private let lock = NSLock()

    private init() {
        guard let url = Bundle.main.url(forResource: "public_suffix_list", withExtension: "dat"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("//") { continue }
            let rule = String(line.split(separator: " ").first ?? "").lowercased()
            let ascii = Self.toASCII(rule)
            if ascii.hasPrefix("!") { exceptions.insert(String(ascii.dropFirst())) }
            else if ascii.hasPrefix("*.") { wildcards.insert(String(ascii.dropFirst(2))) }
            else { rules.insert(ascii) }
        }
    }

    /// The site for a URL, or nil for non-web URLs.
    func site(for url: URL) -> String? {
        guard let host = url.host(percentEncoded: false), !host.isEmpty else { return nil }
        return site(forHost: host)
    }

    func site(forHost rawHost: String) -> String {
        var host = rawHost.lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        if host.hasPrefix("[") { return host }                       // IPv6 literal
        if Self.isIPv4(host) || !host.contains(".") { return host }   // IPv4, localhost, intranet names
        lock.lock(); if let c = cache[host] { lock.unlock(); return c }; lock.unlock()

        let labels = host.split(separator: ".").map(String.init)
        var suffixLabels = 1                                          // implicit "*" rule
        for i in 0..<labels.count {
            let candidate = labels[i...].joined(separator: ".")
            if exceptions.contains(candidate) { suffixLabels = labels.count - i - 1; break }
            if rules.contains(candidate) { suffixLabels = labels.count - i; break }
            if i + 1 < labels.count, wildcards.contains(labels[(i + 1)...].joined(separator: ".")) {
                suffixLabels = labels.count - i; break
            }
        }
        let result = suffixLabels >= labels.count ? host : labels.suffix(suffixLabels + 1).joined(separator: ".")
        lock.lock(); if cache.count > 20_000 { cache.removeAll() }; cache[host] = result; lock.unlock()
        return result
    }

    static func isIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }

    /// Hosts that never leave the machine or local network.
    static func isLocal(_ host: String) -> Bool {
        let h = host.lowercased()
        if h == "localhost" || h.hasSuffix(".localhost") || h.hasSuffix(".local") || h == "::1" || h == "[::1]" { return true }
        if isIPv4(h) {
            let p = h.split(separator: ".").compactMap { Int($0) }
            return p[0] == 127 || p[0] == 10 || (p[0] == 192 && p[1] == 168) || (p[0] == 172 && (16...31).contains(p[1])) || (p[0] == 169 && p[1] == 254)
        }
        return !h.contains(".") && !h.contains(":")
    }

    /// Converts Unicode labels to punycode so they match what WebKit sends.
    private static func toASCII(_ s: String) -> String {
        if s.allSatisfy(\.isASCII) { return s }
        return s.split(separator: ".").map { label -> String in
            let l = String(label)
            if l.allSatisfy(\.isASCII) { return l }
            return "xn--" + (Punycode.encode(l) ?? l)
        }.joined(separator: ".")
    }
}

/// RFC 3492 Punycode encoder (only needed for the handful of non-ASCII suffix rules).
enum Punycode {
    static func encode(_ input: String) -> String? {
        let base = 36, tMin = 1, tMax = 26, skew = 38, damp = 700
        let scalars = input.unicodeScalars.map { Int($0.value) }
        var output = scalars.filter { $0 < 0x80 }.map { Character(UnicodeScalar($0)!) }
        let basicCount = output.count
        var handled = basicCount
        if basicCount > 0 { output.append("-") }
        var n = 0x80, delta = 0, bias = 72
        func digit(_ d: Int) -> Character { Character(UnicodeScalar(d < 26 ? d + 97 : d + 22)!) }
        func adapt(_ d: Int, _ numPoints: Int, _ first: Bool) -> Int {
            var delta = first ? d / damp : d / 2
            delta += delta / numPoints
            var k = 0
            while delta > ((base - tMin) * tMax) / 2 { delta /= base - tMin; k += base }
            return k + (base - tMin + 1) * delta / (delta + skew)
        }
        while handled < scalars.count {
            guard let m = scalars.filter({ $0 >= n }).min() else { return nil }
            delta += (m - n) * (handled + 1)
            n = m
            for c in scalars {
                if c < n { delta += 1 }
                if c == n {
                    var q = delta, k = base
                    while true {
                        let t = k <= bias ? tMin : (k >= bias + tMax ? tMax : k - bias)
                        if q < t { break }
                        output.append(digit(t + (q - t) % (base - t)))
                        q = (q - t) / (base - t)
                        k += base
                    }
                    output.append(digit(q))
                    bias = adapt(delta, handled + 1, handled == basicCount)
                    delta = 0
                    handled += 1
                }
            }
            delta += 1; n += 1
        }
        return String(output)
    }
}
