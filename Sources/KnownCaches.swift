import Foundation

/// Rebuildable caches that live outside ~/Library/Caches.
///
/// SafetyPolicy keeps hidden folders and Library data closed. Each entry below opens
/// one exact subtree for one rule, and nothing else: ~/.npm/_cacache is readable,
/// ~/.npm/_logs and ~/.npmrc are not; Slack's Cache folder is readable, its cookies
/// and databases are not. Files inside an opened subtree still have to match the
/// rule's known cache structure before they become batch-selectable; anything else
/// in the subtree is reported as "purpose not confirmed".
struct KnownCacheLocation: Equatable {
    enum Layout: Equatable {
        case npm, cargo, gradle, simulator
        case chromiumCache, chromiumCodeCache, chromiumGPUCache, electronCachedData
    }
    let ruleID: String
    let owner: String
    let group: String
    /// Path relative to the home folder.
    let path: String
    let layout: Layout
    var blockingAppIDs: [String] = []
    var sourceURL: String? = nil
}

enum KnownCacheLocations {
    private static func chromium(_ ruleID: String, _ owner: String, _ base: String, _ appIDs: [String], source: String? = nil) -> [KnownCacheLocation] {
        [("Cache", KnownCacheLocation.Layout.chromiumCache), ("Code Cache", .chromiumCodeCache), ("GPUCache", .chromiumGPUCache)].map {
            KnownCacheLocation(ruleID: ruleID, owner: owner, group: owner + " 网页与代码缓存", path: base + "/" + $0.0, layout: $0.1, blockingAppIDs: appIDs, sourceURL: source)
        }
    }
    static let slackIDs = ["com.tinyspeck.slackmacgap"]
    static let vscodeIDs = ["com.microsoft.VSCode"]
    static let discordIDs = ["com.hnc.Discord"]
    static let simulatorIDs = ["com.apple.iphonesimulator", "com.apple.dt.Xcode"]
    static let gradleIDs = ["com.google.android.studio", "com.jetbrains.intellij", "com.jetbrains.intellij.ce"]

    static let all: [KnownCacheLocation] = [
        KnownCacheLocation(ruleID: "cache-npm", owner: "npm", group: "npm 下载缓存", path: ".npm/_cacache", layout: .npm, sourceURL: "https://docs.npmjs.com/cli/commands/npm-cache"),
        KnownCacheLocation(ruleID: "cache-cargo", owner: "Rust / Cargo", group: "Cargo 下载缓存", path: ".cargo/registry/cache", layout: .cargo, sourceURL: "https://doc.rust-lang.org/cargo/guide/cargo-home.html"),
        KnownCacheLocation(ruleID: "cache-gradle", owner: "Gradle", group: "Gradle 依赖缓存", path: ".gradle/caches/modules-2/files-2.1", layout: .gradle, blockingAppIDs: gradleIDs, sourceURL: "https://docs.gradle.org/current/userguide/dependency_caching.html"),
        KnownCacheLocation(ruleID: "cache-simulator", owner: "iOS 模拟器", group: "模拟器系统缓存", path: "Library/Developer/CoreSimulator/Caches", layout: .simulator, blockingAppIDs: simulatorIDs),
    ]
    + chromium("cache-slack", "Slack", "Library/Application Support/Slack", slackIDs)
    + chromium("cache-slack", "Slack", "Library/Containers/com.tinyspeck.slackmacgap/Data/Library/Application Support/Slack", slackIDs)
    + chromium("cache-vscode", "Visual Studio Code", "Library/Application Support/Code", vscodeIDs)
    + [KnownCacheLocation(ruleID: "cache-vscode", owner: "Visual Studio Code", group: "Visual Studio Code 网页与代码缓存", path: "Library/Application Support/Code/CachedData", layout: .electronCachedData, blockingAppIDs: vscodeIDs)]
    + chromium("cache-discord", "Discord", "Library/Application Support/discord", discordIDs)

    static func roots(home: URL) -> [URL] {
        all.map { home.appendingPathComponent($0.path) }
    }
    /// Opened roots that currently exist as real directories (not links).
    static func existingRoots(home: URL) -> [URL] {
        roots(home: home).filter { FileStamp.read($0)?.isDirectory == true }
    }
    /// The entry whose subtree contains `url`, with the path below that subtree.
    static func match(_ url: URL, home: URL) -> (location: KnownCacheLocation, relative: String)? {
        let path = url.standardizedFileURL.path
        for location in all {
            let root = home.standardizedFileURL.appendingPathComponent(location.path).path
            guard path.hasPrefix(root + "/") else { continue }
            return (location, String(path.dropFirst(root.count + 1)))
        }
        return nil
    }
    /// Running processes that use a rule's cache, matched from `ps -axo pid=,comm=,args=` lines.
    static func maintenanceRule(forProcessLine line: String, executable: String, rules: Set<String>) -> (rule: String, title: String)? {
        let name = executable.lowercased()
        if rules.contains("cache-npm"), ["node", "npm", "npx"].contains(name),
           line.range(of: #"(?:^|\s|/)(?:npm|npx|npm-cli\.js|npx-cli\.js)(?:\s|$)"#, options: .regularExpression) != nil {
            return ("cache-npm", "npm 安装任务")
        }
        if rules.contains("cache-cargo"), name == "cargo" || name.hasPrefix("cargo-") || name == "rustc" || name == "rustup" {
            return ("cache-cargo", "Cargo 编译任务")
        }
        if rules.contains("cache-gradle"), name == "gradle" || line.contains("GradleDaemon") || line.contains("GradleWrapperMain") || line.contains("org.gradle.launcher") {
            return ("cache-gradle", "Gradle 后台进程")
        }
        if rules.contains("cache-simulator"), name == "launchd_sim" || name == "simulator" {
            return ("cache-simulator", "正在运行的模拟器")
        }
        return nil
    }
}
