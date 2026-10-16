import Foundation

/// Dates the way the History face writes them: in the person's own calendar, zone and language, never the machine's by
/// default. (Every caller is handed its calendar and locale; nothing here asks for the current ones.)
enum HistoryDates {
    /// A formatter for a skeleton such as `EEEdMMM` (`Wed 14 Oct`), `dMMM` (`14 Oct`) or `jm` (`14:20`).
    static func formatter(_ template: String, calendar: Calendar, locale: Locale) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }
}
