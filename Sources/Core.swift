import Foundation
import AppKit
import Darwin

func formatBytes(_ bytes: Int64) -> String {
    if bytes <= 0 { return "0 KB" }
    return ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
}

struct FileStamp: Equatable, Codable {
    let device: Int32
    let inode: UInt64
    let size: Int64
    let allocated: Int64
    let modifiedSeconds: Int64
    let modifiedNanos: Int64
    let changedSeconds: Int64
    let changedNanos: Int64
    let links: UInt16
    let flags: UInt32
    let mode: UInt16
    var isRegular: Bool { mode & UInt16(S_IFMT) == UInt16(S_IFREG) }
    var isDirectory: Bool { mode & UInt16(S_IFMT) == UInt16(S_IFDIR) }
    var isSymlink: Bool { mode & UInt16(S_IFMT) == UInt16(S_IFLNK) }
    var isDataless: Bool { flags & 0x40000000 != 0 }
    static func read(_ url: URL) -> FileStamp? {
        try? readChecked(url)
    }
    static func readChecked(_ url: URL) throws -> FileStamp {
        var value = stat()
        let status = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return EINVAL }
            return lstat(path, &value) == 0 ? 0 : errno
        }
        guard status == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(status)) }
        return FileStamp(device: value.st_dev, inode: value.st_ino, size: value.st_size,
                         allocated: Int64(value.st_blocks) * 512,
                         modifiedSeconds: Int64(value.st_mtimespec.tv_sec), modifiedNanos: Int64(value.st_mtimespec.tv_nsec),
                         changedSeconds: Int64(value.st_ctimespec.tv_sec), changedNanos: Int64(value.st_ctimespec.tv_nsec),
                         links: value.st_nlink, flags: value.st_flags, mode: value.st_mode)
    }
}

struct ScanItem: Identifiable, Codable {
    var id: String { url.path }
    let url: URL
    let root: URL
    let stamp: FileStamp
    let assessment: FileAssessment
    var category: FileCategory { assessment.category }
    var bytes: Int64 { stamp.allocated }
    var modified: Date { Date(timeIntervalSince1970: Double(stamp.modifiedSeconds)) }
}

struct SafetyPolicy {
    let home: URL
    let extraProtected: [URL]
    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, extraProtected: [URL] = []) {
        self.home = home.standardizedFileURL
        self.extraProtected = extraProtected.map(\.standardizedFileURL)
    }
    static func within(_ url: URL, _ parent: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let root = parent.standardizedFileURL.path
        return path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
    }
    /// Rebuildable caches outside Library/Caches, each opened for a single rule.
    var knownCacheRoots: [URL] { KnownCacheLocations.roots(home: home) }
    var maintenanceRoots: [URL] {
        ["Library/Caches", "Library/Logs", "Library/Developer/Xcode/DerivedData"].map { home.appendingPathComponent($0) } + knownCacheRoots
    }
    func permits(_ url: URL) -> Bool {
        let url = url.standardizedFileURL
        guard Self.within(url, home) || url.path.hasPrefix("/Volumes/") else { return false }
        if extraProtected.contains(where: { Self.within(url, $0) }) { return false }
        let library = home.appendingPathComponent("Library")
        if Self.within(url, library) && !maintenanceRoots.contains(where: { Self.within(url, $0) }) { return false }
        let parts = url.pathComponents
        // Hidden components stay closed. Only the fixed components of an allowlisted cache root
        // (such as ".npm" in ".npm/_cacache") are exempt; anything hidden below that root is not.
        let opened = knownCacheRoots.first { Self.within(url, $0) }
        let checked = opened.map { root in Array(parts.prefix(home.pathComponents.count)) + Array(parts.dropFirst(root.pathComponents.count)) } ?? parts
        if checked.contains(where: { $0.hasPrefix(".") }) { return false }
        let protectedExtensions: Set<String> = ["app", "photoslibrary", "photolibrary", "musiclibrary", "fcpbundle", "band", "logicx", "lrdata", "lrcat", "lrcat-data", "sparsebundle", "bundle", "framework", "xcodeproj", "xcworkspace"]
        if parts.contains(where: { protectedExtensions.contains(($0 as NSString).pathExtension.lowercased()) }) { return false }
        let name = url.lastPathComponent.lowercased()
        if name.contains(".lrcat") || ["db", "sqlite", "sqlite3", "db-wal", "db-shm", "sqlite-wal", "sqlite-shm", "download", "crdownload", "part"].contains(url.pathExtension.lowercased()) { return false }
        return true
    }
    func hasNoSymlinkComponents(_ url: URL) -> Bool {
        var cursor = url.standardizedFileURL
        while cursor.path != "/" {
            guard let stamp = FileStamp.read(cursor), !stamp.isSymlink else { return false }
            cursor.deleteLastPathComponent()
        }
        return true
    }
    func validate(_ item: ScanItem) throws {
        guard item.url.path != item.root.path, Self.within(item.url, item.root), permits(item.url), hasNoSymlinkComponents(item.url) else {
            throw SweepError.unsafePath
        }
        guard let current = FileStamp.read(item.url), current.isRegular, current.links == 1, !current.isDataless else {
            throw SweepError.unavailable
        }
        guard current == item.stamp else { throw SweepError.changed }
        let values = try item.url.resourceValues(forKeys: [.isAliasFileKey, .isUbiquitousItemKey])
        guard values.isAliasFile != true, values.isUbiquitousItem != true else { throw SweepError.unsafePath }
    }
}

enum SweepError: LocalizedError {
    case unsafePath, unavailable, changed, rootDenied, protectedContent, unknownPurpose, appRunning
    var errorDescription: String? {
        switch self {
        case .protectedContent: return "此项需要手动选择，并完成二次确认后再清理。"
        case .unknownPurpose: return "用途尚未确认，请手动选择并完成二次确认。"
        case .appRunning: return "相关应用仍在运行或已重新打开，本项已跳过。"
        case .unsafePath: return "受保护的位置、链接或云端文件，已跳过。"
        case .unavailable: return "文件已不存在，或不再符合清理条件。"
        case .changed: return "文件在扫描后发生变化，请重新扫描。"
        case .rootDenied: return "请选择个人文件夹；系统、应用、隐藏目录和资料库不在清理范围。"
        }
    }
}

final class ScanCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
}

struct ScanProgress {
    var visited = 0
    var found = 0
    var bytes: Int64 = 0
    var current = ""
}

// Shared read failures are persisted by both cleanup scans and storage analysis.
enum StorageAccessKind: String, Codable { case permission, restricted, missing, disconnected, unavailable, incomplete
    var title: String { switch self { case .permission: return "需要访问权限"; case .restricted: return "系统访问限制"; case .missing: return "位置不存在"; case .disconnected: return "磁盘未连接"; case .unavailable: return "暂时无法读取"; case .incomplete: return "扫描未完成" } }
}
struct StorageAccessIssue: Identifiable, Codable {
    var id: String { url.path + "|" + kind.rawValue }
    let url: URL
    let root: URL
    let kind: StorageAccessKind
    let detail: String
    static func make(url: URL, root: URL, error: Error? = nil, detail: String = "", incomplete: Bool = false) -> StorageAccessIssue {
        let e = error as NSError?
        let statError: Int
        do { _ = try FileStamp.readChecked(url); statError = 0 }
        catch { statError = (error as NSError).code }
        let missing = statError != 0
        let volume = url.pathComponents.count > 2 && url.pathComponents[1] == "Volumes" ? URL(fileURLWithPath: "/Volumes/" + url.pathComponents[2]) : nil
        let kind: StorageAccessKind
        if incomplete { kind = .incomplete }
        else if let volume, FileStamp.read(volume) == nil { kind = .disconnected }
        else if [Int(EACCES), Int(EPERM)].contains(statError) { kind = .permission }
        else if e?.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(e!.code) || e?.domain == NSCocoaErrorDomain && e?.code == NSFileReadNoPermissionError { kind = .permission }
        else if missing { kind = .missing }
        else { kind = .unavailable }
        return StorageAccessIssue(url: url, root: root, kind: kind, detail: error?.localizedDescription ?? detail)
    }
}

struct ScanResult: Codable {
    var items: [ScanItem] = []
    var visited = 0
    var skipped = 0
    var issues: [String] = []
    var cancelled = false
    var limited = false
    var elapsed: TimeInterval = 0
    var accessIssues: [StorageAccessIssue]? = nil
    var isPartial: Bool { cancelled || limited || !issues.isEmpty }
}

struct DiskScanner {
    let policy: SafetyPolicy
    let minimumBytes: Int64
    // Explicit caps remain injectable for bounded fixtures; the user list has no item truncation.
    var limit = Int.max
    var excludedRoots: [URL] = []
    var includeSmallKnownCaches = false

    func isIgnored(_ url: URL) -> Bool {
        excludedRoots.contains { SafetyPolicy.within(url, $0) }
    }

    func assessFile(_ url: URL, root: URL, stamp: FileStamp, classifier: FileClassifier) -> ScanItem? {
        guard stamp.isRegular, stamp.links == 1 else { return nil }
        let maintenance = policy.maintenanceRoots.contains { SafetyPolicy.within(url, $0) }
        if maintenance && classifier.context.now.timeIntervalSince1970 - Double(stamp.modifiedSeconds) < 7 * 86_400 { return nil }
        let isSmall = stamp.allocated < minimumBytes
        if isSmall && (!includeSmallKnownCaches || !maintenance || stamp.allocated == 0) { return nil }
        let assessment = classifier.assess(url, stamp: stamp)
        if isSmall && (assessment.category != .cache || !assessment.canBatchSelect) { return nil }
        return ScanItem(url: url, root: root, stamp: stamp, assessment: assessment)
    }

    func inspectIndexedFile(_ url: URL, root: URL, classifier: FileClassifier) throws -> ScanItem? {
        guard policy.permits(root), policy.permits(url), SafetyPolicy.within(url, root), !isIgnored(url) else { return nil }
        let stamp = try FileStamp.readChecked(url)
        guard !stamp.isDataless, policy.hasNoSymlinkComponents(url) else { return nil }
        guard let item = assessFile(url, root: root, stamp: stamp, classifier: classifier) else { return nil }
        try policy.validate(item)
        let values = try url.resourceValues(forKeys: [.isPackageKey])
        if values.isPackage == true { return nil }
        return item
    }

    func scan(roots: [URL], cancellation: ScanCancellation, progress: @escaping (ScanProgress) -> Void) -> ScanResult {
        let started = Date()
        var result = ScanResult()
        let classifier = FileClassifier(policy: policy, context: InspectionContext.collect(home: policy.home))
        var ids = Set<String>()
        var readIssues: [String: StorageAccessIssue] = [:]
        func recordReadIssue(_ url: URL, root: URL, error: Error? = nil) {
            let issue = StorageAccessIssue.make(url: url, root: root, error: error)
            if readIssues.count < 100 || readIssues[issue.id] != nil { readIssues[issue.id] = issue }
        }
        var bytes: Int64 = 0
        var lastUpdate = Date.distantPast
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey, .isAliasFileKey, .isUbiquitousItemKey]
        var uniqueRoots: [URL] = []
        for root in roots.map(\.standardizedFileURL).sorted(by: { $0.path.count < $1.path.count }) {
            if !uniqueRoots.contains(where: { SafetyPolicy.within(root, $0) }) { uniqueRoots.append(root) }
        }
        for root in uniqueRoots {
            if cancellation.isCancelled || result.limited { break }
            progress(ScanProgress(visited: result.visited, found: result.items.count, bytes: bytes, current: "正在读取 \(root.path)；首次访问时，请处理 macOS 的授权提示。"))
            if excludedRoots.contains(where: { SafetyPolicy.within(root, $0) }) { continue }
            guard policy.permits(root), policy.hasNoSymlinkComponents(root), FileStamp.read(root)?.isDirectory == true else {
                result.issues.append("无法扫描：\(root.path)（不存在、未获权限或受保护）")
                if policy.permits(root) { recordReadIssue(root, root: root) }
                continue
            }
            guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants, .skipsHiddenFiles], errorHandler: { url, error in
                result.skipped += 1
                if result.issues.count < 100 { result.issues.append("\(url.path)：\(error.localizedDescription)") }
                recordReadIssue(url, root: root, error: error)
                return !cancellation.isCancelled
            }) else { result.issues.append("无法读取：\(root.path)"); recordReadIssue(root, root: root); continue }
            while let url = autoreleasepool(invoking: { enumerator.nextObject() as? URL }) {
                if cancellation.isCancelled { break }
                result.visited += 1
                if enumerator.level > 64 { enumerator.skipDescendants(); result.skipped += 1; if result.issues.count < 100 { result.issues.append("目录超过安全深度：" + url.path) }; continue }
                autoreleasepool {
                    guard let stamp = FileStamp.read(url) else { result.skipped += 1; return }
                    guard policy.permits(url), !excludedRoots.contains(where: { SafetyPolicy.within(url, $0) }) else {
                        if stamp.isDirectory { enumerator.skipDescendants() }
                        result.skipped += 1; return
                    }
                    guard let values = try? url.resourceValues(forKeys: Set(keys)) else { result.skipped += 1; return }
                    if stamp.isSymlink || stamp.isDataless || values.isPackage == true || values.isAliasFile == true || values.isUbiquitousItem == true {
                        if stamp.isDirectory { enumerator.skipDescendants() }
                        result.skipped += 1; return
                    }
                    guard let item = assessFile(url, root: root, stamp: stamp, classifier: classifier) else { return }
                    guard ids.insert(url.path).inserted else { return }
                    result.items.append(item)
                    bytes += stamp.allocated
                }
                if Date().timeIntervalSince(lastUpdate) > 0.18 {
                    lastUpdate = Date()
                    progress(ScanProgress(visited: result.visited, found: result.items.count, bytes: bytes, current: url.deletingLastPathComponent().path))
                }
                if result.items.count >= limit { result.limited = true; break }
            }
        }
        result.accessIssues = readIssues.values.sorted { $0.url.path < $1.url.path }
        result.cancelled = cancellation.isCancelled
        result.elapsed = Date().timeIntervalSince(started)
        result.items.sort { $0.bytes == $1.bytes ? $0.id < $1.id : $0.bytes > $1.bytes }
        progress(ScanProgress(visited: result.visited, found: result.items.count, bytes: bytes, current: ""))
        return result
    }
}

struct TrashRecord: Identifiable, Codable {
    let id: UUID
    let original: URL
    let trashed: URL
    let bytes: Int64
    let date: Date
    let stamp: FileStamp?
    var batchID: UUID? = nil
    var managedBundleID: String? = nil
    var treeDigest: String? = nil
    var contentSHA256:String? = nil
}

struct CleanupReceipt: Identifiable, Codable {
    let id: UUID
    let date: Date
    let title: String
    let requestedCount: Int
    let movedCount: Int
    let movedBytes: Int64
    let freeBefore: Int64
    let freeAfter: Int64
    let errors: [String]
    let cancelled: Bool
    var retryFiles:[CleanupRetryTarget]?=nil
    var retryManaged:[ManagedRetryTarget]?=nil
    var retryOf:UUID?=nil
    var interrupted:Bool?=nil
    var retryCount:Int{(retryFiles?.count ?? 0)+(retryManaged?.count ?? 0)}
    var observedFreeChange: Int64 { freeAfter - freeBefore }
}
struct CleanupHistoryBatch: Identifiable {
    let id: String
    let date: Date
    let title: String
    let records: [TrashRecord]
    let receipt: CleanupReceipt?
}

struct TrashResult {
    var records: [TrashRecord] = []
    var errors: [String] = []
}

/// A one-review grant tied to file identities, never a global protection bypass.
struct ManualCleanupConsent {
    private let reviewStamps: [String: FileStamp]
    private let individualStamps: [String: FileStamp]
    init(reviewedItems: [ScanItem]) {
        reviewStamps = reviewedItems.reduce(into: [:]) { $0[$1.id] = $1.stamp }
        individualStamps = reviewedItems.filter { $0.assessment.requiresIndividualConfirmation }
            .reduce(into: [:]) { $0[$1.id] = $1.stamp }
    }
    func matches(_ items: [ScanItem]) -> Bool {
        reviewStamps == items.reduce(into: [:]) { $0[$1.id] = $1.stamp }
    }
    func permits(_ item: ScanItem) -> Bool { individualStamps[item.id] == item.stamp }
}

struct TrashService {
    let policy: SafetyPolicy
    func move(_ items: [ScanItem], manualConsent: ManualCleanupConsent? = nil, cancellation:ScanCancellation?=nil, journal: CleanupJournalContext? = nil, beforeMove: (ScanItem) throws -> Void = { _ in }, progress: @escaping (Int) -> Void = { _ in }) -> TrashResult {
        var result = TrashResult()
        let classifier = FileClassifier(policy: policy, context: InspectionContext.collect(home: policy.home))
        for (index, item) in items.enumerated() {
            if cancellation?.isCancelled == true || journal?.journal.isBlocked == true { break }
            var unfinishedIntent = false
            autoreleasepool {
                do {
                    try policy.validate(item)
                    let assessment = classifier.assess(item.url, stamp: item.stamp)
                    if assessment.requiresIndividualConfirmation || item.assessment.requiresIndividualConfirmation {
                        guard manualConsent?.permits(item) == true else { throw SweepError.protectedContent }
                    }
                    try beforeMove(item)
                    guard assessment.blockingAppIDs.allSatisfy({ NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }) else { throw SweepError.appRunning }
                    let checksum=try LocalFiles.digest(item.url,expected:item.stamp,cancellation:cancellation ?? ScanCancellation())
                    if cancellation?.isCancelled==true{throw ToolFailure.cancelled}
                    try policy.validate(item); try beforeMove(item)
                    let intent = try journal.map { try $0.journal.prepareMove(original: item.url, stamp: item.stamp, bytes: item.bytes, context: $0, checksum: checksum) }
                    unfinishedIntent = intent != nil
                    do { try policy.validate(item);try beforeMove(item);if cancellation?.isCancelled==true{throw ToolFailure.cancelled} }
                    catch {if let journal,let intent{try journal.journal.didNotMove(intent);unfinishedIntent=false};throw error}
                    var destination: NSURL?
                    try FileManager.default.trashItem(at: item.url, resultingItemURL: &destination)
                    if let journal, let intent { try journal.journal.hit(.moveApplied, id: intent.id) }
                    guard let actual = destination as URL? else {
                        result.errors.append("\(item.url.lastPathComponent)：已调用系统移入废纸篓，但未返回位置；请在访达中检查。")
                        return
                    }
                    var record=TrashRecord(id: intent?.id ?? UUID(), original: item.url, trashed: actual, bytes: item.bytes, date: intent?.date ?? Date(), stamp: FileStamp.read(actual))
                    record.batchID=journal?.batchID;record.contentSHA256=checksum;result.records.append(record)
                    if let journal, let intent { try journal.journal.didMove(intent, record: record) }
                    unfinishedIntent = false
                } catch { result.errors.append("\(item.url.lastPathComponent)：\(error.localizedDescription)") }
            }
            progress(index + 1)
            if unfinishedIntent { break }
        }
        return result
    }
    func restore(_ record: TrashRecord, journal: CleanupOperationJournal? = nil) throws {
        if record.managedBundleID != nil {
            try ManagedLocations.validateRestore(record,home:policy.home)
            let intent = try journal?.prepareRestore(record)
            try FileManager.default.moveItem(at:record.trashed,to:record.original)
            if let journal, let intent { try journal.hit(.restoreApplied, id: intent.id); try journal.didRestore(intent) }
            return
        }
        let manager = FileManager.default
        guard policy.permits(record.original), policy.hasNoSymlinkComponents(record.original.deletingLastPathComponent()),
              !manager.fileExists(atPath: record.original.path), FileStamp.read(record.original) == nil, let originalStamp = record.stamp,
              let current = FileStamp.read(record.trashed), current.isRegular, policy.hasNoSymlinkComponents(record.trashed),
              current == originalStamp || (record.contentSHA256 != nil && current.sameContentIdentity(originalStamp)),
              record.trashed.pathComponents.contains(".Trash") || record.trashed.pathComponents.contains(".Trashes") else {
            throw SweepError.changed
        }
        if current != originalStamp{guard let proof=record.contentSHA256,try LocalFiles.digest(record.trashed,expected:current)==proof else{throw SweepError.changed}}
        let intent = try journal?.prepareRestore(record)
        try manager.moveItem(at: record.trashed, to: record.original)
        if let journal, let intent { try journal.hit(.restoreApplied, id: intent.id); try journal.didRestore(intent) }
    }
}

struct MemoryProcess: Identifiable {
    var id: String { name }
    let name: String
    let bytes: Int64
    let count: Int
}

struct SystemSnapshot {
    var diskTotal: Int64 = 0
    var diskFree: Int64 = 0
    var memoryTotal: Int64 = 0
    var memoryUsed: Int64 = 0
    var compressed: Int64 = 0
    var swap: Int64 = 0
    var pressure: Int32 = 0
    var processes: [MemoryProcess] = []
    var timestamp = Date()
    var pressureLabel: String {
        switch pressure { case 1: return "正常"; case 2: return "偏高"; case 4: return "紧张"; default: return "未知" }
    }
    static func sample() -> SystemSnapshot {
        var snapshot = SystemSnapshot()
        var disk = statfs()
        if statfs(FileManager.default.homeDirectoryForCurrentUser.path, &disk) == 0 {
            snapshot.diskTotal = Int64(disk.f_blocks) * Int64(disk.f_bsize)
            snapshot.diskFree = Int64(disk.f_bavail) * Int64(disk.f_bsize)
        }
        snapshot.memoryTotal = Int64(ProcessInfo.processInfo.physicalMemory)
        var vm = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let host = mach_host_self()
        let status = withUnsafeMutablePointer(to: &vm) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
        }
        mach_port_deallocate(mach_task_self_, host)
        if status == KERN_SUCCESS {
            let page = Int64(vm_kernel_page_size)
            snapshot.compressed = Int64(vm.compressor_page_count) * page
            snapshot.memoryUsed = min(snapshot.memoryTotal, max(0, Int64(vm.internal_page_count) + Int64(vm.wire_count) + Int64(vm.compressor_page_count) - Int64(vm.purgeable_count)) * page)
        }
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.stride
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 { snapshot.swap = Int64(swap.xsu_used) }
        var level: Int32 = 0
        var levelSize = MemoryLayout<Int32>.stride
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0) == 0 { snapshot.pressure = level }
        snapshot.processes = sampleProcesses()
        snapshot.timestamp = Date()
        return snapshot
    }
    private static func sampleProcesses() -> [MemoryProcess] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axo", "rss=,comm="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0, let content = String(data: data, encoding: .utf8) else { return [] }
        var groups: [String: (Int64, Int)] = [:]
        for line in content.split(separator: "\n") {
            let parts = line.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            guard parts.count == 2, let kb = Int64(parts[0]), kb > 0 else { continue }
            let path = String(parts[1]).trimmingCharacters(in: .whitespaces)
            let name: String
            if let range = path.range(of: ".app/") {
                name = URL(fileURLWithPath: String(path[..<range.lowerBound])).lastPathComponent
            } else { name = URL(fileURLWithPath: path).lastPathComponent }
            let old = groups[name] ?? (0, 0)
            groups[name] = (old.0 + kb * 1024, old.1 + 1)
        }
        return groups.map { MemoryProcess(name: $0.key, bytes: $0.value.0, count: $0.value.1) }.sorted { $0.bytes > $1.bytes }.prefix(12).map { $0 }
    }
}
