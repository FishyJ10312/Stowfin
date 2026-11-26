import Foundation

struct OperationProgress: Codable, Equatable {
  var phase: String
  var current: String = ""
  var completedBytes: Int64 = 0
  var totalBytes: Int64? = nil
  var completedItems: Int = 0
  var totalItems: Int? = nil
  var fraction: Double? {
    guard let total = totalBytes, total > 0 else { return nil }
    return min(1, max(0, Double(completedBytes) / Double(total)))
  }
  var amount: String {
    if let total = totalBytes { return formatBytes(completedBytes) + " / " + formatBytes(total) }
    if let total = totalItems { return "\(completedItems) / \(total) 项" }
    return completedItems > 0 ? "已检查 \(completedItems) 项" : ""
  }
}
func boundedBytes(_ a: Int64, _ b: Int64) -> Int64 {
  let (sum, overflow) = max(0, a).addingReportingOverflow(max(0, b))
  return overflow ? Int64.max : sum
}
func formatElapsed(_ seconds: TimeInterval) -> String {
  guard seconds.isFinite else { return "—" }
  let value = Int(max(0, min(seconds, 365 * 86400)))
  return value >= 3600
    ? "\(value/3600) 时 \(value%3600/60) 分"
    : value >= 60 ? "\(value/60) 分 \(value%60) 秒" : "\(value) 秒"
}

struct CleanupImpact: Identifiable {
  let id: String
  let title: String
  let consequence: String
  let count: Int
  let bytes: Int64
  static func build(_ items: [ScanItem]) -> [CleanupImpact] {
    Dictionary(grouping: items, by: { key($0) }).map { key, files in
      let copy = description(key)
      return CleanupImpact(
        id: key, title: copy.0, consequence: copy.1, count: files.count,
        bytes: files.reduce(0) { $0 + $1.bytes })
    }.sorted { $0.bytes == $1.bytes ? $0.id < $1.id : $0.bytes > $1.bytes }
  }
  private static func key(_ item: ScanItem) -> String {
    if item.assessment.ruleID == "archive-verified-source" { return "archived" }
    if item.url.pathComponents.contains("ProxyMedia") { return "proxy" }
    if item.url.pathComponents.contains("CacheClip")
      || item.url.pathComponents.contains("OptimizedMedia")
    {
      return "render"
    }
    if [.video, .photo, .audio].contains(item.category) { return "media" }
    return item.category.rawValue
  }
  private static func description(_ key: String) -> (String, String) {
    switch key {
    case "archived": return ("已归档来源", "清理后将依赖归档副本；操作前再次检查副本。")
    case "proxy": return ("达芬奇代理", "清理后需要使用原片，或重新生成代理。")
    case "render": return ("达芬奇缓存", "相关项目可能需要重新渲染或生成优化媒体。")
    case FileCategory.installer.rawValue: return ("安装包", "删除本地安装介质；以后重装或回退需重新获取。")
    case FileCategory.cache.rawValue: return ("可重建缓存", "下次使用可能重新下载或生成，首次打开会变慢。")
    case FileCategory.log.rawValue: return ("日志与诊断", "将失去这些诊断记录，可能影响之后排查问题。")
    case FileCategory.project.rawValue: return ("项目与源代码", "会移除项目文件；请核对备份和其他文件的引用。")
    case "media":
      return ("素材", "可能导致剪辑或图库中的引用离线；请确认备份。")
    case FileCategory.preset.rawValue: return ("预设与素材包", "可能影响正在使用的字体、预设、模板或素材。")
    case FileCategory.runtime.rawValue: return ("工具资源", "可能影响工具运行；请先核对用途。")
    default: return ("其他文件", "用途尚未完全确认，请核对内容和引用后再处理。")
    }
  }
}
struct CleanupRetryTarget: Codable, Identifiable {
  var id: String { url.path }
  let url: URL
  let root: URL
  let previousStamp: FileStamp
  let manualRequired: Bool
  let retainedCopy: RetainedCopy?
  let blockingAppIDs: [String]?
  let requiresClosedApps: Bool?
  init(item: ScanItem, retainedCopy: RetainedCopy? = nil) {
    url = item.url
    root = item.root
    previousStamp = item.stamp
    manualRequired = item.assessment.requiresIndividualConfirmation
    self.retainedCopy = retainedCopy
    blockingAppIDs = item.assessment.blockingAppIDs
    requiresClosedApps = item.assessment.needsClosedApps
  }
  func recheck(
    policy: SafetyPolicy, classifier: FileClassifier,
    cancellation: ScanCancellation = ScanCancellation()
  ) throws -> ScanItem {
    if cancellation.isCancelled { throw ToolFailure.cancelled }
    guard let stamp = FileStamp.read(url) else { throw ToolFailure.unreadable(url.path) }
    let base = classifier.assess(url, stamp: stamp)
    var assessment =
      manualRequired && !base.requiresIndividualConfirmation
      ? FileAssessment(
        category: base.category, disposition: .protected, owner: base.owner, group: base.group,
        reason: base.reason, evidence: base.evidence, ruleID: base.ruleID,
        blockingAppIDs: base.blockingAppIDs, needsClosedApps: base.needsClosedApps) : base
    assessment.blockingAppIDs = Array(Set(assessment.blockingAppIDs + (blockingAppIDs ?? [])))
      .sorted()
    assessment.needsClosedApps = assessment.needsClosedApps || requiresClosedApps == true
    let item = ScanItem(url: url, root: root, stamp: stamp, assessment: assessment)
    try policy.validate(item)
    if let retainedCopy {
      try retainedCopy.validate()
      guard stamp.size == retainedCopy.stamp.size,
        try LocalFiles.digest(url, expected: stamp, cancellation: cancellation)
          == LocalFiles.digest(
            retainedCopy.url, expected: retainedCopy.stamp, cancellation: cancellation)
      else { throw ToolFailure.invalid("来源与保留副本内容不一致，本项未清理") }
      // Bind the new proof to both identities until cleanup revalidates their stamps.
      try policy.validate(item)
      try retainedCopy.validate()
    }
    if cancellation.isCancelled { throw ToolFailure.cancelled }
    return item
  }
}
struct ManagedRetryTarget: Codable, Identifiable {
  var id: String { url.path }
  let url: URL
  let bundleID: String
  let title: String
  let role: String
  init(_ item: ManagedItem) {
    url = item.url
    bundleID = item.bundleID
    title = item.title
    role = item.role
  }
  func recheck(home: URL, cancellation: ScanCancellation) throws -> ManagedItem {
    guard ManagedLocations.permits(url, id: bundleID, home: home) else { throw ToolFailure.changed }
    let tree = try FileTree.read(url, cancellation: cancellation)
    if url.pathExtension.lowercased() == "app" {
      let data = try Data(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
      let info =
        try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
      guard info?["CFBundleIdentifier"] as? String == bundleID else { throw ToolFailure.changed }
    }
    return ManagedItem(url: url, bundleID: bundleID, title: title, role: role, tree: tree)
  }
}
struct OperationOutcome: Identifiable {
  let id = UUID()
  let title: String
  let completed: Int
  let bytes: Int64
  let errors: [String]
  var receipt: CleanupReceipt? = nil
  var restoreRemaining: [TrashRecord] = []
  var saveFailure: String? = nil
  var trashUsage: TrashUsage? = nil
  var trashMeasured = false
}

enum ToolTaskKind: String, Codable {
  case media = "媒体扫描"
  case duplicates = "重复文件检查"
  case archive = "归档"
  case verifyArchive = "归档来源检查"
  case applications = "应用读取"
  case application = "应用内容检查"
  case leftovers = "残留检查"
  case startups = "启动项读取"
  case startupChange = "启动项更改"
  case mediaDetails = "媒体参数"
}
enum ToolTaskStatus: String, Codable {
  case running = "进行中"
  case completed = "已完成"
  case partial = "部分完成"
  case cancelled = "已停止"
  case failed = "未完成"
  case interrupted = "已中断"
}
struct ToolTaskPlan: Codable {
  let kind: ToolTaskKind
  var roots: [URL] = []
  var destination: URL? = nil
  var application: InstalledApplication? = nil
  var archiveID: UUID? = nil
  var canRepeat: Bool {
    [
      .media, .duplicates, .archive, .verifyArchive, .applications, .application, .leftovers,
      .startups,
    ].contains(kind)
  }
}
struct ToolTaskRecord: Codable, Identifiable {
  let id: UUID
  let started: Date
  var ended: Date?
  let plan: ToolTaskPlan
  var status: ToolTaskStatus
  var progress: OperationProgress
  var resultCount = 0
  var issueCount = 0
  var details: [String] = []
  var duration: TimeInterval {
    status == .interrupted ? 0 : max(0, (ended ?? Date()).timeIntervalSince(started))
  }
}
enum ToolTaskStore {
  static func load(_ url: URL) throws -> [ToolTaskRecord] {
    guard FileStamp.read(url) != nil else { return [] }
    guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 20_000_000,
      LocalFiles.noLinks(url)
    else { throw ToolFailure.invalid("任务记录无法读取") }
    var records = try JSONDecoder().decode([ToolTaskRecord].self, from: Data(contentsOf: url))
    for index in records.indices where records[index].status == .running {
      records[index].status = .interrupted
      records[index].ended = nil
    }
    return Array(records.prefix(50))
  }
  static func save(_ records: [ToolTaskRecord], to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(Array(records.prefix(50))).write(to: url, options: .atomic)
  }
}

final class OperationProgressRelay: @unchecked Sendable {
  private let lock = NSLock()
  private var last = Date.distantPast
  private var phase = ""
  private let emit: (OperationProgress) -> Void
  init(_ emit: @escaping (OperationProgress) -> Void) { self.emit = emit }
  func send(_ value: OperationProgress) {
    lock.lock()
    let now = Date()
    let changed = phase != value.phase
    guard changed || now.timeIntervalSince(last) > 0.12 || value.fraction == 1 else {
      lock.unlock()
      return
    }
    phase = value.phase
    last = now
    lock.unlock()
    emit(value)
  }
}
