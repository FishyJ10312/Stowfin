import AppKit
import Foundation

@main struct NativeQuitTests {
    @MainActor static func main() async throws {
        let fm = FileManager.default, cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
        let helper = cwd.appendingPathComponent(".build/QingSweepQuitFixture.app")
        var count = 0
        func check(_ value: Bool, _ title: String) { guard value else { fatalError("FAIL: " + title) }; count += 1; print("PASS: " + title) }
        for refuse in [false, true] {
            let base = cwd.appendingPathComponent("testdata-nativequit-" + UUID().uuidString)
            let file = base.appendingPathComponent("Downloads/open.mp4")
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let bytes = Data(repeating: 0x42, count: 8192); try bytes.write(to: file)
            let config = NSWorkspace.OpenConfiguration(); config.activates = false; config.createsNewApplicationInstance = true
            config.arguments = [base.path] + (refuse ? ["refuse"] : [])
            let app: NSRunningApplication = try await withCheckedThrowingContinuation { continuation in
                NSWorkspace.shared.openApplication(at: helper, configuration: config) { app, error in
                    if let app { continuation.resume(returning: app) } else { continuation.resume(throwing: error ?? CleanupPreparationError.usageUnavailable) }
                }
            }
            let deadline = Date().addingTimeInterval(10)
            while !fm.fileExists(atPath: base.appendingPathComponent("ready").path) && Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
            check(fm.fileExists(atPath: base.appendingPathComponent("ready").path), "dedicated native fixture launches and opens its disposable file")
            let policy = SafetyPolicy(home: base), stamp = FileStamp.read(file)!
            let item = ScanItem(url: file, root: base, stamp: stamp, assessment: FileClassifier(policy: policy, context: InspectionContext()).assess(file, stamp: stamp))
            let environment = SystemCleanupEnvironment(), usage = try await environment.usage(for: [item])
            check(usage.openFiles[file.path]?.contains(app.processIdentifier) == true, "native lsof probe finds the real file handle")
            // Each poll runs a full lsof probe, which can take over a second while the rest of the suite
            // is busy, so the accepting case uses the production timeout. Refusal only needs a short wait.
            let result = await CleanupExecutor(environment: environment, quitTimeout: refuse ? 2.0 : 10.0).run([item], policy: policy, consent: ManualCleanupConsent(reviewedItems: [item]), cancellation: ScanCancellation()) { _ in }
            if refuse {
                check(!app.isTerminated && result.trash.records.isEmpty && result.closedApplications.isEmpty && fm.fileExists(atPath: file.path), "native app refusing quit keeps its file untouched")
            } else {
                check(app.isTerminated && result.trash.records.count == 1, "native graceful quit is observed before moving the fixture to Trash")
                try TrashService(policy: policy).restore(result.trash.records[0])
                check((try? Data(contentsOf: file)) == bytes, "native quit and cleanup fixture restores byte-identically")
            }
            try Data().write(to: base.appendingPathComponent("finish"))
            if !app.isTerminated { _ = app.terminate() }
            let stop = Date().addingTimeInterval(5)
            while !app.isTerminated && Date() < stop { try await Task.sleep(nanoseconds: 100_000_000) }
            check(app.isTerminated, "only the disposable helper exits at test teardown")
            try fm.removeItem(at: base)
        }
        print("\(count) native application-exit checks passed; no user applications were asked to quit.")
    }
}
