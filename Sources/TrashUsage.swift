import Foundation

/// How much the Trash still holds. Moving files to the Trash frees nothing until the
/// Trash is emptied, so the result screen reports this alongside what was moved.
/// Stowfin only measures the Trash; emptying it stays the user's own action in Finder.
struct TrashUsage: Equatable {
    let bytes: Int64
    let items: Int
    /// False when the time budget ran out or part of the Trash could not be read.
    let complete: Bool

    /// The home Trash, plus the per-user Trash of each external volume a record went to.
    static func folders(home: URL, records: [TrashRecord], userID: uid_t = getuid()) -> [URL] {
        var folders = [home.appendingPathComponent(".Trash").standardizedFileURL]
        for record in records {
            let parts = record.trashed.standardizedFileURL.pathComponents
            guard parts.count > 4, parts[1] == "Volumes", parts[3] == ".Trashes", parts[4] == String(userID) else { continue }
            let folder = URL(fileURLWithPath: "/Volumes/" + parts[2] + "/.Trashes/" + parts[4])
            if !folders.contains(folder) { folders.append(folder) }
        }
        return folders
    }

    /// Returns nil when no Trash folder could be read at all (for example without Full Disk Access).
    static func measure(_ folders: [URL], timeLimit: TimeInterval = 8, cancellation: ScanCancellation? = nil) -> TrashUsage? {
        let deadline = Date().addingTimeInterval(timeLimit)
        var bytes: Int64 = 0, items = 0, complete = true, readable = false
        var seen = Set<String>()
        let manager = FileManager.default
        for folder in folders {
            guard let stamp = FileStamp.read(folder), stamp.isDirectory, !stamp.isSymlink,
                  let top = try? manager.contentsOfDirectory(atPath: folder.path) else { continue }
            readable = true
            items += top.filter { $0 != ".DS_Store" && $0 != ".localized" }.count
            guard let enumerator = manager.enumerator(at: folder, includingPropertiesForKeys: nil, options: [], errorHandler: { _, _ in complete = false; return true }) else { complete = false; continue }
            while let url = autoreleasepool(invoking: { enumerator.nextObject() as? URL }) {
                if cancellation?.isCancelled == true || Date() > deadline { complete = false; break }
                guard let entry = FileStamp.read(url) else { complete = false; continue }
                if entry.isSymlink { continue }
                guard entry.isRegular else { continue }
                // Hard links inside the Trash occupy their blocks once.
                if entry.links > 1, !seen.insert("\(entry.device):\(entry.inode)").inserted { continue }
                bytes += entry.allocated
            }
            if !complete && Date() > deadline { break }
        }
        return readable ? TrashUsage(bytes: bytes, items: items, complete: complete) : nil
    }

    var summary: String {
        complete ? "废纸篓目前共占用 \(formatBytes(bytes))（\(items) 项）；清空废纸篓后才会释放这部分空间。"
                 : "废纸篓至少占用 \(formatBytes(bytes))（\(items) 项）；清空废纸篓后才会释放这部分空间。"
    }
}
