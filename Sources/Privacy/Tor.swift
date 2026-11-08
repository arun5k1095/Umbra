import Foundation

/// Runs the Tor program bundled inside Umbra (Contents/Helpers/tor) for Tor windows.
///
/// Tor starts the first time a Tor window opens and stops when Umbra quits. If Umbra crashes,
/// Tor notices (`__OwningControllerProcess`) and exits by itself. Each site's container talks
/// to Tor with its own SOCKS username, and Tor's `IsolateSOCKSAuth` then gives every site its
/// own circuit, so two sites can't link your visits by your exit address either.
@MainActor
final class TorService: ObservableObject {
    enum State: Equatable {
        case off
        case connecting(Int, String)     // bootstrap percent, Tor's own summary
        case ready
        case failed(String)
    }

    static let shared = TorService()
    @Published private(set) var state: State = .off
    @Published private(set) var version = ""
    private var process: Process?
    private var pending = ""
    private var lastError = ""
    private var startedAt = Date()
    private var stopping = false

    static var executable: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/tor") }
    static var isBundled: Bool { FileManager.default.isExecutableFile(atPath: executable.path) }

    /// Tor's own data (relay directory cache and guard choice; never anything about the sites you visit).
    static var dataDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Umbra/Tor", isDirectory: true)
    }

    var isReady: Bool { state == .ready }

    func start() {
        if let p = process, p.isRunning { return }
        guard Self.isBundled else { return fail("Tor isn't included in this copy of Umbra.") }
        let fm = FileManager.default
        let dir = Self.dataDirectory
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)   // Tor insists on this
        } catch { return fail("Couldn't create Tor's folder: \(error.localizedDescription)") }
        let torrc = dir.appendingPathComponent("torrc")
        if !fm.fileExists(atPath: torrc.path) { fm.createFile(atPath: torrc.path, contents: Data()) }

        let p = Process()
        p.executableURL = Self.executable
        p.currentDirectoryURL = dir
        p.arguments = [
            "--defaults-torrc", torrc.path, "-f", torrc.path,
            "--SocksPort", "127.0.0.1:auto IsolateSOCKSAuth",
            "--DataDirectory", dir.path,
            "--ClientOnly", "1",
            "--AvoidDiskWrites", "1",
            "--Log", "notice stdout",
            "--__OwningControllerProcess", String(getpid()),
        ]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            let s = String(decoding: d, as: UTF8.self)
            Task { @MainActor in TorService.shared.consume(s) }
        }
        p.terminationHandler = { proc in
            let code = proc.terminationStatus
            Task { @MainActor in TorService.shared.exited(code) }
        }
        stopping = false
        lastError = ""
        startedAt = Date()
        state = .connecting(0, "Starting Tor")
        do { try p.run(); process = p } catch { return fail("Couldn't start Tor: \(error.localizedDescription)") }

        // If the network blocks Tor, bootstrap stalls. Say so, but keep trying in the background.
        let started = startedAt
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) { [weak self] in
            guard let self, self.startedAt == started, case .connecting(let pct, _) = self.state else { return }
            self.state = .failed("Tor is taking too long to connect (stuck at \(pct)%). Your network may be blocking Tor. Umbra keeps trying.")
        }
    }

    func stop() {
        stopping = true
        process?.terminate()
        process = nil
        TorLive.shared.setDown()
        state = .off
    }

    /// New circuits for everything opened from now on, and fresh, empty containers for Tor windows.
    func newIdentity() {
        TorLive.shared.rotateIdentity()
        ContainerManager.shared.dropTorContainers()
        for b in BrowserRegistry.all where b.tor {
            for t in b.tabs { t.reopenInFreshContainer() }
        }
    }

    private func consume(_ chunk: String) {
        pending += chunk
        while let nl = pending.firstIndex(of: "\n") {
            let line = String(pending[..<nl])
            pending.removeSubrange(...nl)
            handle(line)
        }
    }

    private func handle(_ line: String) {
        if version.isEmpty, let r = line.range(of: #"Tor \d+\.\d+\.\d+\.\d+"#, options: .regularExpression) {
            version = String(line[r].dropFirst(4))
        }
        if let r = line.range(of: #"listening on port \d+"#, options: .regularExpression),
           let port = UInt16(line[r].split(separator: " ").last ?? "") {
            TorLive.shared.setPort(port)
        }
        if let r = line.range(of: #"Bootstrapped \d+% \([^)]*\): .*"#, options: .regularExpression) {
            let s = line[r]
            let pct = Int(s.dropFirst("Bootstrapped ".count).prefix { $0.isNumber }) ?? 0
            let summary = s.range(of: "): ").map { String(s[$0.upperBound...]) } ?? ""
            if pct >= 100 {
                state = .ready
                TorLive.shared.setReady()
            } else if state != .ready {
                state = .connecting(pct, summary)
            }
        }
        if line.contains("[err]") || line.contains("[warn]") {
            lastError = line.components(separatedBy: "] ").dropFirst().joined(separator: "] ")
        }
    }

    private func exited(_ code: Int32) {
        process = nil
        TorLive.shared.setDown()
        if stopping { state = .off; return }
        fail(lastError.isEmpty ? "Tor stopped unexpectedly (code \(code))." : "Tor stopped: \(lastError)")
    }

    private func fail(_ message: String) {
        state = .failed(message)
        TorLive.shared.setDown()
    }
}

/// The part of Tor's state the proxy needs, readable from any queue.
final class TorLive: @unchecked Sendable {
    static let shared = TorLive()
    private let lock = NSLock()
    private var port: UInt16 = 0
    private var ready = false
    private var running = false
    private var waiters: [UUID: (UInt16?) -> Void] = [:]
    private var identity = UUID().uuidString

    /// Password half of the SOCKS credentials. Changing it means new circuits for every site.
    var isolationKey: String { lock.lock(); defer { lock.unlock() }; return identity }
    var isReady: Bool { lock.lock(); defer { lock.unlock() }; return ready }

    func rotateIdentity() { lock.lock(); identity = UUID().uuidString; lock.unlock() }

    func setPort(_ p: UInt16) { lock.lock(); port = p; running = true; lock.unlock() }

    func setReady() {
        lock.lock()
        ready = true; running = true
        let p = port, w = waiters
        waiters.removeAll()
        lock.unlock()
        w.values.forEach { $0(p) }
    }

    func setDown() {
        lock.lock()
        ready = false; running = false
        let w = waiters
        waiters.removeAll()
        lock.unlock()
        w.values.forEach { $0(nil) }
    }

    /// Calls back with Tor's SOCKS port once Tor is connected, or nil if it isn't within `timeout`.
    func whenReady(timeout: Double, queue: DispatchQueue, _ done: @escaping @Sendable (UInt16?) -> Void) {
        lock.lock()
        if ready { let p = port; lock.unlock(); queue.async { done(p) }; return }
        let id = UUID()
        waiters[id] = { p in queue.async { done(p) } }
        lock.unlock()
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let w = self.waiters.removeValue(forKey: id)
            self.lock.unlock()
            w?(nil)
        }
    }
}

extension String {
    var isOnionHost: Bool { lowercased().hasSuffix(".onion") }
}
