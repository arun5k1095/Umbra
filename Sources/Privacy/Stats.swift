import Foundation

/// Privacy counters for the new-tab page. Only numbers are kept: never which sites you
/// visited or which trackers were seen. Saved per day, last 30 days.
final class Stats: @unchecked Sendable {
    static let shared = Stats()
    enum Kind: String, CaseIterable { case ad, tracker, linkCleaned, httpsUpgrade }

    private var days: [String: [String: Int]] = [:]
    private let lock = NSLock()
    private var dirty = false
    private let key = "stats.v1"
    private let dayFormat: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()

    private init() {
        if let d = UserDefaults.standard.dictionary(forKey: key) as? [String: [String: Int]] { days = d }
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.save() }
    }

    func add(_ kind: Kind, _ n: Int = 1) {
        let today = dayFormat.string(from: Date())
        lock.lock(); days[today, default: [:]][kind.rawValue, default: 0] += n; dirty = true; lock.unlock()
    }

    func today(_ kind: Kind) -> Int {
        let today = dayFormat.string(from: Date())
        lock.lock(); defer { lock.unlock() }
        return days[today]?[kind.rawValue] ?? 0
    }

    func total(_ kind: Kind) -> Int {
        lock.lock(); defer { lock.unlock() }
        return days.values.reduce(0) { $0 + ($1[kind.rawValue] ?? 0) }
    }

    func reset() { lock.lock(); days.removeAll(); dirty = true; lock.unlock(); save() }

    func save() {
        lock.lock()
        guard dirty else { lock.unlock(); return }
        let keep = days.keys.sorted().suffix(30)
        days = days.filter { keep.contains($0.key) }
        let snapshot = days
        dirty = false
        lock.unlock()
        UserDefaults.standard.set(snapshot, forKey: key)
    }
}
