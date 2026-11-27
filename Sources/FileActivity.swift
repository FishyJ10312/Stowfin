import Foundation
import CoreServices

/// When a file was last touched by the person, for "unused for a long time" views.
/// A modification date alone misses files that are opened but never edited, so this
/// takes the latest of the modification date, Spotlight's last-opened date and the
/// date the file was added to its folder. Spotlight may be off or not yet indexed;
/// the modification date is then the only evidence, and the interface says so.
enum FileActivity {
    static func lastActivity(_ url: URL, modified: Date, useSpotlight: Bool = true) -> Date {
        var latest = modified
        guard useSpotlight, let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else { return latest }
        for key in [kMDItemLastUsedDate, kMDItemDateAdded] {
            if let date = MDItemCopyAttribute(item, key) as? Date, date > latest, date <= Date().addingTimeInterval(86_400) { latest = date }
        }
        return latest
    }
    /// Thresholds offered in the filter menu, in days.
    static let thresholds = [180, 365, 730]
    static func title(days: Int) -> String {
        switch days {
        case 0: return "全部时间"
        case 365: return "一年以上未用"
        case 730: return "两年以上未用"
        default: return "\(days / 30) 个月以上未用"
        }
    }
}
