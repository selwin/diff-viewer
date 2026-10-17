import Foundation

/// The +/− text a churn label draws.
enum ChurnText {
    /// "+1,204" and "−3", grouped for `locale`; nil for a side that did not change.
    static func lineCounts(added: Int, deleted: Int, locale: Locale) -> (added: String?, deleted: String?) {
        (
            added > 0 ? "+" + added.formatted(.number.locale(locale)) : nil,
            deleted > 0 ? "−" + deleted.formatted(.number.locale(locale)) : nil
        )
    }
}
