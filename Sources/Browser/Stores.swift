import AppKit
import Foundation
import Network
import WebKit

private let supportDir: URL = {
    let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Umbra", isDirectory: true)
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}()

struct Bookmark: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var url: URL
}

@MainActor
final class BookmarkStore: ObservableObject {
    static let shared = BookmarkStore()
    @Published private(set) var items: [Bookmark] = []
    private let file = supportDir.appendingPathComponent("bookmarks.json")

    private init() {
        if let d = try? Data(contentsOf: file), let b = try? JSONDecoder().decode([Bookmark].self, from: d) { items = b }
    }

    func contains(_ url: URL?) -> Bool { guard let url else { return false }; return items.contains { $0.url == url } }

    func toggle(_ url: URL, title: String) {
        if let i = items.firstIndex(where: { $0.url == url }) { items.remove(at: i) } else { items.append(Bookmark(title: title, url: url)) }
        save()
    }

    func remove(_ b: Bookmark) { items.removeAll { $0.id == b.id }; save() }

    private func save() { try? JSONEncoder().encode(items).write(to: file, options: .atomic) }
}

struct Visit: Codable, Hashable { var url: URL; var title: String; var date: Date }

/// History is kept in memory for this session only, unless you turn on "Remember history".
@MainActor
final class HistoryStore {
    static let shared = HistoryStore()
    private(set) var visits: [Visit] = []
    private let file = supportDir.appendingPathComponent("history.json")

    private init() {
        if AppSettings.shared.rememberHistory, let d = try? Data(contentsOf: file),
           let v = try? JSONDecoder().decode([Visit].self, from: d) { visits = v }
    }

    func record(_ url: URL, title: String) {
        guard url.scheme?.hasPrefix("http") == true else { return }
        visits.removeAll { $0.url == url }
        visits.append(Visit(url: url, title: title, date: Date()))
        if visits.count > 5000 { visits.removeFirst(visits.count - 5000) }
        if AppSettings.shared.rememberHistory { try? JSONEncoder().encode(visits).write(to: file, options: .atomic) }
    }

    func suggestions(for text: String, limit: Int = 6) -> [Visit] {
        let q = text.lowercased()
        guard !q.isEmpty else { return [] }
        var out: [Visit] = []
        var seen = Set<URL>()
        let bookmarks = BookmarkStore.shared.items.map { Visit(url: $0.url, title: $0.title, date: .distantFuture) }
        for v in (bookmarks + visits.reversed()) where !seen.contains(v.url) {
            let host = v.url.host()?.lowercased() ?? ""
            let stripped = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            if stripped.hasPrefix(q) || v.title.lowercased().contains(q) || v.url.absoluteString.lowercased().contains(q) {
                out.append(v); seen.insert(v.url)
                if out.count >= limit { break }
            }
        }
        return out
    }

    func clearAll() { visits.removeAll(); clearSaved() }
    func clearSaved() { try? FileManager.default.removeItem(at: file) }
}

/// Fetches site icons through the site's own container proxy (ad blocking + encrypted DNS,
/// no cookies), so loading an icon tells nobody more than visiting the page did.
@MainActor
final class FaviconLoader {
    static let shared = FaviconLoader()
    private var cache: [String: NSImage] = [:]
    private var sessions: [UInt16: URLSession] = [:]

    func cached(for page: URL?) -> NSImage? { page?.host().flatMap { cache[$0] } }

    func load(_ icon: URL, page: URL, proxyPort: UInt16, done: @escaping (NSImage?) -> Void) {
        guard let host = page.host() else { return done(nil) }
        if let c = cache[host] { return done(c) }
        let session = sessions[proxyPort] ?? {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.httpCookieStorage = nil
            cfg.httpShouldSetCookies = false
            cfg.timeoutIntervalForRequest = 8
            cfg.proxyConfigurations = [ProxyConfiguration(socksv5Proxy: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: proxyPort)!))]
            let s = URLSession(configuration: cfg)
            sessions[proxyPort] = s
            return s
        }()
        var req = URLRequest(url: icon)
        req.setValue(UserAgent.safari, forHTTPHeaderField: "User-Agent")
        session.dataTask(with: req) { data, resp, _ in
            let img = data.flatMap { (resp as? HTTPURLResponse)?.statusCode == 200 ? NSImage(data: $0) : nil }
            Task { @MainActor in
                if let img { self.cache[host] = img }
                done(img)
            }
        }.resume()
    }
}

/// Downloads go to ~/Downloads and are marked as downloaded from the web, so macOS
/// checks them (Gatekeeper) before they first open.
@MainActor
final class DownloadManager: NSObject, ObservableObject, WKDownloadDelegate {
    static let shared = DownloadManager()

    final class Item: ObservableObject, Identifiable {
        enum State: Equatable { case running, done, failed(String) }
        let id = UUID()
        let filename: String
        let destination: URL
        let source: URL?
        @Published var fraction: Double = 0
        @Published var state: State = .running
        var observation: NSKeyValueObservation?
        weak var download: WKDownload?
        init(filename: String, destination: URL, source: URL?) { self.filename = filename; self.destination = destination; self.source = source }
    }

    @Published private(set) var items: [Item] = []
    var active: Int { items.filter { $0.state == .running }.count }

    func attach(_ d: WKDownload) { d.delegate = self }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let safeName = suggestedFilename.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        var dest = dir.appendingPathComponent(safeName.isEmpty ? "download" : safeName)
        let base = dest.deletingPathExtension().lastPathComponent, ext = dest.pathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"); n += 1
        }
        let item = Item(filename: dest.lastPathComponent, destination: dest, source: response.url)
        item.download = download
        item.observation = download.progress.observe(\.fractionCompleted) { p, _ in
            let f = p.fractionCompleted
            Task { @MainActor in item.fraction = f }
        }
        items.insert(item, at: 0)
        return dest
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let item = items.first(where: { $0.download === download }) else { return }
        item.state = .done
        item.fraction = 1
        markQuarantined(item.destination, source: item.source)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        items.first { $0.download === download }?.state = .failed(error.localizedDescription)
    }

    func cancel(_ item: Item) { item.download?.cancel { _ in }; item.state = .failed("Cancelled") }
    func reveal(_ item: Item) { NSWorkspace.shared.activateFileViewerSelecting([item.destination]) }
    func clearFinished() { items.removeAll { $0.state != .running } }

    private func markQuarantined(_ url: URL, source: URL?) {
        var props: [String: Any] = [kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
                                    kLSQuarantineAgentNameKey as String: "Umbra"]
        if let source { props[kLSQuarantineDataURLKey as String] = source }
        try? (url as NSURL).setResourceValue(props, forKey: .quarantinePropertiesKey)
    }
}
