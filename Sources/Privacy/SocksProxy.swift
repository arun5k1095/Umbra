import Foundation
import Network

/// What a site's pages tried to connect to. Updated from proxy queues, read by the UI.
final class SiteReport: @unchecked Sendable {
    struct Entry { var host: String; var category: Blocker.Category?; var count: Int }
    private var blocked: [String: Entry] = [:]
    private var allowed: [String: Int] = [:]
    private var pageBlocked = 0, pageAds = 0, pageTrackers = 0
    private var pageBlockedHosts: [String: Entry] = [:]
    private var pageAllowedHosts = Set<String>()
    private(set) var totalBlocked = 0
    private var lastBlockedHost: (host: String, at: Date)?
    private let lock = NSLock()

    struct Snapshot {
        var blocked: [Entry]           // this page, most frequent first
        var contacted: [String]        // hosts this page was allowed to reach
        var ads: Int, trackers: Int
        var sessionBlocked: Int
    }

    func beginPage() {
        lock.lock()
        pageBlocked = 0; pageAds = 0; pageTrackers = 0
        pageBlockedHosts.removeAll(); pageAllowedHosts.removeAll()
        lock.unlock()
    }

    func recordBlocked(_ host: String, _ category: Blocker.Category) {
        lock.lock()
        totalBlocked += 1; pageBlocked += 1
        if category == .ad { pageAds += 1 } else { pageTrackers += 1 }
        pageBlockedHosts[host, default: Entry(host: host, category: category, count: 0)].count += 1
        blocked[host, default: Entry(host: host, category: category, count: 0)].count += 1
        lastBlockedHost = (host, Date())
        lock.unlock()
        Stats.shared.add(category == .ad ? .ad : .tracker)
    }

    func recordAllowed(_ host: String) {
        lock.lock(); allowed[host, default: 0] += 1; pageAllowedHosts.insert(host); lock.unlock()
    }

    /// True if `host` was blocked in the last few seconds (used to explain a failed page load).
    func recentlyBlocked(_ host: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let l = lastBlockedHost else { return false }
        return l.host == host.lowercased() && Date().timeIntervalSince(l.at) < 5
    }

    var pageBlockedCount: Int { lock.lock(); defer { lock.unlock() }; return pageBlocked }

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(blocked: pageBlockedHosts.values.sorted { $0.count > $1.count },
                        contacted: pageAllowedHosts.sorted(), ads: pageAds, trackers: pageTrackers,
                        sessionBlocked: totalBlocked)
    }
}

/// A tiny SOCKS5 proxy on 127.0.0.1, one per site container. WebKit sends it the hostname
/// of every connection a page makes; the proxy blocks ads and trackers, resolves the rest
/// over encrypted DNS, and relays the bytes. HTTPS stays end-to-end encrypted: the proxy
/// only ever sees host names and ports, never page content.
final class SocksProxy: @unchecked Sendable {
    let site: String
    let report = SiteReport()
    private(set) var port: UInt16 = 0
    private let listener: NWListener
    private let queue: DispatchQueue
    private var relays = Set<ObjectIdentifier>()
    private var relayObjects: [ObjectIdentifier: Relay] = [:]
    private let lock = NSLock()

    init(site: String) throws {
        self.site = site
        queue = DispatchQueue(label: "umbra.proxy.\(site)", qos: .userInitiated)
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 2)
        guard let p = listener.port?.rawValue, p != 0 else { throw NSError(domain: "Umbra", code: 1) }
        port = p
    }

    func stop() { listener.cancel() }

    private func accept(_ conn: NWConnection) {
        let relay = Relay(client: conn, proxy: self)
        let id = ObjectIdentifier(relay)
        lock.lock(); relayObjects[id] = relay; lock.unlock()
        relay.start()
    }

    fileprivate func finished(_ relay: Relay) {
        lock.lock(); relayObjects.removeValue(forKey: ObjectIdentifier(relay)); lock.unlock()
    }

    fileprivate func decide(_ host: String) -> Blocker.Verdict {
        let cfg = LivePrivacy.shared.config
        if cfg.shieldsOff.contains(site) { return .allow }
        return Blocker.shared.check(host: host, site: site, ads: cfg.blockAds, trackers: cfg.blockTrackers)
    }
}

/// One proxied TCP connection: SOCKS5 handshake, policy check, DNS, then a two-way byte pump.
private final class Relay: @unchecked Sendable {
    let client: NWConnection
    var remote: NWConnection?
    weak var proxy: SocksProxy?
    let q = DispatchQueue(label: "umbra.relay", qos: .userInitiated)
    var closed = false
    var halfClosed = 0

    init(client: NWConnection, proxy: SocksProxy) { self.client = client; self.proxy = proxy }

    func start() {
        client.stateUpdateHandler = { [weak self] s in
            switch s { case .failed, .cancelled: self?.close(); default: break }
        }
        client.start(queue: q)
        readExact(2) { [self] hello in
            guard hello[0] == 5 else { return close() }
            readExact(Int(hello[1])) { [self] _ in
                client.send(content: Data([5, 0]), completion: .contentProcessed { _ in })   // no auth
                readRequest()
            }
        }
    }

    private func readExact(_ n: Int, _ next: @escaping ([UInt8]) -> Void) {
        if n == 0 { next([]); return }
        client.receive(minimumIncompleteLength: n, maximumLength: n) { [weak self] data, _, _, err in
            guard let self, err == nil, let data, data.count == n else { self?.close(); return }
            next([UInt8](data))
        }
    }

    private func readRequest() {
        readExact(4) { [self] h in
            guard h[0] == 5, h[1] == 1 else { return reply(7) }          // CONNECT only
            switch h[3] {
            case 1: readExact(6) { [self] a in connect(a[0..<4].map(String.init).joined(separator: "."), port(a[4], a[5])) }
            case 3: readExact(1) { [self] l in readExact(Int(l[0]) + 2) { [self] a in
                let host = String(decoding: a[0..<Int(l[0])], as: UTF8.self)
                connect(host, port(a[Int(l[0])], a[Int(l[0]) + 1])) } }
            case 4: readExact(18) { [self] a in
                var g: [String] = []
                for i in stride(from: 0, to: 16, by: 2) { g.append(String(UInt16(a[i]) << 8 | UInt16(a[i + 1]), radix: 16)) }
                connect(g.joined(separator: ":"), port(a[16], a[17])) }
            default: reply(8)
            }
        }
    }

    private func port(_ hi: UInt8, _ lo: UInt8) -> UInt16 { UInt16(hi) << 8 | UInt16(lo) }

    private func connect(_ host: String, _ port: UInt16) {
        guard let proxy else { return close() }
        if case .block(let category, _) = proxy.decide(host) {
            proxy.report.recordBlocked(host.lowercased(), category)
            return reply(2)                                              // "not allowed by ruleset"
        }
        proxy.report.recordAllowed(host.lowercased())
        let provider = LivePrivacy.shared.config.dns
        DoHResolver.shared.resolve(host, provider: provider) { [weak self] result in
            guard let self else { return }
            self.q.async {
                switch result {
                case .success(let ips): self.dial(ips, port: port)
                case .failure(.notFound): self.reply(4)                  // host unreachable
                case .failure: self.reply(1)
                }
            }
        }
    }

    private func dial(_ addrs: [String], port: UInt16) {
        guard let addr = addrs.first, let p = NWEndpoint.Port(rawValue: port) else { return reply(4) }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 10
        let r = NWConnection(host: NWEndpoint.Host(addr), port: p, using: NWParameters(tls: nil, tcp: tcp))
        remote = r
        var settled = false
        r.stateUpdateHandler = { [weak self] s in
            guard let self else { return }
            switch s {
            case .ready:
                guard !settled else { return }
                settled = true
                self.client.send(content: Data([5, 0, 0, 1, 0, 0, 0, 0, 0, 0]), completion: .contentProcessed { [weak self] _ in
                    guard let self else { return }
                    self.pump(from: self.client, to: r)
                    self.pump(from: r, to: self.client)
                })
            case .waiting, .failed:
                guard !settled else { if case .failed = s { self.close() }; return }
                settled = true
                r.cancel()
                let rest = Array(addrs.dropFirst())
                if rest.isEmpty { self.reply(5) } else { self.dial(rest, port: port) }
            case .cancelled:
                if settled { self.close() }
            default: break
            }
        }
        r.start(queue: q)
    }

    private func pump(from: NWConnection, to: NWConnection) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, err in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                to.send(content: data, completion: .contentProcessed { [weak self] e in
                    guard let self else { return }
                    if e != nil { self.close() } else if !isComplete { self.pump(from: from, to: to) } else { self.finishHalf(to) }
                })
            } else if isComplete {
                self.finishHalf(to)
            } else if err != nil {
                self.close()
            } else {
                self.pump(from: from, to: to)
            }
        }
    }

    private func finishHalf(_ to: NWConnection) {
        to.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
        halfClosed += 1
        if halfClosed >= 2 { close() }
    }

    private func reply(_ code: UInt8) {
        client.send(content: Data([5, code, 0, 1, 0, 0, 0, 0, 0, 0]), completion: .contentProcessed { [weak self] _ in self?.close() })
    }

    func close() {
        q.async { [self] in
            guard !closed else { return }
            closed = true
            client.cancel()
            remote?.cancel()
            proxy?.finished(self)
        }
    }
}
