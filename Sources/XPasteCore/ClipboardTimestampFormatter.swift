import Foundation

public enum ClipboardTimestampFormatter {
    public static func display(
        _ date: Date,
        relativeTo now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> String {
        let elapsed = now.timeIntervalSince(date)

        // Small clock differences should not turn a fresh capture into a future date.
        if elapsed >= -300, elapsed < 60 {
            return "刚刚"
        }
        if elapsed >= 60, elapsed < 3_600 {
            return "\(Int(elapsed / 60))分钟前"
        }
        if elapsed >= 3_600, elapsed < 86_400 {
            return "\(Int(elapsed / 3_600))小时前"
        }

        if calendar.isDateInToday(date) {
            return "今天 \(time(date, calendar: calendar))"
        }
        if calendar.isDateInYesterday(date) {
            return "昨天 \(time(date, calendar: calendar))"
        }

        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let currentYear = calendar.component(.year, from: now)
        let month = components.month ?? 0
        let day = components.day ?? 0
        if components.year == currentYear {
            return "\(month)月\(day)日 \(time(date, calendar: calendar))"
        }
        return "\(components.year ?? 0)年\(month)月\(day)日 \(time(date, calendar: calendar))"
    }

    public static func full(
        _ date: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> String {
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d年%d月%d日 %02d:%02d:%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0,
            components.hour ?? 0,
            components.minute ?? 0,
            components.second ?? 0
        )
    }

    private static func time(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
    }
}
