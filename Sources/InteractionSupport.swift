import Foundation
import Darwin

struct CleanupPreferences: Codable, Equatable {
    private(set) var ignoredPaths: [String]

    init(ignoredPaths: [String] = []) {
        self.ignoredPaths = Self.normalized(ignoredPaths)
    }

    private enum CodingKeys: String, CodingKey { case ignoredPaths }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        ignoredPaths = Self.normalized(try values.decodeIfPresent([String].self, forKey: .ignoredPaths) ?? [])
    }

    private static func normalized(_ paths: [String]) -> [String] {
        Array(Set(paths.compactMap { path -> String? in
            guard path.hasPrefix("/"), !path.contains("\0") else { return nil }
            return URL(fileURLWithPath: path).standardizedFileURL.path
        })).sorted()
    }

    func isIgnored(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        return ignoredPaths.contains { SafetyPolicy.within(url, URL(fileURLWithPath: $0)) }
    }

    mutating func ignore(_ url: URL) {
        guard url.isFileURL else { return }
        ignoredPaths = Self.normalized(ignoredPaths + [url.path])
    }

    mutating func unignore(_ path: String) {
        guard let canonical = Self.normalized([path]).first else { return }
        ignoredPaths.removeAll { $0 == canonical }
    }

    static func load(url: URL) throws -> CleanupPreferences {
        guard FileManager.default.fileExists(atPath: url.path) else { return CleanupPreferences() }
        return try JSONDecoder().decode(CleanupPreferences.self, from: Data(contentsOf: url))
    }

    func save(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}

enum ScanReportLoader {
    static func validate(report: ScanArchive, policy: SafetyPolicy, context: InspectionContext,
                         ignored: CleanupPreferences = CleanupPreferences()) -> [ScanItem] {
        guard [2, 3].contains(report.schemaVersion) else { return [] }
        let classifier = FileClassifier(policy: policy, context: context)
        var seen = Set<String>()
        return report.result.items.compactMap { item in
            guard item.url.isFileURL, item.root.isFileURL,
                  policy.permits(item.root), FileStamp.read(item.root)?.isDirectory == true,
                  !ignored.isIgnored(item.url), !seen.contains(item.url.standardizedFileURL.path) else { return nil }
            do { try policy.validate(item) } catch { return nil }
            seen.insert(item.url.standardizedFileURL.path)
            return ScanItem(url: item.url, root: item.root, stamp: item.stamp,
                            assessment: classifier.assess(item.url, stamp: item.stamp))
        }
    }
}

enum RestoreAvailability: String, Codable {
    case available, missing, changed, occupied, blocked, permission, disconnected, unverified

    var displayName: String {
        switch self {
        case .available: return "可恢复"
        case .missing: return "已不在废纸篓"
        case .changed: return "文件已变化"
        case .occupied: return "原位置已有文件"
        case .blocked: return "原位置不可用"
        case .permission: return "暂时无法读取废纸篓"
        case .disconnected: return "废纸篓所在磁盘未连接"
        case .unverified: return "暂时无法核实"
        }
    }

    static func check(record: TrashRecord, policy: SafetyPolicy) -> RestoreAvailability {
        guard record.original.isFileURL, record.trashed.isFileURL,
              ManagedLocations.inTrash(record.trashed, home: policy.home) else { return .blocked }
        if FileStamp.read(record.original) != nil { return .occupied }
        let current: FileStamp
        do { current = try FileStamp.readChecked(record.trashed) }
        catch {
            let parts = record.trashed.pathComponents
            if parts.count > 2, parts[1] == "Volumes",
               let mounted = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []),
               !mounted.contains(where: { $0.standardizedFileURL.path == "/Volumes/" + parts[2] }) {
                return .disconnected
            }
            switch Int32((error as NSError).code) {
            case EACCES, EPERM: return .permission
            case ENOENT where LocalFiles.noLinks(record.trashed.deletingLastPathComponent()): return .missing
            default: return .unverified
            }
        }
        if record.managedBundleID != nil {
            guard let id=record.managedBundleID,ManagedLocations.permits(record.original,id:id,home:policy.home),LocalFiles.noLinks(record.original.deletingLastPathComponent()),LocalFiles.noLinks(record.trashed),let expected=record.stamp,current==expected || (expected.isDirectory && current.sameContentIdentity(expected)) || (record.contentSHA256 != nil && current.sameContentIdentity(expected)) else{return .changed}
            return .available // Full recursive identity check is performed when restoring.
        }
        guard policy.permits(record.original), policy.hasNoSymlinkComponents(record.original.deletingLastPathComponent()),
              policy.hasNoSymlinkComponents(record.trashed) else { return .blocked }
        guard let expected = record.stamp, current.isRegular, current == expected || (record.contentSHA256 != nil && current.sameContentIdentity(expected)) else { return .changed }
        return .available
    }
}

extension ScanConfiguration {
    func isValid(policy: SafetyPolicy) -> Bool {
        !roots.isEmpty && roots.count <= 100 && minimumBytes >= 0 && (unusedDays.map { (1...3650).contains($0) } ?? true) && roots.allSatisfy { $0.isFileURL && policy.permits($0) }
    }
}
