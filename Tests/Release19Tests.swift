import Foundation
import Darwin

/// 1.9 additions: Trash usage after cleanup, the long-unused large-file view and the
/// in-app update check. None of them may weaken selection or confirmation rules.
@main struct Release19Tests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let fm = FileManager.default
        let base = URL(fileURLWithPath: "/Users/Shared").appendingPathComponent("qingsweep-r19-" + UUID().uuidString)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ name: String) {
            guard value() else { fputs("FAIL: \(name)\n", stderr); exit(1) }
            count += 1
            print("PASS: \(name)")
        }
        @discardableResult func file(_ path: String, bytes: Int, daysOld: Double = 0) throws -> URL {
            let url = base.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0x19, count: bytes).write(to: url)
            try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -daysOld * 86_400)], ofItemAtPath: url.path)
            return url
        }

        // Trash usage: measured, never emptied.
        try file(".Trash/old-installer.dmg", bytes: 300_000)
        try file(".Trash/Folder/a.bin", bytes: 200_000)
        let linkSource = try file(".Trash/Folder/b.bin", bytes: 100_000)
        try fm.linkItem(at: linkSource, to: base.appendingPathComponent(".Trash/Folder/b-link.bin"))
        try fm.createSymbolicLink(at: base.appendingPathComponent(".Trash/outside-link"), withDestinationURL: URL(fileURLWithPath: "/System"))
        try "x".write(to: base.appendingPathComponent(".Trash/.DS_Store"), atomically: true, encoding: .utf8)
        let usage = TrashUsage.measure(TrashUsage.folders(home: base, records: []))
        check(usage != nil && usage!.complete, "Trash usage is measured completely")
        check(usage!.items == 3, "top-level Trash items are counted without Finder metadata (got \(usage!.items))")
        check(usage!.bytes >= 600_000 && usage!.bytes < 1_000_000, "hard links count once and links are not followed (got \(usage!.bytes))")
        check(fm.fileExists(atPath: base.appendingPathComponent(".Trash/old-installer.dmg").path), "measuring never removes Trash contents")
        check(TrashUsage.measure([base.appendingPathComponent("missing/.Trash")]) == nil, "an unreadable Trash reports no number instead of zero")
        let timed = TrashUsage.measure([base.appendingPathComponent(".Trash")], timeLimit: -1)
        check(timed?.complete == false, "a measurement that runs out of time is marked as a lower bound")
        check(timed!.summary.contains("至少"), "a partial measurement is worded as a minimum")
        let volumeRecord = TrashRecord(id: UUID(), original: URL(fileURLWithPath: "/Volumes/Work/a.mov"), trashed: URL(fileURLWithPath: "/Volumes/Work/.Trashes/\(getuid())/a.mov"), bytes: 1, date: Date(), stamp: nil)
        let otherUser = TrashRecord(id: UUID(), original: URL(fileURLWithPath: "/Volumes/Work/b.mov"), trashed: URL(fileURLWithPath: "/Volumes/Work/.Trashes/0/b.mov"), bytes: 1, date: Date(), stamp: nil)
        let folders = TrashUsage.folders(home: base, records: [volumeRecord, volumeRecord, otherUser], userID: getuid())
        check(folders.map(\.path) == [base.appendingPathComponent(".Trash").path, "/Volumes/Work/.Trashes/\(getuid())"], "external volume Trash folders come only from this user's records")
        var outcome = OperationOutcome(title: "清理结果", completed: 1, bytes: 1, errors: [])
        check(outcome.trashUsage == nil && !outcome.trashMeasured, "a new outcome starts with the Trash still being measured")
        outcome.trashUsage = usage; outcome.trashMeasured = true
        check(outcome.trashUsage?.summary.contains("清空废纸篓后才会释放") == true, "the result explains that emptying the Trash frees the space")

        // Long-unused large files.
        let model = AppModel(home: base, loadSavedScan: false, startTimer: false)
        func item(_ url: URL, _ category: FileCategory, _ disposition: CleanupDisposition) -> ScanItem {
            let assessment = FileAssessment(category: category, disposition: disposition, owner: "Fixture", group: category.rawValue, reason: "Fixture", evidence: "Fixture", ruleID: "fixture")
            return ScanItem(url: url, root: base.appendingPathComponent("Documents"), stamp: FileStamp.read(url)!, assessment: assessment)
        }
        let ancient = item(try file("Documents/ancient.mov", bytes: 90_000, daysOld: 800), .video, .protected)
        let old = item(try file("Documents/old.mov", bytes: 80_000, daysOld: 400), .video, .protected)
        let recent = item(try file("Documents/recent.mov", bytes: 70_000, daysOld: 20), .video, .protected)
        let installer = item(try file("Documents/old.dmg", bytes: 60_000, daysOld: 500), .installer, .priority)
        model.items = [ancient, old, recent, installer]
        model.showDisposition(nil)
        model.unusedFilter = 365
        check(Set(model.filtered.map(\.id)) == Set([ancient.id, old.id, installer.id]), "the unused filter keeps only files idle for the chosen time")
        model.ordering = .leastUsed
        check(model.filtered.map(\.id) == [ancient.id, installer.id, old.id], "least-used ordering puts the longest-idle files first")
        model.unusedFilter = 730
        check(model.filtered.map(\.id) == [ancient.id], "a longer threshold narrows the list")
        check(model.lastActivity(recent) >= recent.modified, "activity is never earlier than the modification date")
        model.unusedFilter = 180
        model.selectPriority()
        check(model.selected == Set([installer.id]), "recommendations in the unused view still exclude personal media")
        model.selected.removeAll()
        model.selectCleanupScope(.protected)
        check(model.unusedFilter == 180, "switching scope keeps the unused view")
        model.clearAllCleanupFilters()
        check(model.unusedFilter == 0 && model.ordering != .leastUsed, "clearing filters leaves the unused view")
        model.applyUnusedView(ScanConfiguration(roots: [base], label: "长期未用的大文件", minimumBytes: 100_000_000, unusedDays: 180))
        check(model.unusedFilter == 180 && model.ordering == .leastUsed, "the unused scan opens filtered and ordered by idle time")
        model.applyUnusedView(ScanConfiguration(roots: [base], label: "大文件", minimumBytes: 100_000_000))
        check(model.unusedFilter == 0 && model.ordering == .size, "an ordinary scan resets the unused view")
        check(FileActivity.title(days: 180) == "6 个月以上未用" && FileActivity.title(days: 365) == "一年以上未用", "threshold titles read naturally")

        let policy = SafetyPolicy(home: base)
        let legacy = try JSONDecoder().decode(ScanConfiguration.self, from: Data(#"{"roots":["file:///Users/Shared/x/"],"label":"常用位置","minimumBytes":1000000}"#.utf8))
        check(legacy.unusedDays == nil, "saved scans from earlier versions still decode")
        let unusedConfig = ScanConfiguration(roots: [base.appendingPathComponent("Documents")], label: "长期未用的大文件", minimumBytes: 100_000_000, unusedDays: 180)
        let roundTrip = try JSONDecoder().decode(ScanConfiguration.self, from: JSONEncoder().encode(unusedConfig))
        check(roundTrip == unusedConfig && roundTrip.isValid(policy: policy), "the unused view survives relaunch")
        check(!ScanConfiguration(roots: [base], label: "x", minimumBytes: 0, unusedDays: -5).isValid(policy: policy), "a damaged unused threshold is rejected")

        // Update check: parsing and comparison only; tests never reach the network.
        check(UpdateCheck.version(fromTag: "v1.8.8-beta") == "1.8.8" && UpdateCheck.version(fromTag: "1.9") == "1.9", "release tags yield dotted versions")
        check(UpdateCheck.version(fromTag: "nightly") == nil, "tags without a version are ignored")
        check(UpdateCheck.isNewer("1.8.10", than: "1.8.9") && !UpdateCheck.isNewer("1.8.7", than: "1.8.7") && !UpdateCheck.isNewer("1.8", than: "1.8.0") && UpdateCheck.isNewer("2.0", than: "1.99.9"), "versions compare numerically")
        let json = #"""
        [{"tag_name":"v1.8.7-beta","name":"Stowfin 1.8.7 Beta","html_url":"https://github.com/FishyJ10312/Stowfin/releases/tag/v1.8.7-beta","draft":false,"prerelease":true},
         {"tag_name":"v1.9.0-beta","name":"Stowfin 1.9.0 Beta","html_url":"https://github.com/FishyJ10312/Stowfin/releases/tag/v1.9.0-beta","draft":false,"prerelease":true},
         {"tag_name":"v2.0.0","name":"draft","html_url":"https://github.com/FishyJ10312/Stowfin/releases/tag/untagged-1","draft":true,"prerelease":false},
         {"tag_name":"v9.9.9","name":"elsewhere","html_url":"https://example.com/FishyJ10312/Stowfin/releases/tag/v9.9.9","draft":false,"prerelease":false}]
        """#
        let newer = try UpdateCheck.newerRelease(than: "1.8.7", in: Data(json.utf8))
        check(newer?.version == "1.9.0" && newer?.displayVersion == "1.9.0 Beta", "the newest published release is offered")
        check(try UpdateCheck.newerRelease(than: "1.9.0", in: Data(json.utf8)) == nil, "drafts and links outside the release pages are ignored")
        check((try? UpdateCheck.latest(fromJSON: Data("{\"message\":\"rate limited\"}".utf8))) == nil, "an API error body is not mistaken for a release")

        let suite = "QingSweep.Release19Tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var requests = 0
        let checker = UpdateChecker(defaults: defaults, currentVersion: "1.8.7") { requests += 1; return Data(json.utf8) }
        check(!checker.automatic, "automatic update checks are off by default")
        checker.checkAutomaticallyIfDue()
        check(requests == 0 && checker.state == .idle, "with automatic checks off, nothing is requested")
        checker.check()
        for _ in 0..<100 where checker.state == .checking { try await Task.sleep(nanoseconds: 10_000_000) }
        check(requests == 1 && checker.availableRelease?.version == "1.9.0" && checker.showingResult, "a manual check reports the newer release")
        checker.showingResult = false
        checker.automatic = true
        for _ in 0..<50 { try await Task.sleep(nanoseconds: 10_000_000) }
        check(requests == 1, "turning on automatic checks does not repeat a check made today")
        defaults.set(Date(timeIntervalSinceNow: -2 * 86_400), forKey: UpdateChecker.lastCheckKey)
        checker.checkAutomaticallyIfDue()
        for _ in 0..<100 where checker.state == .checking { try await Task.sleep(nanoseconds: 10_000_000) }
        check(requests == 2 && !checker.showingResult, "a due automatic check runs quietly without a dialog")
        let failing = UpdateChecker(defaults: defaults, currentVersion: "1.8.7") { throw URLError(.notConnectedToInternet) }
        failing.check()
        for _ in 0..<100 where failing.state == .checking { try await Task.sleep(nanoseconds: 10_000_000) }
        check(failing.state == .failed && failing.availableRelease == nil, "an offline check fails without offering a download")
        print("\(count) release 1.9 checks passed")
    }
}
