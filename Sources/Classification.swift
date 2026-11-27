import Foundation
import AppKit

enum FileCategory: String, CaseIterable, Identifiable, Codable {
    case installer = "应用安装包"
    case cache = "可重建缓存"
    case otherCache = "用途未确认的缓存"
    case log = "日志与诊断"
    case preset = "预设与素材包"
    case video = "视频素材"
    case photo = "照片与 RAW"
    case audio = "音频素材"
    case project = "项目与源代码"
    case document = "文档与学习资料"
    case archive = "用途未确认的压缩包"
    case runtime = "工具运行资源"
    case other = "其他待辨认文件"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .installer: return "安装包"
        case .cache: return "缓存"
        case .otherCache: return "其他缓存"
        case .photo: return "照片与原始图像"
        case .document: return "文档"
        case .archive: return "压缩文件"
        case .runtime: return "工具资源"
        case .other: return "其他文件"
        default: return rawValue
        }
    }
    var symbol: String {
        switch self {
        case .installer: return "shippingbox"
        case .cache, .otherCache: return "internaldrive"
        case .log, .document: return "doc.text"
        case .preset: return "slider.horizontal.3"
        case .video: return "film"
        case .photo: return "photo"
        case .audio: return "waveform"
        case .project: return "folder.badge.gearshape"
        case .archive: return "doc.zipper"
        case .runtime: return "gearshape.2"
        case .other: return "doc"
        }
    }
    var caution: String { self == .installer ? "文件名版本与本机已安装版本分别展示；未执行或挂载安装包。" : "请查看该项的分类依据和处理条件。" }
}

enum CleanupDisposition: String, CaseIterable, Identifiable, Codable {
    case priority = "优先核对"
    case conditional = "退出应用后核对"
    case manual = "进一步确认"
    case protected = "保留并保护"
    case unknown = "用途待确认"
    var id: String { rawValue }
    var title: String {
        switch self { case .priority: return "建议清理"; case .conditional: return "清理前自动退出"; case .manual: return "自行选择"; case .protected, .unknown: return "需自行确认" }
    }
    var canBatchSelect: Bool { self == .priority || self == .conditional || self == .manual }
    var symbol: String {
        switch self { case .priority: return "checklist"; case .conditional: return "pause.circle"; case .manual: return "questionmark.circle"; case .protected: return "questionmark.circle"; case .unknown: return "questionmark.folder" }
    }
}

struct FileAssessment: Codable, Equatable {
    let category: FileCategory
    let disposition: CleanupDisposition
    let owner: String
    let group: String
    let reason: String
    let evidence: String
    let ruleID: String
    var confidence: String = "规则识别"
    var sourceURL: String? = nil
    var blockingAppIDs: [String] = []
    var needsClosedApps = false
    var displayGroup: String {
        if group == category.rawValue { return category.title }
        return group.replacingOccurrences(of: "安装介质待确认", with: "安装包")
            .replacingOccurrences(of: "旧版本安装包", with: "旧安装包")
            .replacingOccurrences(of: "已安装版本的介质", with: "安装包（已安装）")
    }
    var canBatchSelect: Bool { disposition.canBatchSelect && [.installer, .cache, .log].contains(category) }
    var requiresIndividualConfirmation: Bool { !canBatchSelect }
    var groupID: String { category.rawValue + "|" + disposition.rawValue + "|" + group }
}

struct InstalledApplication: Codable {
    let path: String
    let id: String
    let name: String
    let version: String
    let build: String
}

struct InspectionContext {
    var applications: [InstalledApplication] = []
    var runningIDs: Set<String> = []
    var now = Date()
    static func collect(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> InspectionContext {
        var context = InspectionContext()
        let manager = FileManager.default
        for root in [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")] {
            guard let iterator = manager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            while let url = autoreleasepool(invoking: { iterator.nextObject() as? URL }) {
                if iterator.level > 3 { iterator.skipDescendants(); continue }
                if url.pathExtension.lowercased() != "app" { continue }
                iterator.skipDescendants()
                let infoURL = url.appendingPathComponent("Contents/Info.plist")
                guard let stamp = FileStamp.read(infoURL), stamp.isRegular, !stamp.isDataless,
                      let attributes = try? infoURL.resourceValues(forKeys: [.isUbiquitousItemKey]), attributes.isUbiquitousItem != true,
                      let data = try? Data(contentsOf: infoURL),
                      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      let id = plist["CFBundleIdentifier"] as? String else { continue }
                context.applications.append(InstalledApplication(path: url.path, id: id, name: plist["CFBundleDisplayName"] as? String ?? plist["CFBundleName"] as? String ?? url.deletingPathExtension().lastPathComponent, version: plist["CFBundleShortVersionString"] as? String ?? "", build: plist["CFBundleVersion"] as? String ?? ""))
            }
        }
        context.runningIDs = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return context
    }
}

final class FileClassifier {
    let policy: SafetyPolicy
    let context: InspectionContext
    private var projectDirectories: [String: Bool] = [:]
    init(policy: SafetyPolicy, context: InspectionContext) { self.policy = policy; self.context = context }
    private let projectExtensions: Set<String> = ["drp", "dra", "drt", "prproj", "aep", "aepx", "psd", "psb", "afphoto", "afdesign", "blend", "blend1", "c4d", "indd", "ai", "sketch", "fig", "rpp", "als", "logicx", "fcpxml", "xml", "swift", "py", "ipynb", "js", "jsx", "ts", "tsx", "c", "cpp", "h", "java", "rs", "go", "html", "css", "sql", "sh", "ipynb", "sln", "cs", "godot"]
    private let photoExtensions: Set<String> = ["arw", "cr2", "cr3", "nef", "nrw", "raf", "orf", "rw2", "dng", "raw", "srw", "jpg", "jpeg", "heic", "heif", "png", "tif", "tiff", "exr", "webp", "bmp", "gif"]
    private let videoExtensions: Set<String> = ["mov", "mp4", "mxf", "braw", "r3d", "ari", "mkv", "avi", "mts", "m2ts", "webm", "m4v", "insv"]
    private let audioExtensions: Set<String> = ["wav", "aif", "aiff", "flac", "mp3", "m4a", "aac", "ogg", "opus", "mid"]
    private let presetExtensions: Set<String> = ["cube", "3dl", "look", "dctl", "drx", "xmp", "lrtemplate", "lrpreset", "ffx", "mogrt", "prfpset", "setting", "ttf", "otf", "woff", "woff2", "abr", "pat", "asl"]
    private let archiveExtensions: Set<String> = ["zip", "7z", "rar", "tar", "gz", "xz", "bz2", "tgz"]
    private func match(_ pattern: String, _ text: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let result = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        let target = result.numberOfRanges > 1 ? result.range(at: 1) : result.range
        guard let range = Range(target, in: text) else { return nil }
        return String(text[range])
    }
    private func inProject(_ url: URL) -> Bool {
        var directory = url.deletingLastPathComponent()
        while directory.path != "/", directory.path != policy.home.path {
            if let known = projectDirectories[directory.path] {
                if known { return true }
            } else {
                let markers = [".git", ".svn", "Package.swift", "package.json", "pyproject.toml", "Cargo.toml", "project.godot", "CMakeLists.txt"]
                let value = markers.contains { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
                projectDirectories[directory.path] = value
                if value { return true }
            }
            directory.deleteLastPathComponent()
        }
        return false
    }
    private func protectedAssessment(_ category: FileCategory, _ reason: String, _ evidence: String) -> FileAssessment {
        FileAssessment(category: category, disposition: .protected, owner: "你的个人资料", group: category.rawValue, reason: reason, evidence: evidence, ruleID: "protect-" + category.id, confidence: "保守保护")
    }
    func assess(_ url: URL, stamp: FileStamp) -> FileAssessment {
        let path = url.path
        let name = url.lastPathComponent
        let lower = path.lowercased()
        let ext = url.pathExtension.lowercased()
        let cacheRoot = policy.home.appendingPathComponent("Library/Caches")
        let logRoot = policy.home.appendingPathComponent("Library/Logs")
        let inCache = SafetyPolicy.within(url, cacheRoot)
        let rel = inCache ? String(path.dropFirst(cacheRoot.path.count + 1)) : ""
        let days = max(0, Int(context.now.timeIntervalSince1970 - Double(stamp.modifiedSeconds)) / 86_400)
        let ageEvidence = "已 \(days) 天未修改；时间只能说明较旧，不能证明不再需要。"

        // Personal content wins over cache and installer rules, including content inside archives' names.
        if projectExtensions.contains(ext) || inProject(url) || match("(?:^|[/ _-])(project|projects|backup|backups)(?:[/ _.-]|$)|项目|工程|备份", lower) != nil {
            return protectedAssessment(.project, "项目、源代码或备份，请核实是否仍需保留。", "根据文件格式、项目标记或所在目录识别。")
        }
        let knownMediaFormat = videoExtensions.contains(ext) || photoExtensions.contains(ext) || audioExtensions.contains(ext)
        if presetExtensions.contains(ext) || (!knownMediaFormat && match("power[ _-]?grades?|filmforever|colorist factory|grain and textures|editing pack|hudsonfilms|kodak|tropic colour|presets?|footage|素材|预设|调色|胶片|作品集|(?:^|[/ _-])lut(?:[/ _.包-]|$)", lower) != nil) {
            return protectedAssessment(.preset, "预设、素材包或创作资源，请确认用途后决定是否删除。", "素材目录和名称优先于 ZIP、RAR 等压缩格式。")
        }
        if SafetyPolicy.within(url, policy.home.appendingPathComponent("Movies/CacheClip")), ext == "dvcc" {
            return FileAssessment(category: .cache, disposition: .protected, owner: "DaVinci Resolve", group: "达芬奇渲染缓存", reason: "已识别渲染帧缓存；删除后需重新计算，项目归属仍需你确认。", evidence: "位于 Movies/CacheClip，格式 .dvcc；没有据此判断项目已废弃。", ruleID: "resolve-render-cache", blockingAppIDs: ["com.blackmagic-design.DaVinciResolve"], needsClosedApps: true)
        }
        if SafetyPolicy.within(url, policy.home.appendingPathComponent("Movies/ProxyMedia")), videoExtensions.contains(ext) {
            return FileAssessment(category: .video, disposition: .protected, owner: "DaVinci Resolve", group: "达芬奇代理文件", reason: "请先禁用代理并确认原始素材可正常播放；需要时可重新生成代理。", evidence: "根据代理目录与视频格式识别，未验证原片或项目引用。", ruleID: "resolve-proxy", blockingAppIDs: ["com.blackmagic-design.DaVinciResolve"], needsClosedApps: true)
        }
        if videoExtensions.contains(ext) { return protectedAssessment(.video, "视频素材，请核实是否仍需保留。", "视频格式 .\(ext)") }
        if photoExtensions.contains(ext) { return protectedAssessment(.photo, "照片、RAW 或图像素材，请核实是否仍需保留。", "图像格式 .\(ext)") }
        if audioExtensions.contains(ext) { return protectedAssessment(.audio, "音频或音乐素材，请核实是否仍需保留。", "音频格式 .\(ext)") }
        if ["pdf", "doc", "docx", "ppt", "pptx", "xls", "xlsx", "csv", "txt", "md", "tex", "epub", "pages", "numbers", "key"].contains(ext) {
            return protectedAssessment(.document, "个人文档与学习资料，请确认用途后决定是否删除。", "文档格式 .\(ext)")
        }

        if let known = KnownCacheLocations.match(url, home: policy.home) {
            return knownCache(known.location, relative: known.relative, name: name, days: days, ageEvidence: ageEvidence)
        }
        if inCache {
            if rel.hasPrefix("ms-playwright/") || rel.hasPrefix("node-gyp/") || rel.hasPrefix("ffmpeg-static-nodejs/") || rel.hasPrefix("typescript/") {
                return FileAssessment(category: .runtime, disposition: .protected, owner: String(rel.split(separator: "/").first ?? "开发工具"), group: "开发工具运行资源", reason: "工具运行所需的资源，删除后可能需要重新安装或下载。", evidence: "删除浏览器或编解码工具可能使现有工作流失效。", ruleID: "protect-runtime")
            }
            if match("^pip/http-v2/(?:[a-f0-9]/){5}[a-f0-9]{56,64}(?:\\.body)?$", rel) != nil || match("^pip/http/(?:[a-f0-9]/){5}[a-f0-9]{56,64}$", rel) != nil || (rel.hasPrefix("pip/wheels/") && ext == "whl") {
                return FileAssessment(category: .cache, disposition: days >= 7 ? .priority : .manual, owner: "Python / pip", group: "pip 下载与构建缓存", reason: "已识别 pip 下载或构建缓存；后续安装会重新下载或构建。", evidence: ageEvidence + " 仅匹配 pip 缓存结构，不包含已安装环境。", ruleID: "cache-pip", confidence: "已知缓存目录与格式", sourceURL: "https://pip.pypa.io/en/stable/topics/caching/", needsClosedApps: true)
            }
            if rel.hasPrefix("Homebrew/downloads/"), match("^[a-f0-9]{64}--.+", name) != nil {
                return FileAssessment(category: .cache, disposition: days >= 7 ? .priority : .manual, owner: "Homebrew", group: "Homebrew 下载缓存", reason: "软件安装介质的下载副本；以后安装可能需要重新下载。", evidence: ageEvidence + " 位于 downloads 缓存，不是已安装软件目录。", ruleID: "cache-homebrew", confidence: "已知缓存目录与格式", sourceURL: "https://docs.brew.sh/Manpage#cleanup-options-formulacask-", needsClosedApps: true)
            }
            if (rel.hasPrefix("Adobe Camera Raw 2/") || rel.hasPrefix("Adobe Camera Raw/")), match("^Cache_[0-9]+_[0-9]+\\.dat$", name) != nil {
                let ids = ["com.adobe.LightroomClassicCC7", "com.adobe.Photoshop", "com.adobe.bridge"]
                let running = !context.runningIDs.isDisjoint(with: ids)
                return FileAssessment(category: .cache, disposition: .conditional, owner: "Adobe Camera Raw / Lightroom", group: "Camera Raw 图像处理缓存", reason: "用于加速 RAW 处理，可重建；清理后首次打开照片可能更慢。", evidence: ageEvidence + (running ? " 相关 Adobe 应用正在运行，暂不加入优先清单。" : " 清理前会自动退出相关 Adobe 应用。"), ruleID: "cache-camera-raw", confidence: "已知缓存目录与格式", sourceURL: "https://helpx.adobe.com/camera-raw/desktop/get-started/overview-and-setup/introduction-camera-raw.html", blockingAppIDs: ids, needsClosedApps: true)
            }
            if match("^Google/Chrome/(?:Default|Profile [0-9]+)/(?:Cache/Cache_Data|Code Cache/(?:js|wasm)|GPUCache)/(?:[a-f0-9]+_(?:[0-9]+|s)|[a-f0-9]+)$", rel) != nil {
                return FileAssessment(category: .cache, disposition: .conditional, owner: "Google Chrome", group: "Chrome 网页与代码缓存", reason: "仅识别网页/代码缓存；网页资源会重新下载。", evidence: ageEvidence + (context.runningIDs.contains("com.google.Chrome") ? " Chrome 正在运行，清理前会自动退出。" : " 清理前会检查 Chrome 是否已退出。") + " 不涉及 Cookie、密码、历史和站点数据库。", ruleID: "cache-chrome", confidence: "精确缓存子目录", sourceURL: "https://support.google.com/chrome/answer/2392709", blockingAppIDs: ["com.google.Chrome"], needsClosedApps: true)
            }
            if match("^Firefox/Profiles/[^/]+/cache2/entries/[A-Fa-f0-9]{40}$", rel) != nil {
                return FileAssessment(category: .cache, disposition: .conditional, owner: "Firefox", group: "Firefox 网页缓存", reason: "网页内容会重新下载；不包含 Cookie、密码、历史或离线站点数据库。", evidence: "cache2/entries 中的 SHA-1 文件名；" + ageEvidence, ruleID: "cache-firefox", confidence: "精确缓存子目录与格式", sourceURL: "https://firefox-source-docs.mozilla.org/networking/cache2/doc.html", blockingAppIDs: ["org.mozilla.firefox"], needsClosedApps: true)
            }
            if match("^com\\.microsoft\\.edgemac/(?:Default|Profile [0-9]+)/(?:Cache/Cache_Data|Code Cache/(?:js|wasm)|GPUCache)/(?:[a-f0-9]+_(?:[0-9]+|s)|[a-f0-9]+)$", rel) != nil {
                return FileAssessment(category: .cache, disposition: .conditional, owner: "Microsoft Edge", group: "Edge 网页与代码缓存", reason: "仅处理网页与代码缓存；不包含登录状态、密码和历史。", evidence: "精确 Chromium 缓存结构；" + ageEvidence, ruleID: "cache-edge", blockingAppIDs: ["com.microsoft.edgemac"], needsClosedApps: true)
            }
            if match("^go-build/[0-9a-f]{2}/[0-9a-f]{64}-[ad]$", rel) != nil {
                return FileAssessment(category: .cache, disposition: days >= 7 ? .priority : .manual, owner: "Go", group: "Go 编译缓存", reason: "已识别 Go 编译缓存；之后编译会重新生成，首次编译可能更慢。", evidence: ageEvidence + " 仅匹配 go-build 缓存结构，不包含模块下载和源码。", ruleID: "cache-go-build", confidence: "已知缓存目录与格式", sourceURL: "https://pkg.go.dev/cmd/go#hdr-Build_and_test_caching", needsClosedApps: true)
            }
            let owner = String(rel.split(separator: "/").first ?? "未识别应用")
            return FileAssessment(category: .otherCache, disposition: .unknown, owner: owner, group: owner, reason: "仅知道位于 Caches，无法确认内容是否仍有用途。", evidence: "可能包含离线数据、会话资源或运行依赖；请自行确认是否仍需保留。", ruleID: "unknown-cache")
        }
        let derived = policy.home.appendingPathComponent("Library/Developer/Xcode/DerivedData")
        if SafetyPolicy.within(url, derived) {
            let rel = String(path.dropFirst(derived.path.count + 1))
            if match("^[^/]+/Build/Intermediates\\.noindex/", rel) != nil {
                return FileAssessment(category: .cache, disposition: .protected, owner: "Xcode", group: "Xcode 编译中间文件", reason: "项目生成的编译中间文件；清理后需要重新编译，请自行确认。", evidence: "仅识别 DerivedData 的 Build/Intermediates.noindex；排除源码包、Archives 与模块缓存。", ruleID: "cache-xcode-intermediates", sourceURL: "https://help.apple.com/xcode/mac/current/en.lproj/deva52afe8a4.html", blockingAppIDs: ["com.apple.dt.Xcode"], needsClosedApps: true)
            }
        }
        if SafetyPolicy.within(url, logRoot), (["log", "ips", "crash"].contains(ext) || match("\\.log\\.[0-9]+$", name) != nil) {
            let relative = path.dropFirst(logRoot.path.count + 1)
            let owner = String(relative.split(separator: "/").first ?? "应用")
            return FileAssessment(category: .log, disposition: .manual, owner: owner, group: owner + " 日志", reason: "可能用于排查问题；本轮不自动加入候选。", evidence: ageEvidence, ruleID: "old-log", needsClosedApps: true)
        }
        if ["dmg", "pkg"].contains(ext) { return installer(url, days: days) }
        if archiveExtensions.contains(ext) || ext == "iso" {
            return FileAssessment(category: .archive, disposition: .unknown, owner: "个人下载", group: "待辨认压缩包", reason: "压缩格式不能证明是安装包，可能装有素材、项目或备份。", evidence: "未解压或执行内容，保留等待人工辨认。", ruleID: "unknown-archive")
        }
        return FileAssessment(category: .other, disposition: .unknown, owner: "个人文件", group: "其他待辨认文件", reason: "用途不足以确定，暂不加入清理。", evidence: ageEvidence, ruleID: "unknown-file")
    }
    /// Files in an allowlisted cache subtree must also match that rule's known layout.
    private func knownCache(_ location: KnownCacheLocation, relative rel: String, name: String, days: Int, ageEvidence: String) -> FileAssessment {
        let chromiumEntry = "(?:[a-f0-9]+_(?:[0-9]+|s)|[a-f0-9]+)"
        let pattern: String
        let disposition: CleanupDisposition
        let reason: String
        let scope: String
        switch location.layout {
        case .npm:
            pattern = "^(?:content-v2/sha(?:512|384|256|1)/[0-9a-f]{2}/[0-9a-f]{2}/[0-9a-f]{20,}|index-v5/[0-9a-f]{2}/[0-9a-f]{2}/[0-9a-f]{20,})$"
            disposition = .priority
            reason = "已识别 npm 下载缓存；之后安装会重新下载，已安装的 node_modules 不受影响。"
            scope = " 仅匹配 _cacache 的内容与索引结构，不包含 npm 配置、日志和全局安装的包。"
        case .cargo:
            pattern = "^[^/]+/[A-Za-z0-9_.+-]+\\.crate$"
            disposition = .priority
            reason = "已识别 Cargo 下载的 .crate 压缩包；之后编译会按需重新下载。"
            scope = " 仅匹配 registry/cache 中的 .crate 文件，不包含已解压源码、Cargo 配置和凭据。"
        case .gradle:
            pattern = "^[^/]+/[^/]+/[^/]+/[0-9a-f]{20,40}/[^/]+\\.(?:jar|aar|pom|module|klib)$"
            disposition = days >= 30 ? .priority : .manual
            reason = "已识别 Gradle 依赖下载缓存；之后构建会重新下载，首次构建可能更慢。"
            scope = " 仅匹配 modules-2/files-2.1 的依赖文件，不包含构建脚本、Gradle 配置和项目输出。"
        case .simulator:
            pattern = "^dyld/.+"
            disposition = .conditional
            reason = "模拟器系统共享缓存；下次启动模拟器时会重新生成，首次启动会更慢。"
            scope = " 仅匹配 CoreSimulator/Caches/dyld，不包含模拟器设备、应用和数据。"
        case .chromiumCache:
            pattern = "^Cache_Data/" + chromiumEntry + "$"
            disposition = .conditional
            reason = "仅识别网页缓存；内容会重新下载，不包含登录状态、消息记录和设置。"
            scope = " 精确 Chromium 缓存结构，不涉及 Cookie、本地存储和数据库。"
        case .chromiumCodeCache:
            pattern = "^(?:js|wasm)/" + chromiumEntry + "$"
            disposition = .conditional
            reason = "仅识别脚本编译缓存；应用下次启动时重新生成。"
            scope = " 精确 Chromium 代码缓存结构，不涉及 Cookie、本地存储和数据库。"
        case .chromiumGPUCache:
            pattern = "^" + chromiumEntry + "$|^(?:data_[0-9]+|f_[0-9a-f]+|index)$"
            disposition = .conditional
            reason = "仅识别图形着色器缓存；应用下次启动时重新生成。"
            scope = " 精确 GPUCache 结构，不涉及 Cookie、本地存储和数据库。"
        case .electronCachedData:
            pattern = "^[0-9a-f]{40}/(?:[^/]+/){0,3}[^/]+$"
            disposition = .conditional
            reason = "按应用版本保存的脚本编译缓存；应用下次启动时重新生成。"
            scope = " 仅匹配以版本提交号命名的 CachedData 子目录，不包含扩展、设置和工作区数据。"
        }
        guard match(pattern, rel) != nil else {
            return FileAssessment(category: .otherCache, disposition: .unknown, owner: location.owner, group: location.owner, reason: "位于已知缓存目录，但不符合已核实的缓存结构，暂不加入清理。", evidence: "可能是临时文件、锁文件或新版本格式；请自行确认是否仍需保留。", ruleID: "unknown-" + location.ruleID)
        }
        let running = !context.runningIDs.isDisjoint(with: location.blockingAppIDs)
        let appNote = location.blockingAppIDs.isEmpty ? " 清理前会检查相关任务是否仍在运行。" : running ? " 相关应用正在运行，清理前会自动退出。" : " 清理前会检查相关应用是否已退出。"
        return FileAssessment(category: .cache, disposition: disposition, owner: location.owner, group: location.group, reason: reason, evidence: ageEvidence + scope + appNote, ruleID: location.ruleID, confidence: "已知缓存目录与格式", sourceURL: location.sourceURL, blockingAppIDs: location.blockingAppIDs, needsClosedApps: true)
    }
    private func versionedInstaller(owner: String, version: String, installed: [InstalledApplication], days: Int, confidence: String) -> FileAssessment? {
        guard let newest = installed.max(by: { $0.version.compare($1.version, options: .numeric) == .orderedAscending }) else { return nil }
        let older = version.compare(newest.version, options: .numeric) == .orderedAscending
        let newer = version.compare(newest.version, options: .numeric) == .orderedDescending
        let title = older ? " 旧版本安装包" : newer ? " 较新版本安装介质" : " 已安装版本的介质"
        let reason = older ? "本机已安装更高版本；如果不需要回退，可考虑移走此安装介质。" : newer ? "文件名版本高于本机安装版本，可能用于升级，先保留核对。" : "对应应用已安装；是否保留重装介质由你决定。"
        return FileAssessment(category: .installer, disposition: older && days >= 7 ? .priority : .manual, owner: owner, group: owner + title, reason: reason, evidence: "文件名版本 \(version)；已安装 \(newest.version)（\(newest.path)）。未挂载安装包、未核验包内版本。", ruleID: older ? "old-installer" : "installed-media", confidence: confidence)
    }
    /// Splits installer names such as "Rectangle0.8.dmg", "Firefox 132.0.dmg" or "vlc-3.0.21-arm64.dmg"
    /// into an application name and a dotted version. Names without a dotted version are not matched.
    private func genericInstallerName(_ fileName: String) -> (String, String)? {
        let stem = (fileName as NSString).deletingPathExtension
        guard let expression = try? NSRegularExpression(pattern: "^([A-Za-z][A-Za-z0-9 ._+-]*?)[ ._-]*[vV]?([0-9]+(?:\\.[0-9]+){1,3})(?:[ ._+-].*)?$"),
              let result = expression.firstMatch(in: stem, range: NSRange(stem.startIndex..., in: stem)),
              let nameRange = Range(result.range(at: 1), in: stem), let versionRange = Range(result.range(at: 2), in: stem) else { return nil }
        return (String(stem[nameRange]), String(stem[versionRange]))
    }
    private func normalizedAppName(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
    private func installer(_ url: URL, days: Int) -> FileAssessment {
        let name = url.lastPathComponent
        let rules: [(String, String, String)] = [
            ("^DaVinci_Resolve_Studio_([0-9]+(?:\\.[0-9]+)+)_Mac\\.dmg$", "com.blackmagic-design.DaVinciResolve", "DaVinci Resolve"),
            ("^Obsidian-([0-9]+(?:\\.[0-9]+)+)\\.dmg$", "md.obsidian", "Obsidian"),
            ("^Notion-([0-9]+(?:\\.[0-9]+)+)(?:-arm64|-universal)?\\.dmg$", "notion.id", "Notion"),
            ("^IINA\\.v([0-9]+(?:\\.[0-9]+)+)\\.dmg$", "com.colliderli.iina", "IINA"),
            ("^Mos\\.Versions\\.([0-9]+(?:\\.[0-9]+)+)\\.dmg$", "com.caldis.Mos", "Mos"),
            ("^UU-macOS-([0-9]+(?:\\.[0-9]+)+)\\.dmg$", "com.netease.uumac", "UU 加速器")
        ]
        for (pattern, bundleID, owner) in rules {
            guard let version = match(pattern, name) else { continue }
            guard let assessment = versionedInstaller(owner: owner, version: version, installed: context.applications.filter { $0.id == bundleID }, days: days, confidence: "文件名 + 本机安装信息") else { break }
            return assessment
        }
        if let parsed = genericInstallerName(name) {
            let (appName, version) = parsed
            let key = normalizedAppName(appName)
            let installed = context.applications.filter { app in
                !app.version.isEmpty && [app.name, URL(fileURLWithPath: app.path).deletingPathExtension().lastPathComponent].contains { normalizedAppName($0) == key }
            }
            if key.count >= 3, let owner = installed.first?.name,
               let assessment = versionedInstaller(owner: owner, version: version, installed: installed, days: days, confidence: "文件名中的应用名称与版本 + 本机安装信息") {
                return assessment
            }
        }
        let known: [(String, String, String)] = [
            ("^VSCode-darwin-(?:universal|arm64|x64)\\.dmg$", "com.microsoft.VSCode", "Visual Studio Code"),
            ("^googlechrome\\.dmg$", "com.google.Chrome", "Google Chrome"),
            ("^Claude\\.dmg$", "com.anthropic.claudefordesktop", "Claude"),
            (".*DJIStudio-[0-9]+.*\\.pkg$", "com.light.studio", "DJI Studio"),
            ("^bitz-.*\\.pkg$", "org.erb.vortex", "Bitz Net"),
            ("^steam\\.dmg$", "com.valvesoftware.steam", "Steam"),
            ("^thunder\\.dmg$", "com.xunlei.Thunder", "迅雷")
        ]
        for (pattern, bundleID, owner) in known where match(pattern, name) != nil {
            let installed = context.applications.filter { $0.id == bundleID }
            if !installed.isEmpty {
                return FileAssessment(category: .installer, disposition: .manual, owner: owner, group: owner + " 安装介质待确认", reason: "对应应用已安装，安装包内部版本仍未核实。", evidence: installed.map { "\($0.version) / build \($0.build)：\($0.path)" }.joined(separator: "；"), ruleID: "installed-media-unverified", confidence: "名称匹配，版本未核实")
            }
        }
        return FileAssessment(category: .installer, disposition: .unknown, owner: "对应应用未确认", group: "身份未确认的安装介质", reason: "文件扩展名是安装介质；尚不能确认对应应用或版本。", evidence: "可能存在同名应用、备份镜像或未安装软件；请自行确认用途和是否需要保留。", ruleID: "unknown-installer")
    }
}

struct ScanConfiguration: Codable, Equatable {
    let roots: [URL]
    let label: String
    let minimumBytes: Int64
    /// Opens the results filtered to files unused for this many days (the long-unused large-file view).
    var unusedDays: Int? = nil
}

struct ScanArchive: Codable {
    var schemaVersion = 3
    let scannedAt: Date
    let label: String
    let result: ScanResult
    var preselectPriority = false
    var configuration: ScanConfiguration? = nil
    var catalogVersion: Int? = nil
}

struct AssessmentGroup: Identifiable {
    let id: String
    let assessment: FileAssessment
    let items: [ScanItem]
    var bytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
    static func build(_ items: [ScanItem]) -> [AssessmentGroup] {
        Dictionary(grouping: items, by: { $0.assessment.groupID }).map { id, items in
            AssessmentGroup(id: id, assessment: items[0].assessment, items: items)
        }.sorted { a, b in
            let order = CleanupDisposition.allCases
            let ai = order.firstIndex(of: a.assessment.disposition) ?? 9
            let bi = order.firstIndex(of: b.assessment.disposition) ?? 9
            return ai == bi ? a.bytes > b.bytes : ai < bi
        }
    }
}
