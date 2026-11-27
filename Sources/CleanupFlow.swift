import Foundation

enum CleanupScope: String, CaseIterable, Identifiable {
    case recommended = "推荐清理", optional = "可自行选择", protected = "需自行确认"
    var id: String { rawValue }
    var shortDescription: String {
        switch self {
        case .recommended: return "旧安装包与下载缓存"
        case .optional: return "查看影响后手动选择"
        case .protected: return "手动选择，二次确认"
        }
    }
    var explanation: String {
        switch self {
        case .recommended: return "至少 7 天未修改的已识别旧安装包、下载缓存；只添加当前范围"
        case .optional: return "可重建缓存、日志和重装介质；请查看影响后手动选择"
        case .protected: return "素材和项目默认不选；可全选、按组或逐项选择，清理前二次确认"
        }
    }
    func contains(_ item: ScanItem) -> Bool {
        switch self {
        case .recommended: return item.assessment.canBatchSelect && item.assessment.disposition == .priority
        case .optional: return item.assessment.canBatchSelect && item.assessment.disposition != .priority
        case .protected: return !item.assessment.canBatchSelect
        }
    }
    static func forAssessment(_ assessment: FileAssessment) -> CleanupScope {
        guard assessment.canBatchSelect else { return .protected }
        return assessment.disposition == .priority ? .recommended : .optional
    }
}

struct CleanupLocation {
    let scope: CleanupScope?
    let disposition: CleanupDisposition?
    let category: FileCategory?
    let group: String?
    let search: String
    let minimum: Int64
    let onlySelected: Bool
    let presentation: ResultPresentation
    let ordering: FileOrdering
}
struct StorageLocation {
    let mode: StoragePresentation
    let folder: URL?
    let owner: String?
    let ownerTitle: String?
    let search: String
    let ordering: FileOrdering
}

struct StorageCleanup {
    let configuration: ScanConfiguration
    let owner: AppStorageSummary?
    let folder: URL?
    var archive: ScanArchive?
}

struct StoppedCleanupScan {
    let date: Date
    let visited: Int
}

@MainActor extension AppModel {
    var cleanupItems: [ScanItem] {
        storageCleanup.map { $0.archive?.result.items ?? [] } ?? items
    }
    var cleanupResult: ScanResult? {
        if let storageCleanup { return storageCleanup.archive?.result }
        return result
    }
    var cleanupScannedAt: Date? {
        if let storageCleanup { return storageCleanup.archive?.scannedAt }
        return scannedAt
    }
    var cleanupConfiguration: ScanConfiguration? {
        storageCleanup?.configuration ?? currentScanConfiguration
    }
    var cleanupLabel: String { storageCleanup?.configuration.label ?? scanLabel }
    var cleanupIsPartial: Bool {
        cleanupResult?.isPartial == true
    }
    var visibleBatchSelectableItems: [ScanItem] { filtered.filter { $0.assessment.canBatchSelect && !preferences.isIgnored($0.url) } }
    var unselectedRecommendations: [ScanItem] { visibleBatchSelectableItems.filter { $0.assessment.disposition == .priority && !isSelectedForReview($0) } }
    var visibleSelectableItems: [ScanItem] { filtered.filter { !preferences.isIgnored($0.url) } }
    var allVisibleSelected: Bool { !visibleSelectableItems.isEmpty && visibleSelectableItems.allSatisfy(isSelectedForReview) }
    func allScopeItems(_ scope: CleanupScope) -> [ScanItem] {
        items.filter { scope.contains($0) && !preferences.isIgnored($0.url) }
    }
    func openCleanup(_ scope: CleanupScope) {
        clearCleanupOwner(); selectCleanupScope(scope); section = .results
    }
    func clearCurrentSelection() { selected.subtract(currentSelection.map(\.id)) }
    var cleanupLocation: CleanupLocation { CleanupLocation(scope: cleanupScope, disposition: disposition, category: category, group: groupFilter, search: search, minimum: minimumFilter, onlySelected: onlySelected, presentation: presentation, ordering: ordering) }
    var canReturnCleanup: Bool { !cleanupTrail.isEmpty || storageCleanup != nil }
    var currentSelection: [ScanItem] { filtered.filter(isSelectedForReview) }
    var currentSelectionBytes: Int64 { currentSelection.reduce(0) { $0 + $1.bytes } }
    var otherSelectionCount: Int { selectedItems.count - currentSelection.count }
    var cleanupGroupTitle: String? { groupFilter.flatMap { id in cleanupItems.first { $0.assessment.groupID == id }?.assessment.displayGroup } }
    func scopeItems(_ scope: CleanupScope) -> [ScanItem] {
        cleanupItems.filter { scope.contains($0) && !preferences.isIgnored($0.url) && matchesCleanupOwner($0) }
    }
    func matchesCleanupOwner(_ item: ScanItem) -> Bool {
        storageCleanup != nil || cleanupOwnerFilter == nil || ownerResolver.cleanupOwner(item).id == cleanupOwnerFilter
    }
    func selectFirstPopulatedCleanupScope() {
        let cutoff = Date().addingTimeInterval(-Double(unusedFilter) * 86_400)
        let available = Set(cleanupItems.lazy.filter { !self.preferences.isIgnored($0.url) && self.matchesCleanupOwner($0) && (self.unusedFilter == 0 || self.lastActivity($0) < cutoff) }.map { CleanupScope.forAssessment($0.assessment) })
        selectCleanupScope(CleanupScope.allCases.first(where: available.contains) ?? .recommended)
    }
    func selectCleanupScope(_ scope: CleanupScope) {
        clearCleanupFilters(); cleanupScope = scope; disposition = nil
    }
    func clearCleanupFilters() {
        category = nil; groupFilter = nil; search = ""; minimumFilter = 0; onlySelected = false; presentation = .groups; cleanupTrail = []
    }
    /// The "clear filters" button also leaves the long-unused view; switching scope keeps it.
    func clearAllCleanupFilters() { clearCleanupFilters(); unusedFilter = 0; if ordering == .leastUsed { ordering = .size } }
    func returnCleanup() {
        guard !busy else { return }
        guard let previous = cleanupTrail.popLast() else {
            if storageCleanup != nil {
                clearCleanupOwner()
                stoppedCleanupScan = nil
                section = .storage
            }
            return
        }
        cleanupScope = previous.scope; disposition = previous.disposition; category = previous.category
        groupFilter = previous.group; search = previous.search; minimumFilter = previous.minimum
        onlySelected = previous.onlySelected; presentation = previous.presentation; ordering = previous.ordering
    }
    func prepareCurrentReview() {
        guard !busy else { return }
        review = currentSelection; reviewConfirmed = false
        reviewScopeTitle = [cleanupOwnerTitle, cleanupScope?.rawValue, cleanupGroupTitle].compactMap { $0 }.joined(separator: " / ")
        if !review.isEmpty { showingReview = true }
    }
    var storageLocation: StorageLocation { StorageLocation(mode: storageMode, folder: storageFolder, owner: storageOwnerFilter, ownerTitle: storageOwnerTitle, search: storageSearch, ordering: storageOrdering) }
    var canReturnStorage: Bool { !storageTrail.isEmpty }
    func returnStorage() {
        guard let previous = storageTrail.popLast() else { return }
        storageMode = previous.mode; storageFolder = previous.folder; storageOwnerFilter = previous.owner
        storageOwnerTitle = previous.ownerTitle; storageSearch = previous.search; storageOrdering = previous.ordering
        storageItems = []; storageTotalMatches = 0; scheduleStorageQuery()
    }
    func storageUp() {
        guard let folder = storageFolder else { return }
        let scope = storageInfo?.roots.filter { SafetyPolicy.within(folder, $0.url) }.max { $0.url.path.count < $1.url.path.count }
        if folder.path == scope?.url.path { browseStorage(nil) }
        else {
            // Physical parents can be shared by several applications. Leave the
            // owner filter when going up, and keep it in history for Back.
            storageTrail.append(storageLocation)
            storageOwnerFilter = nil; storageOwnerTitle = nil
            storageFolder = folder.deletingLastPathComponent(); storageSearch = ""
            storageItems = []; storageTotalMatches = 0; scheduleStorageQuery()
        }
    }
    func changeStorageMode(_ mode: StoragePresentation) {
        storageTrail.append(storageLocation)
        storageMode = mode; storageOwnerFilter = nil; storageOwnerTitle = nil; storageFolder = nil; storageSearch = ""
        storageItems = []; storageTotalMatches = 0; scheduleStorageQuery()
    }
}
