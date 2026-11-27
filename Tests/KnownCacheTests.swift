import Foundation
import Darwin

/// Allowlisted cache locations outside ~/Library/Caches: each rule opens one exact
/// subtree, files there must still match the rule's layout, and everything around
/// those subtrees (hidden folders, credentials, app data) stays closed.
@main struct KnownCacheTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let fm = FileManager.default
        let base = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("testdata-known-" + UUID().uuidString)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let policy = SafetyPolicy(home: base)
        var assertions = 0
        func check(_ value: @autoclosure () -> Bool, _ name: String) {
            guard value() else { fputs("FAIL: \(name)\n", stderr); exit(1) }
            assertions += 1
            print("PASS: \(name)")
        }
        let old = Date(timeIntervalSinceNow: -40 * 86_400)
        @discardableResult func file(_ path: String, bytes: Int = 1_100_000, age: Date? = old) throws -> URL {
            let url = base.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0x4b, count: bytes).write(to: url)
            if let age { try fm.setAttributes([.modificationDate: age], ofItemAtPath: url.path) }
            return url
        }
        let sha = String(repeating: "ab", count: 62)
        let npmContent = try file(".npm/_cacache/content-v2/sha512/12/34/" + sha)
        let npmIndex = try file(".npm/_cacache/index-v5/56/78/" + String(repeating: "cd", count: 30), bytes: 4096)
        let npmTemp = try file(".npm/_cacache/tmp/upload-123")
        let npmHidden = try file(".npm/_cacache/.lock/content")
        let npmLog = try file(".npm/_logs/2026-11-01-debug-0.log")
        let npmrc = try file(".npmrc", bytes: 100)
        let crate = try file(".cargo/registry/cache/index.crates.io-6f17d22bba15001f/serde-1.0.200.crate")
        let crateSource = try file(".cargo/registry/src/index.crates.io-6f17d22bba15001f/serde-1.0.200/src/lib.rs")
        let cargoCredentials = try file(".cargo/credentials.toml", bytes: 200)
        let gradleJar = try file(".gradle/caches/modules-2/files-2.1/com.squareup.okio/okio/3.9.0/4f1c3a1b2c3d4e5f60718293a4b5c6d7e8f90a1b/okio-3.9.0.jar")
        let gradleRecent = try file(".gradle/caches/modules-2/files-2.1/org.example/lib/1.0/0a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d/lib-1.0.jar", age: Date(timeIntervalSinceNow: -10 * 86_400))
        let gradleOdd = try file(".gradle/caches/modules-2/files-2.1/org.example/lib/1.0/notes.bin")
        let gradleProperties = try file(".gradle/gradle.properties", bytes: 200)
        let simulator = try file("Library/Developer/CoreSimulator/Caches/dyld/24A335/com.apple.CoreSimulator.SimRuntime.iOS-18-0.22A3351/dyld_sim_shared_cache_arm64e.01")
        let simulatorDevice = try file("Library/Developer/CoreSimulator/Devices/ABCD/data/Containers/app.bin")
        let slackCache = try file("Library/Application Support/Slack/Cache/Cache_Data/0123456789abcdef_0")
        let slackCode = try file("Library/Application Support/Slack/Code Cache/js/fedcba9876543210_0")
        let slackGPU = try file("Library/Application Support/Slack/GPUCache/data_1")
        let slackCookies = try file("Library/Application Support/Slack/Cookies")
        let slackStorage = try file("Library/Application Support/Slack/Local Storage/leveldb/000003.log")
        let slackStore = try file("Library/Containers/com.tinyspeck.slackmacgap/Data/Library/Application Support/Slack/Cache/Cache_Data/00aa11bb22cc33dd_0")
        let vscodeData = try file("Library/Application Support/Code/CachedData/" + String(repeating: "a1", count: 20) + "/chrome/js/abc.code")
        let vscodeSettings = try file("Library/Application Support/Code/User/settings.json", bytes: 300)
        let discord = try file("Library/Application Support/discord/Cache/Cache_Data/a0b1c2d3e4f50617_s")
        let personal = try file(".gradle/caches/modules-2/files-2.1/com.example/assets/1.0/aa11bb22cc33dd44ee55ff66aa77bb88cc99dd00/photo.png")
        let freshNpm = try file(".npm/_cacache/content-v2/sha512/9a/9b/" + sha, age: Date())

        // Policy: exact subtrees open, everything around them stays closed.
        for url in [npmContent, npmIndex, npmTemp, crate, gradleJar, simulator, slackCache, slackCode, slackGPU, slackStore, vscodeData, discord] {
            check(policy.permits(url), "allowlisted cache file is readable: " + url.path.dropFirst(base.path.count + 1))
        }
        for url in [npmHidden, npmLog, npmrc, crateSource, cargoCredentials, gradleProperties, simulatorDevice, slackCookies, slackStorage, vscodeSettings] {
            check(!policy.permits(url), "location outside the allowlist stays closed: " + url.path.dropFirst(base.path.count + 1))
        }
        check(!policy.permits(base.appendingPathComponent(".npm")), "the hidden parent of an allowlisted root is not a scan root")
        check(!policy.permits(base.appendingPathComponent(".ssh/id_ed25519")), "credentials remain protected")
        check(!policy.permits(base.appendingPathComponent("Library/Application Support/Slack")), "the app's data folder is not opened, only its caches")
        check(policy.permits(base.appendingPathComponent(".npm/_cacache")), "allowlisted root can be scanned directly")
        check(!policy.permits(base.appendingPathComponent(".npm/_cacache/content-v2/x.sqlite")), "databases stay protected inside an allowlisted root")
        check(KnownCacheLocations.all.allSatisfy { !$0.path.hasPrefix("/") && !$0.path.contains("..") && !$0.path.hasSuffix("/") }, "allowlist entries are plain home-relative paths")
        check(Set(KnownCacheLocations.all.map(\.path)).count == KnownCacheLocations.all.count, "allowlist entries are unique")
        check(KnownCacheLocations.all.allSatisfy { $0.ruleID.hasPrefix("cache-") }, "every opened subtree is tied to one cache rule")
        check(KnownCacheLocations.all.allSatisfy { location in
            let root = location.path
            return !KnownCacheLocations.all.contains { $0.path != root && $0.path.hasPrefix(root + "/") }
        }, "allowlisted roots do not nest")

        // Classification: structure must match, personal content still wins.
        let classifier = FileClassifier(policy: policy, context: InspectionContext())
        func assess(_ url: URL) -> FileAssessment { classifier.assess(url, stamp: FileStamp.read(url)!) }
        check(assess(npmContent).ruleID == "cache-npm" && assess(npmContent).disposition == .priority && assess(npmContent).canBatchSelect, "npm content is a recommended rebuildable cache")
        check(assess(npmIndex).ruleID == "cache-npm", "npm index entries match the npm rule")
        check(assess(npmTemp).ruleID == "unknown-cache-npm" && !assess(npmTemp).canBatchSelect, "unexpected npm files are not batch-selectable")
        check(assess(crate).ruleID == "cache-cargo" && assess(crate).disposition == .priority, "Cargo .crate downloads match the Cargo rule")
        check(assess(gradleJar).ruleID == "cache-gradle" && assess(gradleJar).disposition == .priority, "old Gradle dependency files are recommended")
        check(assess(gradleRecent).ruleID == "cache-gradle" && assess(gradleRecent).disposition == .manual, "Gradle files used within 30 days need a manual choice")
        check(assess(gradleOdd).ruleID == "unknown-cache-gradle", "Gradle files outside the hash layout are unconfirmed")
        check(assess(personal).category == .photo && assess(personal).disposition == .protected, "personal formats stay protected inside caches")
        check(assess(simulator).ruleID == "cache-simulator" && assess(simulator).blockingAppIDs.contains("com.apple.iphonesimulator"), "simulator caches require Simulator to be closed")
        for url in [slackCache, slackCode, slackGPU, slackStore] {
            let value = assess(url)
            check(value.ruleID == "cache-slack" && value.disposition == .conditional && value.needsClosedApps && value.blockingAppIDs == ["com.tinyspeck.slackmacgap"], "Slack cache requires Slack to quit: " + url.lastPathComponent)
        }
        check(assess(vscodeData).ruleID == "cache-vscode", "VS Code compiled script cache is recognised")
        check(assess(discord).ruleID == "cache-discord", "Discord web cache is recognised")
        check(KnownCacheLocations.all.allSatisfy { location in
            location.ruleID != "cache-slack" && location.ruleID != "cache-vscode" && location.ruleID != "cache-discord" || !location.blockingAppIDs.isEmpty
        }, "every app cache names the app that must be closed")

        // Scanner: the opened roots are scanned like other maintenance caches.
        let roots = KnownCacheLocations.existingRoots(home: base)
        check(roots.count == 10, "existing allowlisted roots are discovered (found \(roots.count))")
        let result = DiskScanner(policy: policy, minimumBytes: 1_000_000, includeSmallKnownCaches: true).scan(roots: roots, cancellation: ScanCancellation()) { _ in }
        let paths = Set(result.items.map(\.id))
        check(paths.contains(npmContent.path) && paths.contains(crate.path) && paths.contains(gradleJar.path) && paths.contains(slackCache.path), "scan lists recognised caches")
        check(paths.contains(npmIndex.path), "small recognised cache entries are included")
        check(!paths.contains(freshNpm.path), "caches modified within 7 days are left alone")
        check(!paths.contains(npmHidden.path), "hidden folders below an allowlisted root are skipped")
        check(!paths.contains(slackCookies.path) && !paths.contains(slackStorage.path) && !paths.contains(vscodeSettings.path), "app data next to caches is never scanned")
        let linkedHome = base.appendingPathComponent("linked")
        try fm.createDirectory(at: linkedHome, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: linkedHome.appendingPathComponent(".npm"), withDestinationURL: base.appendingPathComponent(".npm"))
        let linked = DiskScanner(policy: SafetyPolicy(home: linkedHome), minimumBytes: 0).scan(roots: [linkedHome.appendingPathComponent(".npm/_cacache")], cancellation: ScanCancellation()) { _ in }
        check(linked.items.isEmpty, "an allowlisted root reached through a link is refused")

        // Cleanup execution: processes using a cache block it like an open app.
        let rules: Set<String> = ["cache-npm", "cache-cargo", "cache-gradle", "cache-simulator"]
        check(KnownCacheLocations.maintenanceRule(forProcessLine: "412 node /opt/homebrew/bin/npm install", executable: "node", rules: rules)?.rule == "cache-npm", "running npm install blocks npm cache cleanup")
        check(KnownCacheLocations.maintenanceRule(forProcessLine: "413 node /Users/a/project/server.js", executable: "node", rules: rules) == nil, "an unrelated node process does not block npm cleanup")
        check(KnownCacheLocations.maintenanceRule(forProcessLine: "414 cargo cargo build", executable: "cargo", rules: rules)?.rule == "cache-cargo", "running cargo blocks Cargo cleanup")
        check(KnownCacheLocations.maintenanceRule(forProcessLine: "415 /Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/java -cp gradle-launcher.jar org.gradle.launcher.daemon.bootstrap.GradleDaemon 8.10", executable: "Android", rules: rules)?.rule == "cache-gradle", "a Gradle daemon blocks Gradle cleanup even with spaces in its path")
        check(KnownCacheLocations.maintenanceRule(forProcessLine: "416 launchd_sim launchd_sim", executable: "launchd_sim", rules: rules)?.rule == "cache-simulator", "a booted simulator blocks simulator cache cleanup")
        check(KnownCacheLocations.maintenanceRule(forProcessLine: "417 cargo cargo build", executable: "cargo", rules: ["cache-npm"]) == nil, "process checks only run for selected rules")
        var usage = CleanupUsage()
        usage.maintenance["cache-npm"] = [412]
        let stamp = FileStamp.read(npmContent)!
        let item = ScanItem(url: npmContent, root: base.appendingPathComponent(".npm/_cacache"), stamp: stamp, assessment: assess(npmContent))
        check(usage.blockers(for: item) == [412], "a running npm task blocks the selected npm files")
        let slackItem = ScanItem(url: slackCache, root: base, stamp: FileStamp.read(slackCache)!, assessment: assess(slackCache))
        usage.applications = [CleanupApplication(pid: 900, bundleID: "com.tinyspeck.slackmacgap", name: "Slack", canQuit: true)]
        check(usage.blockers(for: slackItem).contains(900), "a running Slack blocks its cache files")
        print("\(assertions) known cache checks passed")
    }
}
