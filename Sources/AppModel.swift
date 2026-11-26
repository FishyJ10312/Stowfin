import SwiftUI
import AppKit
import Combine

enum AppSection: String, CaseIterable {
    case overview = "我的 Mac", results = "清理", storage = "空间分析", memory = "内存", history = "清理记录", tools = "工具"
    var icon: String {
        switch self { case .overview: return "square.grid.2x2"; case .results: return "tray.full"; case .storage: return "chart.bar.xaxis"; case .memory: return "memorychip"; case .history: return "clock.arrow.circlepath"; case .tools:return "square.grid.3x3" }
    }
}
enum ResultPresentation: String, CaseIterable { case groups = "按用途", files = "全部文件" }
enum FileOrdering: String, CaseIterable { case size = "占用最大", oldest = "最早修改", leastUsed = "最久未用", name = "文件名称" }

@MainActor final class AppModel: ObservableObject {
    @Published var section: AppSection = .overview
    @Published var historyOnlyRecoverable = false
    @Published var snapshot = SystemSnapshot()
    @Published var scanning = false
    @Published var analyzing = false
    @Published var mutating = false
    @Published var sampling = false
    @Published var loadingReport = false
    @Published var loadingStorageIndex = false
    @Published var progress = ScanProgress()
    @Published var storageProgress = StorageAuditProgress()
    @Published var storageResult: StorageAuditResult?
    @Published var storageSearch = "" { didSet { scheduleStorageQuery() } }
    @Published var storageShowsMap=false
    @Published var storageMode: StoragePresentation = .applications
    @Published var appSummaries: [AppStorageSummary] = []
    @Published var storageItems: [IndexedStorageItem] = []
    @Published var storageItemDetail: IndexedStorageItem?
    @Published var storageCountedBytes: Int64 = 0
    @Published var storageInfo: StorageIndexInfo?
    @Published var storageScanScope: StorageScanScope = .selectedFolders
    @Published var storagePendingRoots: [StorageRoot] = []
    @Published var storageVolumes: [StorageVolumeUsage] = []
    @Published var storageAutoContinue = false
    @Published var storageUpdateStatus = ""
    @Published var cleanupDisplayLimit = 100
    @Published var previewURL: URL?
    @Published var storageAccessStatus = ""
    @Published var storageAccessIssues: [StorageAccessIssue] = []
    @Published var storageFolder: URL?
    @Published var storageOwnerFilter: String?
    @Published var storageOwnerTitle: String?
    @Published var storageOrdering: FileOrdering = .size { didSet { scheduleStorageQuery() } }
    @Published var storageTotalMatches = 0
    @Published var queryingStorage = false
    @Published var storageIndexUnavailable = false
    @Published var cleanupOwnerFilter: String?
    @Published var cleanupOwnerTitle: String?
    @Published var showingScanChooser = false
    @Published var currentScanConfiguration: ScanConfiguration?
    @Published var storageCleanup: StorageCleanup? { didSet { itemsRevision += 1 } }
    @Published var stoppedCleanupScan: StoppedCleanupScan?
    @Published var addingIndexedFile = false
    @Published var accessCheckRunning = false
    @Published var expandedAccessGroups = Set<String>()
    var storageQueue = DispatchQueue(label: "local.qingsweep.storage", qos: .utility)
    var storageQueryGeneration = 0
    var storageDebounce: DispatchWorkItem?
    var storageIndexURL: URL!
    var storageApplications: [InstalledApplication] = []
    var cleanupIndexRefreshPaths: [URL] = []
    var ownerResolver = StorageOwnerResolver(applications: [])
    var shouldRecheckAccessOnActivation = false
    private var shouldRecheckCleanupOnActivation = false
    private var shouldRecheckCleanupScanOnActivation = false
    var accessObserver: NSObjectProtocol?

    @Published var expandedStorage = Set<String>()
    @Published var storageDetail: StorageEntry?
    @Published var result: ScanResult?
    @Published var items: [ScanItem] = [] { didSet { itemsRevision += 1 } }
    @Published var selected = Set<String>() {
        didSet {
            selectionRevision += 1
            manuallySelectedStamps = manuallySelectedStamps.filter { selected.contains($0.key) }
            additionalSelections = additionalSelections.filter { selected.contains($0.key) }
            retainedCopies = retainedCopies.filter { selected.contains($0.key) }
        }
    }
    private var additionalSelections: [String: ScanItem] = [:]
    var retainedCopies:[String:RetainedCopy]=[:]
    private var manuallySelectedStamps: [String: FileStamp] = [:]
    @Published var search = "" { didSet { cleanupDisplayLimit = 100 } }
    @Published var category: FileCategory? { didSet { cleanupDisplayLimit = 100 } }
    @Published var disposition: CleanupDisposition? { didSet { cleanupDisplayLimit = 100 } }
    @Published var groupFilter: String? { didSet { cleanupDisplayLimit = 100 } }
    @Published var cleanupScope: CleanupScope? = .recommended
    @Published var cleanupTrail: [CleanupLocation] = []
    @Published var storageTrail: [StorageLocation] = []
    @Published var reviewScopeTitle = "全部已选文件"
    @Published var reviewNotice:String?
    @Published var operationOutcome:OperationOutcome?
    @Published var trashUsage: TrashUsage?
    private var reviewRetryParent:UUID?
    var managedRetryParent:UUID?
    @Published var presentation: ResultPresentation = .groups
    @Published var ordering: FileOrdering = .size { didSet { cleanupDisplayLimit = 100 } }
    @Published var onlySelected = false { didSet { cleanupDisplayLimit = 100 } }
    @Published var inspecting: ScanItem?
    @Published var scannedAt: Date?
    @Published var minimumFilter: Int64 = 0
    /// Days without modification, opening or being added; 0 shows every file.
    @Published var unusedFilter: Int = 0 { didSet { cleanupDisplayLimit = 100 } }
    @Published var reviewDisplayLimit = 100
    @Published var review: [ScanItem] = [] { didSet { reviewDisplayLimit = 100; resetManualConfirmation() } }
    @Published var showingReview = false { didSet { if !showingReview { resetManualConfirmation();reviewRetryParent=nil;reviewNotice=nil } } }
    @Published var reviewConfirmed = false
    @Published var canCancelCleanup = false
    private var cleanupCancellation: ScanCancellation?
    var cleanupEnvironment: CleanupApplicationEnvironment?
    @Published var showingManualConfirmation = false
    @Published var manualReviewAcknowledged = false
    private var manualCleanupConsent: ManualCleanupConsent?
    @Published var showingIssues = false
    @Published var showingIgnored = false
    @Published var showingMemoryDetails = false
    @Published var showingStorageIssues = false
    @Published var message: String?
    @Published var history: [TrashRecord] = []
    @Published var cleanupReceipts: [CleanupReceipt] = []
    @Published var reconcilingCleanup = false
    @Published var cleanupJournalFailure: String?
    @Published var cleanupJournalIssues: [String] = []
    private var cleanupJournal: CleanupOperationJournal?
    @Published var restoreStates: [UUID: RestoreAvailability] = [:]
    @Published var preferences = CleanupPreferences() { didSet { itemsRevision += 1 } }
    @Published var scanLabel = "尚未扫描"
    @Published var operationProgress = ""
    private var cancellation: ScanCancellation?
    var auditCancellation: ScanCancellation?
    private var timer: Timer?
    private var lastRoots: [URL] = []
    private var lastMinimum: Int64 = 1_000_000
    let workbench:WorkbenchModel
    private var workbenchObservation:AnyCancellable?
    private let home: URL
    let policy: SafetyPolicy
    private let receiptsURL: URL
    private let historyURL: URL
    private let preferencesURL: URL
    private let catalogURL: URL
    private let reportURL: URL
    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, loadSavedScan: Bool = true, startTimer: Bool = true, cleanupJournalCheckpoint: ((CleanupJournalCheckpoint,UUID) throws -> Void)? = nil) {
        self.home = home
        workbench=WorkbenchModel(home:home)
        policy = SafetyPolicy(home: home, extraProtected: [Bundle.main.bundleURL])
        let support = home.appendingPathComponent("Library/Application Support/QingSweep")
        historyURL = support.appendingPathComponent("history.json")
        receiptsURL = support.appendingPathComponent("cleanup-receipts.json")
        preferencesURL = support.appendingPathComponent("preferences.json")
        reportURL = support.appendingPathComponent("last-scan.json")
        catalogURL = support.appendingPathComponent("cleanup-catalog.sqlite")
        storageIndexURL = support.appendingPathComponent("storage-index.sqlite")
        if let data = try? Data(contentsOf: historyURL), let records = try? JSONDecoder().decode([TrashRecord].self, from: data) { history = records }
        if let data = try? Data(contentsOf: receiptsURL), let receipts = try? JSONDecoder().decode([CleanupReceipt].self, from: data) { cleanupReceipts = receipts }
        var needsJournalCheck = false
        do {
            let journal = try CleanupOperationJournal(url: support.appendingPathComponent("cleanup-operations.sqlite"),checkpoint:cleanupJournalCheckpoint)
            cleanupJournal = journal
            let state = try journal.snapshot()
            state.merge(history: &history, receipts: &cleanupReceipts)
            cleanupIndexRefreshPaths=state.entries.map(\.original)
            cleanupJournalIssues = state.issues; needsJournalCheck = state.needsReconciliation
        } catch { cleanupJournalFailure = error.localizedDescription }
        do { preferences = try CleanupPreferences.load(url: preferencesURL) }
        catch { message = "忽略列表无法读取，请在设置中重新检查" }
        workbenchObservation=workbench.objectWillChange.sink{[weak self] _ in self?.objectWillChange.send()}
        if loadSavedScan { loadLastScan(); loadStorageIndex() }
        accessObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                if let self, self.shouldRecheckAccessOnActivation { self.recheckStorageAccess() }
                if let self,self.shouldRecheckCleanupOnActivation {self.shouldRecheckCleanupOnActivation=false;self.reconcileCleanupOperations()}
                if let self,self.shouldRecheckCleanupScanOnActivation,!self.busy {self.shouldRecheckCleanupScanOnActivation=false;self.recheckCleanupScanAccess()}
            }
        }
        refresh()
        if startTimer { timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } } }
        if needsJournalCheck { reconcileCleanupOperations() }
        if startTimer { measureTrash(records: history) }
    }
    var busy: Bool { scanning || analyzing || mutating || reconcilingCleanup || loadingReport || loadingStorageIndex || showingReview || addingIndexedFile || workbench.busy }
    var totalBytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
    func isIndividuallySelected(_ item: ScanItem) -> Bool { selected.contains(item.id) && manuallySelectedStamps[item.id] == item.stamp }
    func isSelectedForReview(_ item: ScanItem) -> Bool {
        selected.contains(item.id) && (additionalSelections[item.id].map { $0.stamp == item.stamp } ?? true) &&
            (item.assessment.canBatchSelect || isIndividuallySelected(item)) && !preferences.isIgnored(item.url)
    }
    var selectedItems: [ScanItem] {
        let fromReport = items.filter { additionalSelections[$0.id] == nil && isSelectedForReview($0) }
        return fromReport + additionalSelections.values.filter(isSelectedForReview).sorted { $0.id < $1.id }
    }
    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.bytes } }
    var priorityBytes: Int64 { items.filter { $0.assessment.canBatchSelect && $0.assessment.disposition == .priority && !preferences.isIgnored($0.url) }.reduce(0) { $0 + $1.bytes } }
    var recoverable: [TrashRecord] { history.filter { restoreStates[$0.id] == .available } }
    private var itemsRevision = 0
    private var selectionRevision = 0
    private var filteredCache: (key: String, values: [ScanItem])?
    private var groupsCache: (key: String, values: [AssessmentGroup])?
    private var activityCache: [String: (stamp: FileStamp, date: Date)] = [:]
    private var filterKey: String { [InterfaceLanguage.current.rawValue,String(itemsRevision),String(onlySelected ? selectionRevision : 0),search,cleanupScope?.rawValue ?? "",cleanupOwnerFilter ?? "",category?.rawValue ?? "",disposition?.rawValue ?? "",groupFilter ?? "",String(minimumFilter),String(unusedFilter),String(onlySelected),ordering.rawValue].joined(separator: "\0") }
    var filtered: [ScanItem] {
        let key = filterKey
        if let cache = filteredCache, cache.key == key { return cache.values }
        let values = cleanupItems.filter { item in
            !preferences.isIgnored(item.url) && (cleanupScope == nil || cleanupScope!.contains(item)) &&
            matchesCleanupOwner(item) &&
            (category == nil || item.category == category) && item.bytes >= minimumFilter &&
            (disposition == nil || item.assessment.disposition == disposition) &&
            (groupFilter == nil || item.assessment.groupID == groupFilter) &&
            (!onlySelected || isSelectedForReview(item)) &&
            (search.isEmpty || (item.url.path + " " + item.assessment.owner + " " + item.category.rawValue + " " + L(item.assessment.owner) + " " + L(item.category.rawValue)).localizedCaseInsensitiveContains(search)) &&
            (unusedFilter == 0 || lastActivity(item) < unusedCutoff)
        }
        let sorted = values.sorted { a, b in
            switch ordering {
            case .size: return a.bytes == b.bytes ? a.id < b.id : a.bytes > b.bytes
            case .oldest: return a.modified == b.modified ? a.id < b.id : a.modified < b.modified
            case .leastUsed:
                let left = lastActivity(a), right = lastActivity(b)
                return left == right ? a.id < b.id : left < right
            case .name: return a.url.lastPathComponent == b.url.lastPathComponent ? a.id < b.id : a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent) == .orderedAscending
            }
        }
        filteredCache = (key,sorted)
        return sorted
    }
    private var unusedCutoff: Date { Date().addingTimeInterval(-Double(unusedFilter) * 86_400) }
    /// Latest of modification, last-opened and date-added; Spotlight is consulted for files of 10 MB or more.
    func lastActivity(_ item: ScanItem) -> Date {
        if let cached = activityCache[item.id], cached.stamp == item.stamp { return cached.date }
        let date = FileActivity.lastActivity(item.url, modified: item.modified, useSpotlight: item.bytes >= 10_000_000)
        activityCache[item.id] = (item.stamp, date)
        return date
    }
    var displayedCleanupFiles: [ScanItem] { Array(filtered.prefix(cleanupDisplayLimit)) }
    var displayedCleanupGroups: [AssessmentGroup] { Array(groups.prefix(cleanupDisplayLimit)) }
    var cleanupHasMore: Bool { (presentation == .groups ? groups.count : filtered.count) > cleanupDisplayLimit }
    func loadMoreCleanup() { cleanupDisplayLimit += 100 }
    func preview(_ url: URL) {
        guard policy.permits(url), policy.hasNoSymlinkComponents(url), let stamp = FileStamp.read(url), stamp.isRegular, !stamp.isDataless,
              let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey]), values.isUbiquitousItem != true else { message = "此文件暂时无法预览"; return }
        previewURL = url
    }
    var groups: [AssessmentGroup] {
        let key = filterKey
        if let cache = groupsCache, cache.key == key { return cache.values }
        let values = AssessmentGroup.build(filtered)
        let sorted: [AssessmentGroup] = {
        switch ordering {
        case .size: return values.sorted { $0.bytes == $1.bytes ? $0.id < $1.id : $0.bytes > $1.bytes }
        case .oldest: return values.sorted { ($0.items.map(\.modified).min() ?? .distantFuture) < ($1.items.map(\.modified).min() ?? .distantFuture) }
        case .leastUsed: return values.sorted { ($0.items.map(lastActivity).max() ?? .distantFuture) < ($1.items.map(lastActivity).max() ?? .distantFuture) }
        case .name: return values.sorted { $0.assessment.group.localizedStandardCompare($1.assessment.group) == .orderedAscending }
        }        }()
        groupsCache = (key,sorted)
        return sorted
    }
    func total(for disposition: CleanupDisposition) -> Int64 { items.filter { $0.assessment.disposition == disposition && (cleanupOwnerFilter == nil || ($0.assessment.canBatchSelect && ownerResolver.cleanupOwner($0).id == cleanupOwnerFilter)) }.reduce(0) { $0 + $1.bytes } }
    func showDisposition(_ value: CleanupDisposition?) {
        cleanupScope = nil; cleanupTrail = []; disposition = value; category = nil; groupFilter = nil; search = ""; minimumFilter = 0; onlySelected = false; presentation = .groups
    }
    func showGroup(_ group: AssessmentGroup) {
        cleanupTrail.append(cleanupLocation); groupFilter = group.id; presentation = .files
    }
    func selectPriority() {
        guard !busy else { return }
        let recommendations = unselectedRecommendations
        for item in recommendations { saveSelectionSource(for: item) }
        selected.formUnion(recommendations.map(\.id))
    }
    private func saveSelectionSource(for item: ScanItem) {
        if storageCleanup != nil { additionalSelections[item.id] = item }
        else { additionalSelections.removeValue(forKey: item.id) }
    }
    func toggleGroup(_ group: AssessmentGroup) {
        let ids = Set(group.items.map(\.id))
        toggleSelection(filtered.filter { ids.contains($0.id) && $0.assessment.groupID == group.id })
    }
    private func toggleSelection(_ candidates: [ScanItem]) {
        guard !busy, !candidates.isEmpty else { return }
        let ids = Set(candidates.map(\.id))
        if candidates.allSatisfy(isSelectedForReview) { selected.subtract(ids); return }
        var accepted = Set<String>(), rejected = 0
        for item in candidates where !isSelectedForReview(item) {
            if item.assessment.requiresIndividualConfirmation {
                do { try policy.validate(item) }
                catch { rejected += 1; continue }
                manuallySelectedStamps[item.id] = item.stamp
            }
            saveSelectionSource(for: item)
            accepted.insert(item.id)
        }
        selected.formUnion(accepted)
        if rejected > 0 { message = "有 \(rejected) 项已变化或无法访问，未选中；请重新扫描。" }
    }
    func refresh() {
        guard !sampling else { return }
        sampling = true
        let records = history, policy = self.policy
        DispatchQueue.global(qos: .utility).async {
            let snapshot = autoreleasepool { SystemSnapshot.sample() }
            let states = Dictionary(uniqueKeysWithValues: records.map { ($0.id, RestoreAvailability.check(record: $0, policy: policy)) })
            DispatchQueue.main.async { self.snapshot = snapshot; self.workbench.recordMemory(snapshot); self.restoreStates = states; self.sampling = false }
        }
    }
    private func loadLastScan() {
        let adjacent = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("轻扫扫描结果.json")
        let url = FileManager.default.fileExists(atPath: reportURL.path) ? reportURL : adjacent
        let policy = self.policy, ignored = preferences, catalogURL = self.catalogURL
        loadingReport = true
        DispatchQueue.global(qos: .utility).async {
            var report: ScanArchive?
            var valid: [ScanItem] = []
            var restoredAccess = false
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 50_000_000,
               let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode(ScanArchive.self, from: data), [2, 3].contains(decoded.schemaVersion) {
                let complete: ScanArchive
                if decoded.catalogVersion == 1 {
                    do { complete = try CleanupCatalog(url: catalogURL).archive() }
                    catch { DispatchQueue.main.async { self.message = "清理清单需要重新扫描；清理记录与忽略列表已保留" }; complete = decoded }
                } else { complete = decoded }
                report = complete
                valid = ScanReportLoader.validate(report: complete, policy: policy, context: InspectionContext.collect(), ignored: ignored)
                if complete.schemaVersion == 3, let config = complete.configuration, config.isValid(policy: policy) {
                    restoredAccess = complete.result.accessIssues?.contains { issue in
                        issue.kind == .permission && policy.permits(issue.url) && !ignored.isIgnored(issue.url) &&
                        config.roots.contains(where: { SafetyPolicy.within(issue.url, $0) }) &&
                        StorageAccessProbe.problem(at: issue.url, root: issue.root) == nil
                    } == true
                }
            }
            DispatchQueue.main.async {
                if let report {
                    self.items = valid; self.result = report.result; self.scannedAt = report.scannedAt; self.scanLabel = report.label
                    self.currentScanConfiguration = report.schemaVersion == 3 && report.configuration?.isValid(policy: self.policy) == true ? report.configuration : nil
                    self.lastRoots = self.currentScanConfiguration?.roots ?? []
                    self.lastMinimum = self.currentScanConfiguration?.minimumBytes ?? 1_000_000
                    self.applyUnusedView(self.currentScanConfiguration)
                    self.cleanupDisplayLimit = 100
                }
                self.loadingReport = false
                if restoredAccess { self.resumeCleanupScanAfterAccessChange() }
            }
        }
    }
    private func resumeCleanupScanAfterAccessChange() {
        if loadingStorageIndex || loadingReport {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.resumeCleanupScanAfterAccessChange() }
            return
        }
        guard !busy, selected.isEmpty, currentScanConfiguration != nil else { return }
        recheckCleanupScanAccess()
    }
    func smartScan() {
        guard !busy else { return }
        let config = refreshedCommonConfiguration(currentScanConfiguration) ?? commonScanConfiguration
        runStorageAnalysis(navigate: false, recheckingCleanupRoots: config.roots)
        startCleanupScan(config)
    }
    func stopSmartScan() { cancelScan(); cancelStorageAnalysis() }
    /// Downloads, caches and logs, plus the allowlisted developer and app caches that exist on this Mac.
    private var commonRoots: [URL] {
        ["Downloads", "Library/Caches", "Library/Logs"].map { home.appendingPathComponent($0) } + KnownCacheLocations.existingRoots(home: home)
    }
    private var commonScanConfiguration: ScanConfiguration {
        ScanConfiguration(roots: commonRoots, label: "常用位置", minimumBytes: 1_000_000)
    }
    /// A saved "common locations" scan picks up cache locations added in later versions.
    private func refreshedCommonConfiguration(_ config: ScanConfiguration?) -> ScanConfiguration? {
        guard let config else { return nil }
        return config.label == "常用位置" && config.minimumBytes == 1_000_000 ? commonScanConfiguration : config
    }
    func quickScan() { startCleanupScan(commonScanConfiguration) }
    private var personalRoots: [URL] {
        ["Downloads", "Desktop", "Documents", "Movies", "Pictures", "Music"].map { home.appendingPathComponent($0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
    func personalScan() {
        scan(roots: personalRoots, label: "大文件", minimum: 100_000_000)
    }
    func applyUnusedView(_ configuration: ScanConfiguration?) {
        unusedFilter = configuration?.unusedDays ?? 0
        if unusedFilter > 0 { ordering = .leastUsed } else if ordering == .leastUsed { ordering = .size }
    }
    /// Large personal files that have not been modified, opened or added for half a year.
    /// They stay in "需自行确认": selecting them is manual and needs the second confirmation.
    func unusedLargeFileScan() {
        startCleanupScan(ScanConfiguration(roots: personalRoots, label: "长期未用的大文件", minimumBytes: 100_000_000, unusedDays: 180))
    }
    func chooseFolder() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.title = L("选择文件夹"); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.directoryURL = home; panel.prompt = L("扫描")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard policy.permits(url), policy.hasNoSymlinkComponents(url) else { message = SweepError.rootDenied.localizedDescription; return }
        scan(roots: [url], label: url.lastPathComponent, minimum: 1_000_000)
    }
    func rescan() {
        guard !busy else { return }
        if section == .results, let storageCleanup { beginStorageCleanup(storageCleanup) }
        else if let config = refreshedCommonConfiguration(currentScanConfiguration) { startCleanupScan(config) }
        else { showingScanChooser = true }
    }
    func scan(roots: [URL], label: String, minimum: Int64) {
        startCleanupScan(ScanConfiguration(roots: roots, label: label, minimumBytes: minimum))
    }
    func beginStorageCleanup(_ source: StorageCleanup) {
        guard !busy else { return }
        if source.archive == nil {
            showDisposition(nil)
            cleanupOwnerFilter = source.owner?.id
            cleanupOwnerTitle = source.owner?.title
        }
        storageCleanup = source
        section = .results
        startCleanupScan(source.configuration, source: source)
    }
    private func startCleanupScan(_ configuration: ScanConfiguration, source: StorageCleanup? = nil) {
        guard !scanning, !mutating, !loadingReport, !showingReview else { return }
        if source == nil && storageCleanup != nil { clearCleanupOwner() }
        let token = ScanCancellation(); cancellation = token
        showingIssues = false
        scanning = true; progress = ScanProgress(); stoppedCleanupScan = nil; message = nil
        let scanner = DiskScanner(policy: policy, minimumBytes: configuration.minimumBytes,
                                  excludedRoots: preferences.ignoredPaths.map { URL(fileURLWithPath: $0) },
                                  includeSmallKnownCaches: configuration.minimumBytes == 1_000_000)
        let indexURL = storageIndexURL!
        DispatchQueue.global(qos: .utility).async {
            let progress: (ScanProgress) -> Void = { update in DispatchQueue.main.async { self.progress = update } }
            let result = autoreleasepool {
                if let source, let owner = source.owner {
                    return Self.scanIndexedCleanup(indexURL, owner: owner.id, folder: source.folder, scanner: scanner, token: token, progress: progress)
                }
                return scanner.scan(roots: configuration.roots, cancellation: token, progress: progress)
            }
            DispatchQueue.main.async {
                let now = Date()
                self.scanning = false; self.cancellation = nil
                guard !result.cancelled, !token.isCancelled else {
                    self.stoppedCleanupScan = StoppedCleanupScan(date: now, visited: result.visited)
                    return
                }
                if var source {
                    source.archive = ScanArchive(schemaVersion: 3, scannedAt: now, label: configuration.label,
                                                 result: result, configuration: configuration)
                    self.storageCleanup = source
                    self.applyUnusedView(configuration)
                    self.selectFirstPopulatedCleanupScope()
                } else {
                    self.clearCleanupOwner()
                    self.selected.removeAll()
                    self.lastRoots = configuration.roots; self.lastMinimum = configuration.minimumBytes
                    self.currentScanConfiguration = configuration; self.scanLabel = configuration.label
                    self.result = result; self.items = result.items; self.scannedAt = now
                    self.applyUnusedView(configuration)
                    self.selectFirstPopulatedCleanupScope()
                    self.saveReport()
                }
                if result.accessIssues?.contains(where: { $0.kind == .permission }) == true { self.showingIssues = true }
                self.refresh()
            }
        }
    }
    nonisolated private static func scanIndexedCleanup(_ indexURL: URL, owner: String, folder: URL?, scanner: DiskScanner,
                                                       token: ScanCancellation, progress: (ScanProgress) -> Void) -> ScanResult {
        let start = Date()
        let classifier = FileClassifier(policy: scanner.policy, context: InspectionContext.collect(home: scanner.policy.home))
        var result = ScanResult(), bytes: Int64 = 0
        var issues: [String: StorageAccessIssue] = [:]
        var lastUpdate = Date.distantPast
        do {
            try StorageIndex(url: indexURL).visitFiles(ownedBy: owner, in: folder) { url, root in
                guard !token.isCancelled else { return false }
                result.visited += 1
                autoreleasepool {
                    do {
                        if let item = try scanner.inspectIndexedFile(url, root: root, classifier: classifier) {
                            result.items.append(item); bytes += item.bytes
                        }
                    } catch {
                        let issue = StorageAccessIssue.make(url: url, root: root, error: error)
                        if issue.kind == .permission && issues.count < 100 { issues[issue.id] = issue }
                    }
                }
                if Date().timeIntervalSince(lastUpdate) > 0.18 {
                    lastUpdate = Date()
                    progress(ScanProgress(visited: result.visited, found: result.items.count, bytes: bytes, current: url.deletingLastPathComponent().path))
                }
                return true
            }
        } catch { result.issues.append(error.localizedDescription) }
        result.accessIssues = issues.values.sorted { $0.id < $1.id }
        result.issues += issues.values.map(\.detail)
        result.cancelled = token.isCancelled
        result.elapsed = Date().timeIntervalSince(start)
        return result
    }
    private func saveReport() {
        guard var result, let scannedAt else { return }
        result.items = items
        self.result = result
        let archive = ScanArchive(schemaVersion: 3, scannedAt: scannedAt, label: scanLabel, result: result, preselectPriority: false, configuration: currentScanConfiguration)
        do {
            try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try CleanupCatalog.save(archive, to: catalogURL)
            var summaryResult = result; summaryResult.items = []
            let summary = ScanArchive(schemaVersion: 3, scannedAt: scannedAt, label: scanLabel, result: summaryResult, preselectPriority: false, configuration: currentScanConfiguration, catalogVersion: 1)
            try JSONEncoder().encode(summary).write(to: reportURL, options: .atomic)
        } catch { message = "扫描记录保存失败，本次结果仍可使用" }
    }
    func updateScopedCleanupItems(_ change: (inout [ScanItem]) -> Void) {
        guard var source = storageCleanup, let archive = source.archive else { return }
        var result = archive.result
        change(&result.items)
        source.archive = ScanArchive(schemaVersion: archive.schemaVersion, scannedAt: archive.scannedAt,
                                     label: archive.label, result: result, configuration: archive.configuration)
        storageCleanup = source
    }
    func startStorageAnalysis(navigate: Bool = true) { runStorageAnalysis(navigate: navigate) }
    func cancelStorageAnalysis() { storageAutoContinue = false; auditCancellation?.cancel() }
    func toggleStorage(_ id: String) { if expandedStorage.contains(id) { expandedStorage.remove(id) } else { expandedStorage.insert(id) } }
    func cancelScan() { cancellation?.cancel() }
    func toggle(_ item: ScanItem, on: Bool) {
        guard !busy, !preferences.isIgnored(item.url) else { return }
        if !on { selected.remove(item.id); return }
        guard cleanupItems.contains(where: { $0.id == item.id && $0.stamp == item.stamp }) else { return }
        selectFile(item, outsideReport: storageCleanup != nil)
    }
    private func selectFile(_ item: ScanItem, outsideReport: Bool) {
        guard !preferences.isIgnored(item.url) else { return }
        if item.assessment.requiresIndividualConfirmation {
            do { try policy.validate(item) }
            catch { message = error.localizedDescription; return }
            manuallySelectedStamps[item.id] = item.stamp
        }
        if outsideReport { additionalSelections[item.id] = item }
        else { additionalSelections.removeValue(forKey: item.id) }
        selected.insert(item.id)
    }
    func canAddIndexedFile(_ item: IndexedStorageItem) -> Bool {
        !item.isDirectory && item.state == 1 && policy.permits(item.root) && policy.permits(item.url) &&
            SafetyPolicy.within(item.url, item.root) && !preferences.isIgnored(item.url)
    }
    func addIndexedFileForReview(_ entry: IndexedStorageItem) {
        guard !busy, canAddIndexedFile(entry) else { return }
        addingIndexedFile = true
        let scanner = DiskScanner(policy: policy, minimumBytes: 0,
                                  excludedRoots: preferences.ignoredPaths.map { URL(fileURLWithPath: $0) })
        Task {
            let inspected = await Task.detached(priority: .utility) {
                let classifier = FileClassifier(policy: scanner.policy, context: InspectionContext.collect(home: scanner.policy.home))
                return try? scanner.inspectIndexedFile(entry.url, root: entry.root, classifier: classifier)
            }.value
            addingIndexedFile = false
            guard let item = inspected else { message = "无法将此文件加入待复核"; return }
            selectFile(item, outsideReport: true)
            if isSelectedForReview(item) { storageItemDetail = nil }
        }
    }
    func toggleVisible() { toggleSelection(visibleSelectableItems) }
    func ignore(_ url: URL) {
        guard !busy else { return }
        var next = preferences; next.ignore(url)
        do { try next.save(url: preferencesURL); preferences = next }
        catch { message = "忽略列表保存失败"; return }
        let removed = Set(items.filter { preferences.isIgnored($0.url) }.map(\.id))
        items.removeAll { removed.contains($0.id) }
        selected.subtract(removed.union(additionalSelections.values.filter { preferences.isIgnored($0.url) }.map(\.id)))
        inspecting = nil
    }
    func unignore(_ path: String) {
        var next = preferences; next.unignore(path)
        do { try next.save(url: preferencesURL); preferences = next }
        catch { message = "忽略列表保存失败" }
    }
    func prepareReview() {
        guard !busy else { return }
        reviewScopeTitle = "全部已选文件";reviewNotice=nil;reviewRetryParent=nil
        review = selectedItems; reviewConfirmed = false
        if !review.isEmpty { showingReview = true }
    }
    var manualReviewItems: [ScanItem] { review.filter { $0.assessment.requiresIndividualConfirmation } }
    var canProceedWithReview: Bool {
        showingReview && !review.isEmpty && !mutating && !reconcilingCleanup && cleanupJournalFailure == nil && !scanning && !analyzing && !loadingReport &&
        reviewRetentionError == nil && review.allSatisfy { !preferences.isIgnored($0.url) && ($0.assessment.canBatchSelect || isIndividuallySelected($0)) }
    }
    private func resetManualConfirmation() {
        showingManualConfirmation = false; manualReviewAcknowledged = false
        manualCleanupConsent = nil; reviewConfirmed = false
    }
    func returnToReview() { resetManualConfirmation() }
    func removeReviewedItem(_ item: ScanItem) {
        review.removeAll { $0.id == item.id }; selected.remove(item.id);workbench.unselect([item.id])
    }
    func requestReviewedMove() {
        guard canProceedWithReview else { return }
        resetManualConfirmation()
        if !manualReviewItems.isEmpty { showingManualConfirmation = true }
        else { reviewConfirmed = true; moveReviewed() }
    }
    func confirmManualCleanup() {
        guard canProceedWithReview, showingManualConfirmation, manualReviewAcknowledged, !manualReviewItems.isEmpty else { return }
        manualCleanupConsent = ManualCleanupConsent(reviewedItems: review)
        reviewConfirmed = true; moveReviewed()
    }
    func moveReviewed() {
        guard canProceedWithReview, reviewConfirmed else { return }
        if !manualReviewItems.isEmpty {
            guard manualCleanupConsent?.matches(review) == true,
                  manualReviewItems.allSatisfy({ isIndividuallySelected($0) && manualCleanupConsent?.permits($0) == true }) else { return }
        }
        let targets = review, consent = manualCleanupConsent, cancellation = ScanCancellation(), guards=retainedCopies
        let batchID = UUID(), batchDate = Date(), batchTitle = reviewScopeTitle, freeBefore = SystemSnapshot.sample().diskFree, retryParent=reviewRetryParent
        guard let journal = beginCleanupBatch(CleanupJournalBatch(id:batchID,date:batchDate,title:batchTitle,requestedCount:targets.count,freeBefore:freeBefore,retryFiles:targets.map{CleanupRetryTarget(item:$0,retainedCopy:guards[$0.id])},retryManaged:nil,retryOf:retryParent)) else { return }
        cleanupCancellation = cancellation; canCancelCleanup = true
        showingReview = false; mutating = true; operationProgress = "正在检查文件与应用占用"
        Task {
            let outcome = await CleanupExecutor(environment: cleanupEnvironment).run(targets, policy: policy, consent: consent,
                cancellation: cancellation, retainedCopies:guards, journal:CleanupJournalContext(journal:journal,batchID:batchID)) { text in self.operationProgress = text }
            var result = outcome.trash
            if let state = await checkedJournalAfterOperation(journal) {
                result.records = state.entries.filter{$0.batchID == batchID && $0.state == .moved}.compactMap(\.record)
            }
            result.records = result.records.map { record in var value = record; value.batchID = batchID; return value }
            var receipt = CleanupReceipt(id: batchID, date: batchDate, title: batchTitle, requestedCount: targets.count, movedCount: result.records.count, movedBytes: result.records.reduce(0) { $0 + $1.bytes }, freeBefore: freeBefore, freeAfter: SystemSnapshot.sample().diskFree, errors: result.errors, cancelled: outcome.cancelled)
            let movedPaths=Set(result.records.map{ $0.original.path })
            receipt.retryFiles=targets.filter{!movedPaths.contains($0.id)}.map{CleanupRetryTarget(item:$0,retainedCopy:guards[$0.id])};receipt.retryOf=retryParent
            do { try journal.finish(receipt) } catch { cleanupJournalFailure = error.localizedDescription }
            resolveRetryParent(retryParent,moved:movedPaths)
            cleanupReceipts.insert(receipt, at: 0)
            let removed = Set(result.records.map { $0.original.path });workbench.didMove(result.records.map(\.original))
            items.removeAll { removed.contains($0.id) }
            updateScopedCleanupItems { $0.removeAll { removed.contains($0.id) } }
            selected.subtract(removed); history.insert(contentsOf: result.records, at: 0)
            let saveError = saveHistory(); mutating = false; canCancelCleanup = false; cleanupCancellation = nil
            operationOutcome=OperationOutcome(title:outcome.cancelled ? "已停止清理":"清理结果",completed:result.records.count,bytes:receipt.movedBytes,errors:result.errors,receipt:receipt,saveFailure:saveError)
            measureTrash(records:result.records)
            review=[];saveReport();refreshStorageIndex(paths:result.records.map(\.original));refresh()
        }
    }
    func cancelCleanup() {
        cleanupCancellation?.cancel(); canCancelCleanup = false
        operationProgress = "正在停止；已发出的退出请求可能仍会完成"
    }
    func restore(_ record: TrashRecord) { restoreBatch([record]) }
    func restoreBatch(_ records: [TrashRecord]) {
        guard !busy, !records.isEmpty, cleanupJournalFailure == nil, let journal = cleanupJournal else { return }
        mutating = true; operationProgress = "正在恢复文件"
        let service = TrashService(policy: policy)
        let roots = lastRoots.isEmpty ? commonRoots : lastRoots
        let scanner = DiskScanner(policy: policy, minimumBytes: lastMinimum,
                                  excludedRoots: preferences.ignoredPaths.map { URL(fileURLWithPath: $0) },
                                  includeSmallKnownCaches: lastMinimum == 1_000_000)
        let folder = storageCleanup?.owner == nil ? storageCleanup?.folder : nil
        let folderScanner = DiskScanner(policy: policy, minimumBytes: 0, excludedRoots: scanner.excludedRoots)
        DispatchQueue.global(qos: .utility).async {
            let classifier = FileClassifier(policy: service.policy, context: InspectionContext.collect(home: service.policy.home))
            var recoveredItems: [ScanItem] = []
            var recoveredInFolder: [ScanItem] = []
            var restored = Set<UUID>(), errors: [String] = []
            for (index, record) in records.enumerated() {
                if journal.isBlocked { break }
                do {
                    try service.restore(record,journal:journal); restored.insert(record.id)
                    if let root = roots.first(where: { SafetyPolicy.within(record.original, $0) }),
                       let item = try? scanner.inspectIndexedFile(record.original, root: root, classifier: classifier) {
                        recoveredItems.append(item)
                    }
                    if let folder, let item = try? folderScanner.inspectIndexedFile(record.original, root: folder, classifier: classifier) {
                        recoveredInFolder.append(item)
                    }
                }
                catch { errors.append(record.original.lastPathComponent + "：" + error.localizedDescription) }
                if index % 20 == 0 { DispatchQueue.main.async { self.operationProgress = "正在恢复 \(index + 1) / \(records.count)" } }
            }
            let reconciled:CleanupJournalSnapshot?
            do { reconciled = journal.isBlocked ? nil : try journal.reconcile(policy:service.policy) }
            catch { reconciled=nil;errors.append(error.localizedDescription) }
            DispatchQueue.main.async {
                if journal.isBlocked { self.cleanupJournalFailure = CleanupJournalError.unavailable.localizedDescription }
                if let state=reconciled {
                    state.merge(history:&self.history,receipts:&self.cleanupReceipts)
                    self.cleanupJournalIssues=state.issues
                    if state.entries.contains(where:{$0.state == .pending || $0.state == .restoring}){self.cleanupJournalFailure=CleanupJournalError.unresolved.localizedDescription}
                }
                self.history.removeAll { restored.contains($0.id) }
                let recoveredIDs = Set(recoveredItems.map(\.id))
                self.items.removeAll { recoveredIDs.contains($0.id) }; self.items.append(contentsOf: recoveredItems)
                if !recoveredInFolder.isEmpty {
                    let ids = Set(recoveredInFolder.map(\.id))
                    self.updateScopedCleanupItems { $0.removeAll { ids.contains($0.id) }; $0 += recoveredInFolder }
                }
                let saveError = self.saveHistory(); self.mutating = false; self.saveReport()
                self.operationOutcome=OperationOutcome(title:"恢复结果",completed:restored.count,bytes:records.filter{restored.contains($0.id)}.reduce(0){$0+$1.bytes},errors:errors,restoreRemaining:records.filter{!restored.contains($0.id)},saveFailure:saveError)
                self.measureTrash(records: records)
                self.refreshStorageIndex(paths: records.filter { restored.contains($0.id) }.map(\.original), restoring: true)
                self.refresh()
            }
        }
    }
    var historyBatches: [CleanupHistoryBatch] {
        var grouped = Dictionary(grouping: history) { $0.batchID?.uuidString ?? "legacy:" + String(Calendar.current.startOfDay(for: $0.date).timeIntervalSince1970) }
        var batches = cleanupReceipts.map { receipt in
            CleanupHistoryBatch(id: receipt.id.uuidString, date: receipt.date, title: receipt.title, records: grouped.removeValue(forKey: receipt.id.uuidString) ?? [], receipt: receipt)
        }
        batches += grouped.map { key, records in CleanupHistoryBatch(id: key, date: records.map(\.date).max() ?? .distantPast, title: "早期清理记录", records: records, receipt: nil) }
        return batches.sorted { $0.date > $1.date }
    }
    func restorableRecords(in batch: CleanupHistoryBatch) -> [TrashRecord] { batch.records.filter { restoreStates[$0.id] == .available } }
    private func saveHistory() -> String? {
        do { try FileManager.default.createDirectory(at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true); try JSONEncoder().encode(history).write(to: historyURL, options: .atomic); try JSONEncoder().encode(cleanupReceipts).write(to: receiptsURL, options: .atomic); return cleanupJournalFailure }
        catch { return error.localizedDescription }
    }
    private func beginCleanupBatch(_ batch:CleanupJournalBatch) -> CleanupOperationJournal? {
        guard cleanupJournalFailure == nil, let journal=cleanupJournal else { message=cleanupJournalFailure;return nil }
        do {
            let state=try journal.snapshot()
            guard !state.entries.contains(where:{$0.state == .pending || $0.state == .restoring}),!state.batches.contains(where:{$0.receipt == nil}) else { throw CleanupJournalError.unresolved }
            try journal.begin(batch);return journal
        }catch{cleanupJournalFailure=error.localizedDescription;message=cleanupJournalFailure;return nil}
    }
    private func checkedJournalAfterOperation(_ journal:CleanupOperationJournal) async -> CleanupJournalSnapshot? {
        do {
            guard !journal.isBlocked else{throw CleanupJournalError.unavailable}
            let initial=try journal.snapshot()
            let state:CleanupJournalSnapshot
            if initial.entries.contains(where:{$0.state == .pending || $0.state == .restoring}) {
                state=try await Task.detached(priority:.utility){try journal.reconcile(policy:self.policy)}.value
            }else{state=initial}
            cleanupJournalIssues=state.issues
            if state.entries.contains(where:{$0.state == .pending || $0.state == .restoring}){cleanupJournalFailure=CleanupJournalError.unresolved.localizedDescription}
            return state
        }catch{cleanupJournalFailure=error.localizedDescription;return nil}
    }
    func reconcileCleanupOperations() {
        guard !mutating,!reconcilingCleanup,let journal=cleanupJournal else{return}
        reconcilingCleanup=true;operationProgress="正在核对上次文件操作";let policy=self.policy
        Task {
            do {
                let state=try await Task.detached(priority:.utility){try journal.reconcile(policy:policy)}.value
                state.merge(history:&history,receipts:&cleanupReceipts)
                cleanupJournalIssues=state.issues
                cleanupJournalFailure=state.entries.contains{$0.state == .pending || $0.state == .restoring} ? (state.issues.contains{$0.contains("完全磁盘访问")} ? CleanupJournalError.trashAccess.localizedDescription:CleanupJournalError.unresolved.localizedDescription):nil
                cleanupIndexRefreshPaths=state.entries.map(\.original)
                _=saveHistory()
                // A crash may have interrupted index updates as well as JSON summary writes.
                refreshReconciledStorage()
                restoreStates=Dictionary(uniqueKeysWithValues:history.map{($0.id,RestoreAvailability.check(record:$0,policy:policy))})
            }catch{cleanupJournalFailure=error.localizedDescription}
            reconcilingCleanup=false;refreshReconciledStorage();refresh()
        }
    }
    func refreshReconciledStorage(){
        guard storageInfo != nil,!loadingStorageIndex,!reconcilingCleanup,!cleanupIndexRefreshPaths.isEmpty else{return}
        let paths=cleanupIndexRefreshPaths;cleanupIndexRefreshPaths=[];refreshStorageIndex(paths:paths)
    }
    func recheckCleanupScanAccess() {
        guard !busy else { return }
        showingIssues = false
        rescan()
    }
    func openCleanupScanAccessSettings() {
        shouldRecheckCleanupScanOnActivation = true
        if let url=URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"){NSWorkspace.shared.open(url)}
    }
    func openCleanupAccessSettings(){
        shouldRecheckCleanupOnActivation=true
        if let url=URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"){NSWorkspace.shared.open(url)}
    }
    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    func copyPath(_ url: URL) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.path, forType: .string) }
    func openTrash() { NSWorkspace.shared.open(home.appendingPathComponent(".Trash")) }
    /// Measures the Trash off the main thread and attaches the result to the current outcome.
    func measureTrash(records: [TrashRecord]) {
        let folders = TrashUsage.folders(home: home, records: records), outcomeID = operationOutcome?.id
        DispatchQueue.global(qos: .utility).async {
            let usage = TrashUsage.measure(folders)
            DispatchQueue.main.async {
                self.trashUsage = usage
                if var outcome = self.operationOutcome, outcome.id == outcomeID {
                    outcome.trashUsage = usage; outcome.trashMeasured = true; self.operationOutcome = outcome
                }
            }
        }
    }
    func openActivityMonitor() { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")) }
}


/// Always answer macOS Quit explicitly, including while the access assistant is open.
/// A file operation is allowed to finish its cancellation and persist its receipt first.
@MainActor final class QingSweepApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    var terminationReplyForTesting: ((Bool) -> Void)?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { model?.workbench.menuEnabled != true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else{return .terminateNow}
        guard model.mutating || model.reconcilingCleanup || model.workbench.busy else {return .terminateNow}
        model.workbench.stop()
        model.cancelCleanup()
        Task { @MainActor in
            while model.mutating || model.reconcilingCleanup || model.workbench.busy { try? await Task.sleep(nanoseconds: 50_000_000) }
            if let reply = self.terminationReplyForTesting { reply(true) }
            else { sender.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }
}


extension AppModel {
    var reviewRetentionError:String? {
        let paths=Set(review.map(\.id))
        if review.contains(where:{retainedCopies[$0.id].map{paths.contains($0.url.path)} == true}) {return "保留的副本也在本次清单中，请取消其中一份的选择"}
        return nil
    }
    func reviewToolFiles(_ candidates:[ScanItem],title:String,guards:[String:RetainedCopy]=[:]) {
        guard !busy,!candidates.isEmpty else{return}
        reviewRetryParent=nil;reviewNotice=nil
        let ids=Set(candidates.map(\.id))
        if guards.filter({ids.contains($0.key)}).values.contains(where:{ids.contains($0.url.path)}) {message="每组至少保留一份文件";return}
        items.removeAll{ids.contains($0.id)};items.append(contentsOf:candidates)
        for item in candidates { selectFile(item, outsideReport: false) }
        for (path,copy) in guards where selected.contains(path){retainedCopies[path]=copy}
        review=candidates.filter(isSelectedForReview);reviewScopeTitle=title
        if !review.isEmpty{showingReview=true}
    }
    func moveManagedReview(){
        guard !busy,cleanupJournalFailure == nil,workbench.showingManagedReview,workbench.managedAcknowledged,!workbench.managedReview.isEmpty else{return}
        let targets=workbench.managedReview,token=ScanCancellation(),id=UUID(),date=Date(),before=SystemSnapshot.sample().diskFree,parent=managedRetryParent.flatMap { id in
            let paths=Set(cleanupReceipts.first{$0.id==id}?.retryManaged?.map(\.id) ?? []);return Set(workbench.managedReview.map(\.id)).isSubset(of:paths) ? id:nil
        }
        guard let journal=beginCleanupBatch(CleanupJournalBatch(id:id,date:date,title:"应用与私有内容",requestedCount:targets.count,freeBefore:before,retryFiles:nil,retryManaged:targets.map{ManagedRetryTarget($0)},retryOf:parent)) else{return}
        managedRetryParent=nil
        workbench.showingManagedReview=false;mutating=true;cleanupCancellation=token;canCancelCleanup=true;operationProgress="正在退出应用与核实内容"
        Task {
            var result=await ManagedTrash.move(targets,home:home,cancellation:token,journal:CleanupJournalContext(journal:journal,batchID:id)){self.operationProgress=$0}
            if let state=await checkedJournalAfterOperation(journal){result.records=state.entries.filter{$0.batchID==id && $0.state == .moved}.compactMap(\.record)}
            result.records=result.records.map{var record=$0;record.batchID=id;return record}
            history.insert(contentsOf:result.records,at:0)
            let movedSet=Set(result.records.map{$0.original.path})
            var receipt=CleanupReceipt(id:id,date:date,title:"应用与私有内容",requestedCount:targets.count,movedCount:result.records.count,movedBytes:result.records.reduce(0){$0+$1.bytes},freeBefore:before,freeAfter:SystemSnapshot.sample().diskFree,errors:result.errors,cancelled:token.isCancelled)
            receipt.retryManaged=targets.filter{!movedSet.contains($0.id)}.map{ManagedRetryTarget($0)};receipt.retryOf=parent
            do{try journal.finish(receipt)}catch{cleanupJournalFailure=error.localizedDescription}
            resolveRetryParent(parent,moved:movedSet);cleanupReceipts.insert(receipt,at:0)
            let moved=result.records.map(\.original)
            func wasMoved(_ item: ScanItem) -> Bool { moved.contains { SafetyPolicy.within(item.url, $0) } }
            let removed = selectedItems.filter(wasMoved).map(\.id)
            items.removeAll(where: wasMoved)
            updateScopedCleanupItems { $0.removeAll(where: wasMoved) }
            selected.subtract(removed)
            workbench.managedSelected=[];workbench.managedReview=[];workbench.inspection=nil;workbench.managedRetryItems=nil;workbench.leftovers.removeAll{FileStamp.read($0.url)==nil};workbench.applications.removeAll{FileStamp.read(URL(fileURLWithPath:$0.path))==nil}
            let error=saveHistory();mutating=false;canCancelCleanup=false;cleanupCancellation=nil;saveReport();refreshStorageIndex(paths:moved);refresh()
            operationOutcome=OperationOutcome(title:token.isCancelled ? "已停止清理":"清理结果",completed:result.records.count,bytes:receipt.movedBytes,errors:result.errors,receipt:receipt,saveFailure:error)
            measureTrash(records:result.records)
        }
    }
    func showStorageOwner(_ id:String,title:String){
        section = .storage; storageShowsMap=false
        browseStorage(nil,owner:appSummaries.first{$0.id==id} ?? AppStorageSummary(id:id,title:title))
    }
    func captureGrowth(){
        guard storageInfo != nil else{return};let file=storageIndexURL!,apps=storageApplications
        storageQueue.async {do{if let snapshot=try GrowthHistory.capture(index:StorageIndex(url:file),applications:apps){DispatchQueue.main.async{self.workbench.recordGrowth(snapshot)}}}catch{}}
    }
}


extension AppModel {
    private func resolveRetryParent(_ id:UUID?,moved:Set<String>){
        guard let id,let index=cleanupReceipts.firstIndex(where:{$0.id==id}) else{return}
        cleanupReceipts[index].retryFiles?.removeAll{moved.contains($0.id)}
        cleanupReceipts[index].retryManaged?.removeAll{moved.contains($0.id)}
    }
    func retryCleanup(_ receipt:CleanupReceipt){
        guard !busy,receipt.retryCount>0 else{return}
        operationOutcome=nil;mutating=true;operationProgress="重新读取未处理项";let token=ScanCancellation();cleanupCancellation=token;canCancelCleanup=true
        let policy=self.policy,preferences=self.preferences
        Task {
            let checked=await Task.detached(priority:.utility){()->([ScanItem],[ManagedItem],[String:RetainedCopy],[String]) in
                let classifier=FileClassifier(policy:policy,context:InspectionContext.collect(home:policy.home))
                var files:[ScanItem]=[],managed:[ManagedItem]=[],guards:[String:RetainedCopy]=[:],errors:[String]=[]
                for reference in receipt.retryFiles ?? [] {
                    if token.isCancelled{break}
                    do{guard !preferences.isIgnored(reference.url) else{throw ToolFailure.invalid("已加入忽略列表")};let item=try reference.recheck(policy:policy,classifier:classifier,cancellation:token);files.append(item);guards[item.id]=reference.retainedCopy}catch{errors.append(reference.url.lastPathComponent+"："+error.localizedDescription)}
                }
                for reference in receipt.retryManaged ?? [] {
                    if token.isCancelled{break}
                    do{guard !preferences.isIgnored(reference.url) else{throw ToolFailure.invalid("已加入忽略列表")};managed.append(try reference.recheck(home:policy.home,cancellation:token))}catch{errors.append(reference.url.lastPathComponent+"："+error.localizedDescription)}
                }
                return(files,managed,guards,errors)
            }.value
            mutating=false;cleanupCancellation=nil;canCancelCleanup=false
            guard !token.isCancelled else{message="已停止重新检查";return}
            if !checked.0.isEmpty {
                reviewToolFiles(checked.0,title:receipt.title+" · 重试",guards:checked.2);reviewRetryParent=receipt.id
                reviewNotice="已按当前文件状态重建清单，请重新核对"+(checked.3.isEmpty ? "":"；另有 \(checked.3.count) 项暂不可用")
            }else if !checked.1.isEmpty {
                section = .tools;workbench.section = .applications;workbench.loadManagedRetry(checked.1);managedRetryParent=receipt.id
            }else{message=checked.3.isEmpty ? "未处理项已不存在，无需重试":checked.3.prefix(20).joined(separator:"\n")}
        }
    }
    func retrySaveHistory(){guard var outcome=operationOutcome else{return};outcome.saveFailure=saveHistory();operationOutcome=outcome}
    func retryRestore(_ outcome:OperationOutcome){guard !busy else{return};operationOutcome=nil;restoreBatch(outcome.restoreRemaining)}
}
