import Foundation
import Network

/// The live privacy switches, readable from any thread (the proxy runs off the main thread).
final class LivePrivacy: @unchecked Sendable {
    static let shared = LivePrivacy()
    struct Config {
        var blockAds = true
        var blockTrackers = true
        var dns: DNSProvider = .automatic
        var shieldsOff = Set<String>()     // sites where the user turned protections off
    }
    private var value = Config()
    private let lock = NSLock()
    var config: Config {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

enum DNSProvider: String, CaseIterable, Identifiable {
    case automatic, quad9, cloudflare, mullvad, system
    var id: String { rawValue }
    /// The encrypted, no-log resolvers Automatic chooses between.
    static let encrypted: [DNSProvider] = [.quad9, .cloudflare, .mullvad]

    var label: String {
        switch self {
        case .automatic: return "Automatic (fastest no-log resolver)"
        case .quad9: return "Quad9 (Switzerland, non-profit, no logs)"
        case .cloudflare: return "Cloudflare (1.1.1.1, audited, no IP logs)"
        case .mullvad: return "Mullvad (Sweden, no logs)"
        case .system: return "System DNS (not encrypted)"
        }
    }
    var shortName: String {
        switch self {
        case .automatic: return DoHResolver.shared.chosen.shortName
        case .quad9: return "Quad9"
        case .cloudflare: return "Cloudflare"
        case .mullvad: return "Mullvad"
        case .system: return "System"
        }
    }
    /// IP-based endpoints need no plain-DNS lookup to bootstrap.
    var endpoint: URL? {
        switch self {
        case .automatic: return DoHResolver.shared.chosen.endpoint
        case .quad9: return URL(string: "https://9.9.9.9/dns-query")
        case .cloudflare: return URL(string: "https://1.1.1.1/dns-query")
        case .mullvad: return URL(string: "https://dns.mullvad.net/dns-query")
        case .system: return nil
        }
    }
}

/// DNS over HTTPS (RFC 8484) so your ISP or Wi-Fi owner can't see which sites you look up.
/// Answers are cached by TTL; concurrent lookups for the same name share one request; a
/// connection is allowed to start as soon as the IPv4 answer arrives.
final class DoHResolver: @unchecked Sendable {
    static let shared = DoHResolver()

    enum DNSError: Error { case notFound, badResponse, network(String) }
    typealias Completion = (Result<[String], DNSError>) -> Void

    private let session: URLSession
    private var cache: [String: (ips: [String], expires: Date)] = [:]
    private var inflight: [String: [Completion]] = [:]
    private let lock = NSLock()
    private var monitor: NWPathMonitor?
    private var _chosen: DNSProvider = .cloudflare
    private(set) var lookups = 0
    private(set) var latencies: [DNSProvider: Double] = [:]

    /// The resolver Automatic currently uses.
    var chosen: DNSProvider { lock.lock(); defer { lock.unlock() }; return _chosen }

    private init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 6
        cfg.httpCookieStorage = nil
        cfg.urlCache = nil
        cfg.httpMaximumConnectionsPerHost = 2
        cfg.waitsForConnectivity = false
        session = URLSession(configuration: cfg)
    }

    func clearCache() { lock.lock(); cache.removeAll(); lock.unlock() }

    /// Picks the fastest encrypted resolver now and whenever the network changes, and
    /// keeps the HTTPS connection to it warm so the first page load doesn't pay for it.
    func start() {
        benchmark()
        let m = NWPathMonitor()
        var first = true
        m.pathUpdateHandler = { [weak self] path in
            if first { first = false; return }
            if path.status == .satisfied { self?.clearCache(); self?.benchmark() }
        }
        m.start(queue: .global(qos: .utility))
        monitor = m
        Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { [weak self] _ in self?.keepWarm() }
    }

    private func benchmark() {
        let group = DispatchGroup()
        var results: [DNSProvider: Double] = [:]
        let rl = NSLock()
        for p in DNSProvider.encrypted {
            guard let url = p.endpoint else { continue }
            group.enter()
            // First query opens the connection; the second measures a warm round trip.
            query("example.com", type: 1, endpoint: url) { [self] first in
                guard case .success = first else { group.leave(); return }
                let t0 = Date()
                query("apple.com", type: 1, endpoint: url) { second in
                    if case .success = second { rl.lock(); results[p] = Date().timeIntervalSince(t0) * 1000; rl.unlock() }
                    group.leave()
                }
            }
        }
        group.notify(queue: .global(qos: .utility)) { [self] in
            lock.lock()
            latencies = results
            if let best = results.min(by: { $0.value < $1.value })?.key { _chosen = best }
            lock.unlock()
        }
    }

    private func keepWarm() {
        let cfg = LivePrivacy.shared.config
        guard cfg.dns != .system, let url = cfg.dns.endpoint else { return }
        query("example.com", type: 1, endpoint: url) { _ in }
    }

    /// Resolves a host to IP addresses (IPv4 first). For the system provider, IP literals and
    /// local names, returns the host unchanged so the OS resolves it.
    func resolve(_ host: String, provider: DNSProvider, completion: @escaping Completion) {
        let h = host.lowercased()
        guard let endpoint = provider.endpoint, !PublicSuffix.isLocal(h), !PublicSuffix.isIPv4(h), !h.contains(":") else {
            completion(.success([host])); return
        }
        lock.lock()
        if let hit = cache[h], hit.expires > Date() { lock.unlock(); completion(.success(hit.ips)); return }
        if inflight[h] != nil { inflight[h]!.append(completion); lock.unlock(); return }
        inflight[h] = [completion]
        lookups += 1
        lock.unlock()

        let state = LookupState()
        for type: UInt16 in [1, 28] {
            query(h, type: type, endpoint: endpoint) { [self] result in
                let (finishNow, ips, ttl, failure) = state.add(type: type, result: result)
                if let ips { store(h, ips: ips, ttl: ttl) }
                if finishNow { deliver(h, ips.map { .success($0) } ?? .failure(failure ?? .notFound)) }
            }
        }
    }

    private func store(_ h: String, ips: [String], ttl: UInt32) {
        let life = TimeInterval(min(max(ttl == .max ? 300 : ttl, 60), 3600))
        lock.lock()
        if cache.count > 5000 { cache.removeAll() }
        cache[h] = (ips, Date().addingTimeInterval(life))
        lock.unlock()
    }

    private func deliver(_ h: String, _ result: Result<[String], DNSError>) {
        lock.lock()
        let waiters = inflight.removeValue(forKey: h) ?? []
        lock.unlock()
        waiters.forEach { $0(result) }
    }

    /// Combines the A and AAAA answers: finishes on the first usable IPv4 answer, otherwise
    /// waits for both; a later IPv6 answer just extends the cached list.
    private final class LookupState: @unchecked Sendable {
        private let l = NSLock()
        private var v4: [String]? , v6: [String]?
        private var ttl = UInt32.max
        private var delivered = false
        private var failure: DNSError?

        func add(type: UInt16, result: Result<([String], UInt32), DNSError>) -> (Bool, [String]?, UInt32, DNSError?) {
            l.lock(); defer { l.unlock() }
            switch result {
            case .success(let (ips, t)):
                if type == 1 { v4 = ips } else { v6 = ips }
                if !ips.isEmpty { ttl = min(ttl, t) }
            case .failure(let e):
                if type == 1 { v4 = [] ; failure = e } else { v6 = [] }
            }
            let all = (v4 ?? []) + (v6 ?? [])
            if delivered { return (false, all.isEmpty ? nil : all, ttl, nil) }
            let finish = (type == 1 && !(v4 ?? []).isEmpty) || (v4 != nil && v6 != nil)
            if finish { delivered = true }
            return (finish, all.isEmpty ? nil : all, ttl, failure)
        }
    }

    private func query(_ host: String, type: UInt16, endpoint: URL, completion: @escaping (Result<([String], UInt32), DNSError>) -> Void) {
        guard let body = Self.buildQuery(host, type: type) else { completion(.failure(.badResponse)); return }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("application/dns-message", forHTTPHeaderField: "Content-Type")
        req.setValue("application/dns-message", forHTTPHeaderField: "Accept")
        session.dataTask(with: req) { data, resp, err in
            if let err { completion(.failure(.network(err.localizedDescription))); return }
            guard (resp as? HTTPURLResponse)?.statusCode == 200, let data else { completion(.failure(.badResponse)); return }
            completion(Self.parse(data, type: type))
        }.resume()
    }

    static func buildQuery(_ host: String, type: UInt16) -> Data? {
        var d = Data([0, 0, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0])   // ID 0, recursion desired, 1 question
        for label in host.split(separator: ".") {
            let bytes = Array(label.utf8)
            guard !bytes.isEmpty, bytes.count <= 63 else { return nil }
            d.append(UInt8(bytes.count)); d.append(contentsOf: bytes)
        }
        d.append(0)
        d.append(contentsOf: [UInt8(type >> 8), UInt8(type & 0xff), 0, 1])
        return d
    }

    static func parse(_ data: Data, type: UInt16) -> Result<([String], UInt32), DNSError> {
        let b = [UInt8](data)
        guard b.count >= 12 else { return .failure(.badResponse) }
        let rcode = b[3] & 0x0f
        if rcode == 3 { return .failure(.notFound) }
        guard rcode == 0 else { return .failure(.badResponse) }
        let qd = Int(b[4]) << 8 | Int(b[5]), an = Int(b[6]) << 8 | Int(b[7])
        var i = 12
        func skipName() -> Bool {
            while i < b.count {
                let len = Int(b[i])
                if len == 0 { i += 1; return true }
                if len & 0xC0 == 0xC0 { i += 2; return i <= b.count }
                i += len + 1
            }
            return false
        }
        for _ in 0..<qd { guard skipName(), i + 4 <= b.count else { return .failure(.badResponse) }; i += 4 }
        var ips: [String] = [], ttl = UInt32.max
        for _ in 0..<an {
            guard skipName(), i + 10 <= b.count else { break }
            let rtype = UInt16(b[i]) << 8 | UInt16(b[i + 1])
            let t = UInt32(b[i + 4]) << 24 | UInt32(b[i + 5]) << 16 | UInt32(b[i + 6]) << 8 | UInt32(b[i + 7])
            let rdlen = Int(b[i + 8]) << 8 | Int(b[i + 9])
            i += 10
            guard i + rdlen <= b.count else { break }
            if rtype == 1 && rdlen == 4 && type == 1 {
                ips.append(b[i..<i + 4].map(String.init).joined(separator: ".")); ttl = min(ttl, t)
            } else if rtype == 28 && rdlen == 16 && type == 28 {
                var groups: [String] = []
                for g in stride(from: i, to: i + 16, by: 2) { groups.append(String(UInt16(b[g]) << 8 | UInt16(b[g + 1]), radix: 16)) }
                ips.append(groups.joined(separator: ":")); ttl = min(ttl, t)
            }
            i += rdlen
        }
        return .success((ips, ttl))
    }
}
