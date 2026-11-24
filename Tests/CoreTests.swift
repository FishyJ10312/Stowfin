import Foundation
import Darwin

@main struct CoreTests {
    static func main() throws {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("testdata-" + UUID().uuidString)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let policy = SafetyPolicy(home: base)
        let classifier = FileClassifier(policy: policy, context: InspectionContext())
        let downloads = base.appendingPathComponent("Downloads")
        let cache = base.appendingPathComponent("Library/Caches/TestApp")
        let logs = base.appendingPathComponent("Library/Logs/TestApp")
        let old = Date(timeIntervalSinceNow: -10 * 86_400)
        var assertions = 0
        func check(_ value: @autoclosure () -> Bool, _ name: String) {
            guard value() else { fputs("FAIL: \(name)\n", stderr); exit(1) }
            assertions += 1
            print("PASS: \(name)")
        }
        @discardableResult func file(_ path: String, age: Date? = nil) throws -> URL {
            let url = base.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0x51, count: 1_100_000).write(to: url)
            if let age { try fm.setAttributes([.modificationDate: age], ofItemAtPath: url.path) }
            return url
        }
        let normal = try file("Downloads/example.zip")
        let oldCache = try file("Library/Caches/TestApp/old.cache", age: old)
        let freshCache = try file("Library/Caches/TestApp/fresh.cache")
        let oldLog = try file("Library/Logs/TestApp/old.log", age: old)
        let secret = try file("Library/Application Support/data.txt")
        _ = try file("Downloads/Family.photoslibrary/original.jpg")
        _ = try file("Downloads/App.app/Contents/large.bin")
        _ = try file("Downloads/private.lrcat")
        _ = try file("Downloads/private.sqlite")
        _ = try file("Downloads/.hidden/secret.bin")
        _ = try file("Downloads/inprogress.crdownload")
        let linked = try file("Downloads/hardlink-a.bin")
        try fm.linkItem(at: linked, to: downloads.appendingPathComponent("hardlink-b.bin"))
        try fm.createSymbolicLink(at: downloads.appendingPathComponent("secret-link"), withDestinationURL: secret)
        try fm.createSymbolicLink(at: downloads.appendingPathComponent("folder-link"), withDestinationURL: base.appendingPathComponent("Library/Application Support"))
        let scanner = DiskScanner(policy: policy, minimumBytes: 1_000_000)
        let result = scanner.scan(roots: [downloads, downloads, cache, logs], cancellation: ScanCancellation()) { _ in }
        let paths = Set(result.items.map(\.id))
        check(paths == Set([normal.path, oldCache.path, oldLog.path]), "only eligible files; exclude packages, secrets, links, databases, recent caches, hidden and partial downloads")
        check(!paths.contains(freshCache.path), "recent caches excluded")
        check(result.items.count == 3, "overlapping roots do not double count")
        check(result.items.allSatisfy { $0.bytes > 0 }, "allocated bytes measured")
        check(!policy.permits(URL(fileURLWithPath: "/System/Library")), "system paths blocked")
        check(!policy.permits(secret), "application data protected")
        check(!policy.permits(base.appendingPathComponent(".ssh/key")), "credentials and hidden folders protected")
        check(!SafetyPolicy.within(base.appendingPathComponent("Downloads-copy/file"), downloads), "path boundary enforced")
        let denied = scanner.scan(roots: [secret.deletingLastPathComponent()], cancellation: ScanCancellation()) { _ in }
        check(denied.items.isEmpty && !denied.issues.isEmpty, "protected scan roots explain rejection")
        let token = ScanCancellation(); token.cancel()
        let cancelled = scanner.scan(roots: [downloads], cancellation: token) { _ in }
        check(cancelled.cancelled && cancelled.items.isEmpty, "scan cancellation")
        let limited = DiskScanner(policy: policy, minimumBytes: 1_000_000, limit: 1).scan(roots: [downloads, cache], cancellation: ScanCancellation()) { _ in }
        check(limited.limited && limited.items.count == 1, "bounded candidate list")
        let ignoredFolder = DiskScanner(policy: policy, minimumBytes: 1_000_000, excludedRoots: [cache]).scan(roots: [downloads, cache, logs], cancellation: ScanCancellation()) { _ in }
        check(Set(ignoredFolder.items.map(\.id)) == Set([normal.path, oldLog.path]), "ignored folder omitted while other roots remain")
        let ignoredFile = DiskScanner(policy: policy, minimumBytes: 1_000_000, excludedRoots: [normal]).scan(roots: [downloads], cancellation: ScanCancellation()) { _ in }
        check(ignoredFile.items.isEmpty, "individual ignored file omitted")
        let siblingExclusion = DiskScanner(policy: policy, minimumBytes: 1_000_000, excludedRoots: [downloads.appendingPathComponent("example")]).scan(roots: [downloads], cancellation: ScanCancellation()) { _ in }
        check(siblingExclusion.items.contains { $0.id == normal.path }, "ignore uses directory boundary rather than name prefix")
        let original = result.items.first { $0.id == normal.path }!
        try policy.validate(original)
        check(true, "unchanged file validates")
        try Data(repeating: 0x42, count: 1_100_001).write(to: normal)
        do { try policy.validate(original); check(false, "changed file blocked") } catch { check(true, "changed file blocked") }
        let changedTrash = TrashService(policy: policy).move([original])
        check(changedTrash.records.isEmpty && changedTrash.errors.count == 1 && fm.fileExists(atPath: normal.path), "changed file is not trashed")
        let switchFile = try file("Downloads/switch/item.bin")
        let switchItem = ScanItem(url: switchFile, root: downloads, stamp: FileStamp.read(switchFile)!, assessment: classifier.assess(switchFile, stamp: FileStamp.read(switchFile)!))
        let folder = switchFile.deletingLastPathComponent()
        let moved = downloads.appendingPathComponent("moved")
        try fm.moveItem(at: folder, to: moved)
        try fm.createSymbolicLink(at: folder, withDestinationURL: moved)
        do { try policy.validate(switchItem); check(false, "symlink replacement blocked") } catch { check(true, "symlink replacement blocked") }
        let cacheName = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() + String(repeating: "f", count: 32)
        let testURL = try file("Library/Caches/pip/http-v2/a/b/c/d/e/" + cacheName + ".body", age: old)
        let item = ScanItem(url: testURL, root: base.appendingPathComponent("Library/Caches"), stamp: FileStamp.read(testURL)!, assessment: classifier.assess(testURL, stamp: FileStamp.read(testURL)!))
        let service = TrashService(policy: policy)
        let trashed = service.move([item])
        check(trashed.errors.isEmpty && trashed.records.count == 1 && !fm.fileExists(atPath: testURL.path), "real macOS Trash integration using disposable fixture only")
        let record = trashed.records[0]
        check(fm.fileExists(atPath: record.trashed.path), "file exists in Trash")
        try Data("do not overwrite".utf8).write(to: testURL)
        do { try service.restore(record); check(false, "restore does not overwrite") } catch { check(true, "restore does not overwrite") }
        try fm.removeItem(at: testURL)
        try service.restore(record)
        check(fm.fileExists(atPath: testURL.path) && !fm.fileExists(atPath: record.trashed.path), "restore returns the file to its original path")
        let restoredData = try Data(contentsOf: testURL)
        check(restoredData == Data(repeating: 0x51, count: 1_100_000), "restored bytes unchanged")
        let context = InspectionContext(applications: [
            InstalledApplication(path: "/Applications/DaVinci Resolve.app", id: "com.blackmagic-design.DaVinciResolve", name: "Resolve", version: "21.1.2", build: "1"),
            InstalledApplication(path: "/Applications/IINA.app", id: "com.colliderli.iina", name: "IINA", version: "1.5.0", build: "1")
        ])
        let semantic = FileClassifier(policy: policy, context: context)
        func classify(_ name: String) -> FileAssessment { semantic.assess(base.appendingPathComponent(name), stamp: FileStamp.read(oldCache)!) }
        check(classify("Downloads/DaVinci_Resolve_Studio_21.1.1_Mac.dmg").disposition == .priority, "older installer compared with installed application")
        check(classify("Downloads/IINA.v1.3.5.dmg").disposition == .priority, "second older installer rule")
        check(classify("Downloads/IINA.v1.5.0.dmg").disposition == .manual, "same-version installer is not mislabeled old")
        let generic = FileClassifier(policy: policy, context: InspectionContext(applications: [
            InstalledApplication(path: "/Applications/Rectangle.app", id: "com.knollsoft.Rectangle", name: "Rectangle", version: "0.85", build: "1"),
            InstalledApplication(path: "/Applications/Firefox.app", id: "org.mozilla.firefox", name: "Firefox", version: "132.0", build: "1"),
            InstalledApplication(path: "/Applications/Visual Studio Code.app", id: "com.microsoft.VSCode", name: "Code", version: "1.95.3", build: "1"),
            InstalledApplication(path: "/Applications/Notion.app", id: "notion.id", name: "Notion", version: "4.0.0", build: "1"),
            InstalledApplication(path: "/Applications/Unversioned.app", id: "example.unversioned", name: "Unversioned", version: "", build: "")
        ]))
        func classifyGeneric(_ name: String, stamp: FileStamp? = nil) -> FileAssessment { generic.assess(base.appendingPathComponent(name), stamp: stamp ?? FileStamp.read(oldCache)!) }
        let rectangle = classifyGeneric("Downloads/Rectangle0.80.dmg")
        check(rectangle.disposition == .priority && rectangle.ruleID == "old-installer" && rectangle.owner == "Rectangle" && rectangle.canBatchSelect, "older installer found by file-name application name and version")
        check(classifyGeneric("Downloads/Firefox 131.0.3.dmg").disposition == .priority, "space-separated installer version compared with installed application")
        check(classifyGeneric("Downloads/Rectangle0.80.dmg", stamp: FileStamp.read(freshCache)!).disposition == .manual, "recent older installer is not recommended")
        check(classifyGeneric("Downloads/Firefox 132.0.dmg").ruleID == "installed-media" && classifyGeneric("Downloads/Firefox 132.0.dmg").disposition == .manual, "same-version installer stays manual")
        check(classifyGeneric("Downloads/Firefox-133.0-arm64.dmg").disposition == .manual, "newer installer stays manual")
        check(classifyGeneric("Downloads/Notion Calendar-1.0.dmg").ruleID == "unknown-installer", "name prefixes do not match a different installed application")
        check(classifyGeneric("Downloads/Unversioned-1.0.dmg").ruleID == "unknown-installer", "applications without a version are not compared")
        check(classifyGeneric("Downloads/Xcode_16.1.dmg").ruleID == "unknown-installer", "installer for an application that is not installed stays unknown")
        check(classifyGeneric("Downloads/Rectangle0.80.zip").category == .archive, "generic installer matching only applies to dmg and pkg files")
        check(classifyGeneric("Downloads/Project/Rectangle0.80.dmg").disposition == .protected, "project context overrides generic installer matching")
        let goHash = String(repeating: "0123456789abcdef", count: 4)
        let goBuild = classify("Library/Caches/go-build/ab/" + goHash + "-d")
        check(goBuild.ruleID == "cache-go-build" && goBuild.disposition == .priority && goBuild.canBatchSelect, "old Go build cache entries are recommended")
        check(semantic.assess(base.appendingPathComponent("Library/Caches/go-build/ab/" + goHash + "-a"), stamp: FileStamp.read(freshCache)!).disposition == .manual, "recent Go build cache entries are not recommended")
        check(classify("Library/Caches/go-build/README").ruleID == "unknown-cache", "Go cache bookkeeping files stay unverified")
        check(classify("Library/Caches/go-build/ab/" + goHash + "-d.go").disposition == .protected, "Go source names inside the cache stay protected")
        check(classify("Downloads/FilmForever Power Grades.zip").disposition == .protected, "creative archives protected before installer rules")
        check(classify("Downloads/Project/DaVinci_Resolve_Studio_21.1.1_Mac.dmg").disposition == .protected, "project context overrides matching installer")
        check(classify("Downloads/unknown.zip").category == .archive && !classify("Downloads/unknown.zip").canBatchSelect, "unknown zip is not an installer and cannot join bulk selection")
        for ext in ["mp4", "arw", "wav", "cube", "drp", "prproj", "psd", "blend", "swift", "pdf"] {
            check(classify("Downloads/keep." + ext).disposition == .protected, "protected format: " + ext)
        }
        check(classify("Library/Caches/Unidentified/app.bin").disposition == .unknown, "Caches location alone is insufficient evidence")
        check(classify("Library/Logs/App/archive.zip").disposition == .unknown, "archives in Logs remain unverified")
        check(classify("Library/Logs/App/report.pdf").disposition == .protected, "documents in Logs remain protected")
        check(classify("Library/Logs/App/arbitrary.bin").disposition == .unknown, "Logs location alone is insufficient evidence")
        check(classify("Library/Caches/ms-playwright/chromium/browser.bin").disposition == .protected, "cached browser runtime protected")
        check(classify("Library/Caches/Adobe Camera Raw 2/Cache_00_0000000713.dat").disposition == .conditional, "Camera Raw cache requires separate confirmation")
        let fake = FileAssessment(category: .cache, disposition: .priority, owner: "test", group: "test", reason: "test", evidence: "test", ruleID: "forged")
        let creative = try file("Downloads/do-not-clean.mp4")
        let creativeItem = ScanItem(url: creative, root: downloads, stamp: FileStamp.read(creative)!, assessment: fake)
        let blockedCreative = service.move([creativeItem])
        check(blockedCreative.records.isEmpty && blockedCreative.errors.count == 1 && fm.fileExists(atPath: creative.path), "cleanup layer rejects forged material classification")
        let unknown = ScanItem(url: normal, root: downloads, stamp: FileStamp.read(normal)!, assessment: fake)
        let blockedUnknown = service.move([unknown])
        check(blockedUnknown.records.isEmpty && fm.fileExists(atPath: normal.path), "cleanup layer rejects forged unknown-archive classification")
        let projectDirectory = base.appendingPathComponent("Downloads/new-work")
        try fm.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: projectDirectory.appendingPathComponent("package.json"))
        let projectFile = try file("Downloads/new-work/data.bin")
        check(classify("Downloads/new-work/data.bin").disposition == .protected, "project marker protects files with generic extensions")
        let projectItem = ScanItem(url: projectFile, root: downloads, stamp: FileStamp.read(projectFile)!, assessment: fake)
        check(service.move([projectItem]).records.isEmpty && fm.fileExists(atPath: projectFile.path), "cleanup layer enforces project-marker protection")
        let brewRoot = base.appendingPathComponent("Library/Caches/Homebrew")
        let bottle = try file("Library/Caches/Homebrew/downloads/" + String(repeating: "a", count: 64) + "--tool--1.0.bottle.tar.gz", age: old)
        for index in 0..<40 { try fm.createSymbolicLink(at: brewRoot.appendingPathComponent("link-\(index)"), withDestinationURL: bottle) }
        let brewScan = scanner.scan(roots: [brewRoot], cancellation: ScanCancellation()) { _ in }
        check(brewScan.items.contains { $0.url == bottle }, "skipping symlinks must not suppress later sibling directories")
        let snapshot = SystemSnapshot.sample()
        check(snapshot.diskTotal > 0 && snapshot.diskFree >= 0 && snapshot.diskFree <= snapshot.diskTotal, "live disk metrics valid")
        check(snapshot.memoryTotal > 0 && snapshot.memoryUsed > 0 && snapshot.memoryUsed <= snapshot.memoryTotal, "live memory metrics valid")
        check(snapshot.pressure > 0 && !snapshot.processes.isEmpty, "live pressure and process readings")
        print("\n\(assertions) checks passed. No user files were modified.")
    }
}
