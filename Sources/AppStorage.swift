import Foundation

enum StorageComponent: String, Codable { case program, data, cache, logs
    var title: String { switch self { case .program: return "程序"; case .data: return "数据"; case .cache: return "缓存"; case .logs: return "日志" } }
}
struct StorageOwner: Equatable {
    let id: String
    let title: String
    let applicationURL: URL?
}
struct AppStorageSummary: Identifiable {
    let id: String
    let title: String
    var programBytes: Int64 = 0
    var dataBytes: Int64 = 0
    var cacheBytes: Int64 = 0
    var logBytes: Int64 = 0
    var unreadableCount = 0
    var readableCount = 0
    var candidateBytes: Int64 = 0
    var applicationURL: URL?
    var bytes: Int64 { programBytes + dataBytes + cacheBytes + logBytes }
    var partial: Bool { unreadableCount > 0 }
    var hasReadData: Bool { readableCount > 0 }
}
struct CleanupAppGroup: Identifiable {
    let id: String
    let title: String
    let items: [ScanItem]
    var bytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
}

/// Identity is based on exact installed identifiers, known product paths or OS
/// container identity. Shared vendor directories never belong to a guessed app.
final class StorageOwnerResolver {
    let applications: [InstalledApplication]
    private var ids: [String: InstalledApplication] = [:]
    private var paths: [String: InstalledApplication] = [:]
    private var exactNames: [String: String] = [:]
    private var cache: [String: StorageOwner] = [:]
    init(applications: [InstalledApplication]) {
        self.applications = applications
        for app in applications.sorted(by: { $0.version.compare($1.version, options: .numeric) == .orderedDescending }) {
            paths[app.path] = app
            if ids[app.id] == nil { ids[app.id] = app }
        }
        let names = Dictionary(grouping: applications, by: { $0.name.lowercased() })
        for (name, apps) in names where Set(apps.map(\.id)).count == 1 { exactNames[name] = apps[0].id }
    }
    static let products: [String: (String, String)] = [
        "Google Chrome": ("com.google.Chrome", "Google Chrome"), "Chrome": ("com.google.Chrome", "Google Chrome"),
        "Claude": ("com.anthropic.claudefordesktop", "Claude"),
        "Code": ("com.microsoft.VSCode", "Visual Studio Code"), "Visual Studio Code": ("com.microsoft.VSCode", "Visual Studio Code"),
        "Steam": ("com.valvesoftware.steam", "Steam"), "Spotify": ("com.spotify.client", "Spotify"),
        "IINA": ("com.colliderli.iina", "IINA"), "DaVinci Resolve": ("com.blackmagic-design.DaVinciResolve", "DaVinci Resolve"),
        "Codex": ("com.openai.codex", "Codex"), "DJI Studio": ("com.light.studio", "DJI Studio"),
        "UU 加速器": ("com.netease.uumac", "UU 加速器"), "UUBooster": ("com.netease.uumac", "UU 加速器"),
        "Mos": ("com.caldis.Mos", "Mos"), "迅雷": ("com.xunlei.Thunder", "迅雷"), "Bitz Net": ("org.erb.vortex", "Bitz Net")
    ]
    func owner(id: String, fallback: String) -> StorageOwner {
        StorageOwner(id: id, title: ids[id]?.name ?? fallback, applicationURL: ids[id].map { URL(fileURLWithPath: $0.path) })
    }
    private func known(_ name: String) -> StorageOwner? {
        if let app = ids[name] { return owner(id: app.id, fallback: app.name) }
        if name.hasPrefix("group."), let app = ids[String(name.dropFirst(6))] { return owner(id: app.id, fallback: app.name) }
        if name.hasSuffix(".ShipIt"), let app = ids[String(name.dropLast(7))] { return owner(id: app.id, fallback: app.name) }
        if let product = Self.products[name] { return owner(id: product.0, fallback: product.1) }
        if let id = exactNames[name.lowercased()] { return owner(id: id, fallback: name) }
        return nil
    }
    func resolve(_ url: URL, root: StorageRoot) -> StorageOwner {
        if let app = paths[root.url.path] { return owner(id: app.id, fallback: app.name) }
        if url.path.contains(".app"), let position = url.pathComponents.firstIndex(where: { $0.hasSuffix(".app") }) {
            let bundlePath = "/" + url.pathComponents[1...position].joined(separator: "/")
            if let app = paths[bundlePath] { return owner(id: app.id, fallback: app.name) }
        }
        if root.kind == .project { return StorageOwner(id: "personal:" + root.url.path, title: root.title, applicationURL: nil) }
        let parts = ["Caches", "Application Support", "Containers", "Group Containers", "Logs"].contains(root.url.lastPathComponent) || root.kind == .system ? [] : url.pathComponents
        if let position = parts.indices.first(where: { $0 > 0 && parts[$0 - 1] == "Library" && ["Caches", "Application Support", "Containers", "Group Containers", "Logs"].contains(parts[$0]) }) {
            let canonical = URL(fileURLWithPath: "/" + parts[1...position].joined(separator: "/"))
            if canonical.path != root.url.path { return resolve(url, root: StorageRoot(url: canonical, title: root.title, kind: root.kind)) }
        }
        let relative = url.path.dropFirst(root.url.path.count + 1).split(separator: "/", maxSplits: 2).map(String.init)
        guard let first = relative.first else { return StorageOwner(id: "unassigned", title: "未识别资源", applicationURL: nil) }
        let top = root.url.appendingPathComponent(first)
        if let cached = cache[top.path] {
            // Google is a vendor directory; Chrome is identified only by its exact child.
            if first == "Google", relative.count > 1, relative[1] == "Chrome" { return owner(id: "com.google.Chrome", fallback: "Google Chrome") }
            return cached
        }
        let resolved: StorageOwner
        if first == "Google" {
            resolved = StorageOwner(id: "shared:Google", title: "Google 共享资源", applicationURL: nil)
        } else if first == "Adobe" || first.hasPrefix("Adobe Camera Raw") || first == "CreativeCloud" {
            resolved = StorageOwner(id: "shared:Adobe", title: "Adobe 共享资源", applicationURL: nil)
        } else if first == "Blackmagic Design" {
            resolved = StorageOwner(id: "shared:Blackmagic", title: "Blackmagic 共享资源", applicationURL: nil)
        } else if first == "pip" || first == "Homebrew" {
            resolved = StorageOwner(id: "tool:" + first, title: first == "pip" ? "Python / pip" : first, applicationURL: nil)
        } else if first == "group.com.apple.coreservices.useractivityd" {
            resolved = StorageOwner(id: "system:clipboard", title: "共享剪贴板", applicationURL: nil)
        } else if let known = known(first) { resolved = known }
        else if ["Containers", "Group Containers"].contains(root.url.lastPathComponent),
                let stamp = FileStamp.read(top.appendingPathComponent(".com.apple.containermanagerd.metadata.plist")), stamp.isRegular, stamp.links == 1, !stamp.isDataless, stamp.size < 1_000_000,
                let data = try? Data(contentsOf: top.appendingPathComponent(".com.apple.containermanagerd.metadata.plist")),
                let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                let identifier = plist["MCMMetadataIdentifier"] as? String, let identified = known(identifier) { resolved = identified }
        else if root.kind == .system { resolved = StorageOwner(id: "system", title: "系统资源", applicationURL: nil) }
        else { resolved = StorageOwner(id: "unassigned", title: "未识别资源", applicationURL: nil) }
        cache[top.path] = resolved
        if first == "Google", relative.count > 1, relative[1] == "Chrome" { return owner(id: "com.google.Chrome", fallback: "Google Chrome") }
        return resolved
    }
    func cleanupOwner(_ item: ScanItem) -> StorageOwner {
        let assessment = item.assessment
        if assessment.owner.hasPrefix("Adobe") || assessment.owner == "CreativeCloud" { return StorageOwner(id: "shared:Adobe", title: "Adobe 共享资源", applicationURL: nil) }
        if assessment.ruleID == "cache-pip" { return StorageOwner(id: "tool:pip", title: "Python / pip", applicationURL: nil) }
        if assessment.ruleID == "cache-homebrew" { return StorageOwner(id: "tool:Homebrew", title: "Homebrew", applicationURL: nil) }
        if assessment.ruleID == "cache-go-build" { return StorageOwner(id: "tool:" + assessment.owner, title: assessment.owner, applicationURL: nil) }
        if let value = known(assessment.owner) { return value }
        if assessment.ruleID.hasPrefix("resolve-") { return owner(id: "com.blackmagic-design.DaVinciResolve", fallback: "DaVinci Resolve") }
        if [.photo,.video,.audio,.project,.preset,.document,.archive,.other].contains(assessment.category) {
            return StorageOwner(id: "personal:" + assessment.category.rawValue, title: assessment.category.title, applicationURL: nil)
        }
        return StorageOwner(id: "unassigned", title: "未识别资源", applicationURL: nil)
    }
    static func component(for root: StorageRoot, url: URL? = nil) -> StorageComponent {
        let location = url ?? root.url
        if location.pathComponents.contains(where: { $0.hasSuffix(".app") }) { return .program }
        if location.path.contains("/Library/Logs/") || location.lastPathComponent == "Logs" { return .logs }
        if root.kind == .cache || location.path.contains("/Library/Caches/") { return .cache }
        return .data
    }
}
