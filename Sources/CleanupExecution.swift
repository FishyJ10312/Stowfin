import AppKit
import Foundation
import Darwin

struct CleanupApplication: Equatable {
    let pid: Int32
    let bundleID: String?
    let name: String
    let canQuit: Bool
}

struct CleanupUsage {
    var applications: [CleanupApplication] = []
    var openFiles: [String: Set<Int32>] = [:]
    var processNames: [Int32: String] = [:]
    var maintenance: [String: Set<Int32>] = [:]

    func blockers(for item: ScanItem) -> Set<Int32> {
        var pids = openFiles[item.id] ?? []
        let ids = Set(item.assessment.blockingAppIDs)
        pids.formUnion(applications.filter { app in
            guard let id = app.bundleID else { return false }
            // Exact bundle identifiers only; shared vendor folders never identify one app.
            let isMaintenance = [.cache, .otherCache, .log].contains(item.category)
            let exactDirectory = isMaintenance && ["Caches", "Logs"].contains { directory in
                item.url.path.contains("/Library/" + directory + "/" + id + "/")
            }
            return ids.contains(id) || exactDirectory
        }.map(\.pid))
        if item.assessment.needsClosedApps { pids.formUnion(maintenance[item.assessment.ruleID] ?? []) }
        return pids
    }
    func name(_ pid: Int32) -> String { applications.first { $0.pid == pid }?.name ?? processNames[pid] ?? "进程 \(pid)" }
}

/// The only replaceable boundary is the operating system's process lifecycle.
@MainActor protocol CleanupApplicationEnvironment {
    func usage(for items: [ScanItem]) async throws -> CleanupUsage
    func requestQuit(_ app: CleanupApplication) -> Bool
}

struct CleanupExecutionResult {
    var trash = TrashResult()
    var closedApplications: [String] = []
    var cancelled = false
}

enum CleanupPreparationError: LocalizedError {
    case usageUnavailable, cancelled
    var errorDescription: String? {
        switch self {
        case .usageUnavailable: return "无法检查文件占用，本次未清理。请稍后重试。"
        case .cancelled: return "已停止清理。"
        }
    }
}

@MainActor final class CleanupExecutor {
    let environment: CleanupApplicationEnvironment
    let quitTimeout: TimeInterval
    init(environment: CleanupApplicationEnvironment? = nil, quitTimeout: TimeInterval = 10) {
        self.environment = environment ?? SystemCleanupEnvironment(); self.quitTimeout = quitTimeout
    }

    func run(_ items: [ScanItem], policy: SafetyPolicy, consent: ManualCleanupConsent?,
             cancellation: ScanCancellation, retainedCopies:[String:RetainedCopy]=[:], journal: CleanupJournalContext? = nil, progress: @escaping (String) -> Void) async -> CleanupExecutionResult {
        var outcome = CleanupExecutionResult()
        progress("正在检查文件与应用占用")
        // Validate identity and consent before any request to another application.
        let validated = await Task.detached(priority: .utility) { () -> ([ScanItem], [String]) in
            let classifier = FileClassifier(policy: policy, context: InspectionContext.collect(home: policy.home))
            var valid: [ScanItem] = [], errors: [String] = []
            for item in items {
                do {
                    try policy.validate(item)
                    if let keep=retainedCopies[item.id]{guard !items.contains(where:{$0.id==keep.url.path}) else{throw ToolFailure.invalid("保留副本也被选中，本项未清理")};try keep.validate()}
                    var assessment = classifier.assess(item.url, stamp: item.stamp)
                    if assessment.requiresIndividualConfirmation || item.assessment.requiresIndividualConfirmation {
                        guard consent?.permits(item) == true else { throw SweepError.protectedContent }
                    }
                    assessment.blockingAppIDs = Array(Set(assessment.blockingAppIDs + item.assessment.blockingAppIDs))
                    assessment.needsClosedApps = assessment.needsClosedApps || item.assessment.needsClosedApps
                    valid.append(ScanItem(url: item.url, root: item.root, stamp: item.stamp, assessment: assessment))
                } catch { errors.append(item.url.lastPathComponent + "：" + error.localizedDescription) }
            }
            return (valid, errors)
        }.value
        outcome.trash.errors = validated.1
        guard !cancellation.isCancelled else { outcome.cancelled = true; return outcome }
        guard !validated.0.isEmpty else { return outcome }
        do {
            var usage = try await environment.usage(for: validated.0)
            let initial = usage
            let blockers = validated.0.reduce(into: Set<Int32>()) { $0.formUnion(usage.blockers(for: $1)) }
            var requested: [CleanupApplication] = []
            for app in usage.applications where blockers.contains(app.pid) && app.canQuit {
                guard !cancellation.isCancelled else { outcome.cancelled = true; return outcome }
                progress("正在退出 \(app.name)…")
                if environment.requestQuit(app) { requested.append(app) }
            }
            let deadline = Date().addingTimeInterval(quitTimeout)
            if !requested.isEmpty {
                repeat {
                    if cancellation.isCancelled { outcome.cancelled = true; return outcome }
                    try await Task.sleep(nanoseconds: 200_000_000)
                    usage = try await environment.usage(for: validated.0)
                    let active = Set(usage.applications.map(\.pid))
                    let pending = requested.filter { active.contains($0.pid) }
                    if pending.isEmpty { break }
                    progress("等待 \(pending.map(\.name).joined(separator: "、")) 退出；如有保存窗口，请先保存")
                } while Date() < deadline
            }
            if cancellation.isCancelled { outcome.cancelled = true; return outcome }
            // A final fresh snapshot detects a refusal, a restart, or a new file user.
            usage = try await environment.usage(for: validated.0)
            let active = Set(usage.applications.map(\.pid))
            outcome.closedApplications = requested.filter { requestedApp in
                !active.contains(requestedApp.pid) && !usage.applications.contains { current in
                    requestedApp.bundleID != nil && current.bundleID == requestedApp.bundleID
                }
            }.map(\.name)
            var ready: [ScanItem] = []
            var requiredClosedIDs: [String: Set<String>] = [:]
            for item in validated.0 {
                var blockers = usage.blockers(for: item)
                // An app discovered through an open file must fully exit even if it closed that file first.
                let originalApps = initial.applications.filter { initial.blockers(for: item).contains($0.pid) }
                let ids = Set(originalApps.compactMap(\.bundleID) + item.assessment.blockingAppIDs)
                blockers.formUnion(usage.applications.filter { app in
                    active.contains(app.pid) && (originalApps.contains { $0.pid == app.pid } || app.bundleID.map(ids.contains) == true)
                }.map(\.pid))
                if blockers.isEmpty { ready.append(item); requiredClosedIDs[item.id] = ids }
                else {
                    let names = Set(blockers.map { usage.name($0) }).sorted().joined(separator: "、")
                    outcome.trash.errors.append(item.url.lastPathComponent + "：" + names + " 仍在使用，已跳过；保存完成或任务结束后可重试。")
                }
            }
            guard !cancellation.isCancelled else { outcome.cancelled = true; return outcome }
            let closedIDs = requiredClosedIDs
            let moved = await Task.detached(priority: .utility) {
                TrashService(policy: policy).move(ready, manualConsent: consent, cancellation:cancellation, journal:journal, beforeMove: { item in
                    guard !cancellation.isCancelled else { throw CleanupPreparationError.cancelled }
                    try retainedCopies[item.id]?.validate()
                    let ids = closedIDs[item.id] ?? []
                    guard ids.allSatisfy({ NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }) else { throw SweepError.appRunning }
                }) { count in
                    Task { @MainActor in progress("校验并移入废纸篓 \(count) / \(ready.count)") }
                }
            }.value
            outcome.trash.records = moved.records; outcome.trash.errors += moved.errors
            outcome.cancelled = cancellation.isCancelled
        } catch { outcome.trash.errors.append(error.localizedDescription) }
        return outcome
    }
}

@MainActor final class SystemCleanupEnvironment: CleanupApplicationEnvironment {
    func usage(for items: [ScanItem]) async throws -> CleanupUsage {
        let result = try await Task.detached(priority: .utility) { try OpenFileProbe.read(items: items) }.value
        var usage = result
        usage.applications = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }.map { app in
            CleanupApplication(pid: app.processIdentifier, bundleID: app.bundleIdentifier,
                               name: app.localizedName ?? "应用",
                               canQuit: app.activationPolicy == .regular && app.processIdentifier != getpid() && app.bundleIdentifier != "com.apple.finder")
        }
        return usage
    }
    func requestQuit(_ app: CleanupApplication) -> Bool {
        guard app.canQuit, let running = NSRunningApplication(processIdentifier: app.pid),
              running.bundleIdentifier == app.bundleID else { return false }
        return running.terminate()
    }
}

private enum OpenFileProbe {
    static func read(items: [ScanItem]) throws -> CleanupUsage {
        let output = try command("/usr/sbin/lsof", ["-n", "-P", "-F0pcn", "-a", "-u", String(getuid())], allowed: [0, 1])
        let paths = Set(items.map(\.id))
        var result = CleanupUsage(), pid: Int32?
        // NUL fields preserve spaces and newlines in filenames. Only selected paths are retained.
        for raw in output.split(separator: 0) {
            var field = raw
            if field.first == 10 { field = field.dropFirst() }
            guard let tag = field.first else { continue }
            let value = String(decoding: field.dropFirst(), as: UTF8.self)
            if tag == 112 { pid = Int32(value) }
            else if tag == 99, let pid { result.processNames[pid] = value }
            else if tag == 110, let pid, paths.contains(value) { result.openFiles[value, default: []].insert(pid) }
        }
        let rules = Set(items.filter { $0.assessment.needsClosedApps }.map { $0.assessment.ruleID })
        let processRules: Set<String> = ["cache-pip", "cache-homebrew", "cache-npm", "cache-cargo", "cache-gradle", "cache-simulator"]
        if !rules.isDisjoint(with: processRules) {
            let processes = try command("/bin/ps", ["-axo", "pid=,comm=,args="], allowed: [0])
            for line in String(decoding: processes, as: UTF8.self).split(separator: "\n") {
                let parts = line.split(maxSplits: 2, whereSeparator: { $0 == " " || $0 == "\t" })
                guard parts.count == 3, let pid = Int32(parts[0]) else { continue }
                let executable = URL(fileURLWithPath: String(parts[1])).lastPathComponent
                let args = String(parts[2])
                if rules.contains("cache-homebrew"), ["ruby", "brew", "bash", "sh"].contains(executable),
                   args.range(of: #"(?:^|\s|/)(?:brew|brew\.rb)(?:\s|$)"#, options: .regularExpression) != nil {
                    result.maintenance["cache-homebrew", default: []].insert(pid); result.processNames[pid] = "Homebrew 安装任务"
                }
                if rules.contains("cache-pip"), executable.hasPrefix("python") || executable.hasPrefix("pip"),
                   args.range(of: #"(?:^|\s|/)pip(?:[0-9.]+)?(?:\s|$)"#, options: .regularExpression) != nil {
                    result.maintenance["cache-pip", default: []].insert(pid); result.processNames[pid] = "pip 安装任务"
                }
                if let known = KnownCacheLocations.maintenanceRule(forProcessLine: String(line), executable: executable, rules: rules) {
                    result.maintenance[known.rule, default: []].insert(pid); result.processNames[pid] = known.title
                }
            }
        }
        return result
    }

    private static func command(_ executable: String, _ arguments: [String], allowed: Set<Int32>) throws -> Data {
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = output; process.standardError = errors
        try process.run()
        let group = DispatchGroup(), capture = ProbeCapture()
        group.enter(); DispatchQueue.global(qos: .utility).async { capture.output = output.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter(); DispatchQueue.global(qos: .utility).async { capture.errors = errors.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        let deadline = Date().addingTimeInterval(6)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning {
            // This is our own bounded probe, never a user's application.
            process.terminate(); Thread.sleep(forTimeInterval: 0.1)
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            group.wait(); throw CleanupPreparationError.usageUnavailable
        }
        group.wait()
        guard allowed.contains(process.terminationStatus), capture.errors.isEmpty else { throw CleanupPreparationError.usageUnavailable }
        return capture.output
    }
    private final class ProbeCapture: @unchecked Sendable { var output = Data(); var errors = Data() }
}
