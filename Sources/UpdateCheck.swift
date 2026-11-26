import AppKit
import Foundation

/// A published Stowfin release, read from the GitHub Releases API.
struct ReleaseInfo: Equatable {
    let tag: String
    let version: String
    let name: String
    let url: URL
    let prerelease: Bool
    var displayVersion: String { version + (prerelease ? " Beta" : "") }
}

/// Checks GitHub for a newer release. This is the only network request the app makes:
/// one anonymous GET to the public Releases API, sent when the person asks or, if they
/// turned it on, at most once a day. Nothing about the Mac, its files or scans is sent,
/// and nothing is downloaded or installed; a newer version opens its release page.
enum UpdateCheck {
    static let releasesURL = URL(string: "https://api.github.com/repos/FishyJ10312/Stowfin/releases?per_page=20")!
    static let releasePagePrefix = "https://github.com/FishyJ10312/Stowfin/releases/"

    /// "v1.8.8-beta" → "1.8.8". Tags without a dotted version are ignored.
    static func version(fromTag tag: String) -> String? {
        guard let range = tag.range(of: #"^[vV]?[0-9]+(?:\.[0-9]+){1,3}"#, options: .regularExpression) else { return nil }
        let value = String(tag[range])
        return value.first == "v" || value.first == "V" ? String(value.dropFirst()) : value
    }
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }, b = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }
    private struct Payload: Decodable {
        let tag_name: String
        let name: String?
        let html_url: String
        let draft: Bool?
        let prerelease: Bool?
    }
    /// The highest published version in a Releases API response. Drafts and links outside
    /// this repository's release pages are ignored.
    static func latest(fromJSON data: Data) throws -> ReleaseInfo? {
        let releases = try JSONDecoder().decode([Payload].self, from: data)
        return releases.compactMap { payload -> ReleaseInfo? in
            guard payload.draft != true, payload.html_url.hasPrefix(releasePagePrefix),
                  let url = URL(string: payload.html_url), url.scheme == "https", url.host == "github.com",
                  let version = version(fromTag: payload.tag_name) else { return nil }
            return ReleaseInfo(tag: payload.tag_name, version: version, name: payload.name ?? payload.tag_name, url: url, prerelease: payload.prerelease == true)
        }.max { isNewer($1.version, than: $0.version) }
    }
    /// The newer release, or nil when `current` is already the latest.
    static func newerRelease(than current: String, in data: Data) throws -> ReleaseInfo? {
        guard let latest = try latest(fromJSON: data), isNewer(latest.version, than: current) else { return nil }
        return latest
    }
    static func fetch() async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15; configuration.timeoutIntervalForResource = 20
        configuration.httpCookieAcceptPolicy = .never; configuration.httpShouldSetCookies = false; configuration.urlCache = nil
        var request = URLRequest(url: releasesURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Stowfin-update-check", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession(configuration: configuration).data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }
}

@MainActor final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()
    enum State: Equatable { case idle, checking, upToDate, available(ReleaseInfo), failed }
    static let automaticKey = "QingSweep.automaticUpdateCheck"
    static let lastCheckKey = "QingSweep.lastUpdateCheck"
    @Published private(set) var state: State = .idle
    @Published var showingResult = false
    /// Off by default: the app stays offline unless the person checks or turns this on.
    @Published var automatic: Bool { didSet { defaults.set(automatic, forKey: Self.automaticKey); if automatic { checkAutomaticallyIfDue() } } }
    private let defaults: UserDefaults
    private let fetch: () async throws -> Data
    let currentVersion: String
    init(defaults: UserDefaults = .standard, currentVersion: String? = nil, fetch: @escaping () async throws -> Data = UpdateCheck.fetch) {
        self.defaults = defaults; self.fetch = fetch
        self.currentVersion = currentVersion ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        automatic = defaults.bool(forKey: Self.automaticKey)
    }
    var statusTitle: String {
        switch state {
        case .idle: return "检查更新"
        case .checking: return "正在检查更新…"
        case .upToDate: return "已是最新版本"
        case .available(let release): return "有新版本 " + release.displayVersion
        case .failed: return "检查更新失败"
        }
    }
    var resultMessage: String {
        switch state {
        case .available(let release): return "轻扫 \(release.displayVersion) 已发布，当前为 \(currentVersion)。前往发布页下载；轻扫不会自动下载或安装。"
        case .upToDate: return "当前 \(currentVersion) 已是最新版本。"
        case .failed: return "暂时无法连接 GitHub，请稍后重试。"
        case .idle, .checking: return ""
        }
    }
    var availableRelease: ReleaseInfo? { if case .available(let release) = state { return release }; return nil }
    func check(manual: Bool = true) {
        guard state != .checking else { return }
        state = .checking
        Task {
            do {
                let data = try await fetch()
                let release = try UpdateCheck.newerRelease(than: currentVersion, in: data)
                state = release.map { .available($0) } ?? .upToDate
                defaults.set(Date(), forKey: Self.lastCheckKey)
            } catch { state = .failed }
            // An automatic check only updates the sidebar status; it never interrupts with a dialog.
            if manual { showingResult = true }
        }
    }
    func checkAutomaticallyIfDue(now: Date = Date()) {
        guard automatic else { return }
        if let last = defaults.object(forKey: Self.lastCheckKey) as? Date, now.timeIntervalSince(last) < 86_400 { return }
        check(manual: false)
    }
    func openRelease() {
        guard let release = availableRelease, release.url.absoluteString.hasPrefix(UpdateCheck.releasePagePrefix) else { return }
        NSWorkspace.shared.open(release.url)
    }
}
