import AppKit
import CmmKit
import SwiftUI

/// The Settings window (the board `C-Settings`): a grouped form with exactly four switches, one sentence each, the reminder's
/// weekday and time, and the two places in System Settings where macOS lets the person undo what cmm asked for.
///
/// The switches are the settings model's: the person's choices are written as they are made, and what the system owns (Open at
/// login, notifications) is read from the system when the window appears and whenever cmm comes forward, and never kept.
struct SettingsView: View {
    @Bindable var settings: SettingsModel
    /// System Settings > General > Login Items (the system's own call; `SystemLoginItem.openSystemSettings`).
    let openLoginItems: () -> Void
    var calendar: Calendar = .autoupdatingCurrent
    var locale: Locale = .autoupdatingCurrent
    @Environment(\.openURL) private var openURL

    static let width = 540.0

    var body: some View {
        Form {
            Section {
                row(SettingsCopy.menuBar, isOn: $settings.menuBarEnabled)
                row(SettingsCopy.openAtLogin, isOn: openAtLogin, extra: loginLine.map { line in AnyView(lineView(line).padding(.top, 4)) })
                row(SettingsCopy.reminder, isOn: reminder, extra: AnyView(reminderExtras))
                row(SettingsCopy.history, isOn: $settings.historyEnabled)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .navigationTitle(SettingsCopy.windowTitle)
        .environment(\.openURL, OpenURLAction { url in
            switch SettingsCopy.Destination(url: url) {
            case .loginItems:
                openLoginItems()
                return .handled
            case .notifications:
                return .systemAction
            case nil:
                return .discarded
            }
        })
        .task { await settings.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await settings.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            Task { await settings.refresh() }
        }
    }

    // MARK: the switches

    private var openAtLogin: Binding<Bool> {
        Binding(get: { settings.openAtLogin != .off }, set: { settings.setOpenAtLogin($0) })
    }

    private var reminder: Binding<Bool> {
        Binding(get: { settings.weeklyReminderEnabled }, set: { on in Task { await settings.setWeeklyReminder(on) } })
    }

    /// What macOS says about Open at login, when it is not simply on or off.
    private var loginLine: SettingsCopy.Line? {
        if settings.openAtLoginFailed { return SettingsCopy.loginRefused }
        if settings.openAtLogin == .needsApproval { return SettingsCopy.loginNeedsApproval }
        return nil
    }

    /// One switch: its title and sentence on the left, the switch on the right, top aligned as on the board.
    private func row(_ copy: SettingsCopy.Switch, isOn: Binding<Bool>, extra: AnyView? = nil) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                Text(copy.title)
                    .font(Typeface.ui(13, .medium))
                    .foregroundStyle(Theme.ink)
                lineView(copy.detail)
                    .padding(.top, 3)
                if let extra { extra }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(copy.title, isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(Theme.accent)
                .padding(.top, 2)
                .accessibilityHint(copy.detail.text)
        }
        .padding(.vertical, 4)
    }

    /// The reminder's weekday and time, and what macOS can do about it (or what it already did).
    private var reminderExtras: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Picker("Weekday", selection: weekday) {
                    ForEach(SettingsCopy.weekdays(calendar: calendar, locale: locale), id: \.value) { option in
                        Text(option.title).tag(option.value)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                Text(SettingsCopy.reminderAt)
                    .font(Typeface.ui(12.5))
                    .foregroundStyle(Theme.ink2)
                    .accessibilityHidden(true)
                Picker("Time", selection: minuteOfDay) {
                    ForEach(SettingsCopy.times(chosen: minuteOfDayValue, calendar: calendar, locale: locale), id: \.minuteOfDay) { option in
                        Text(option.title).tag(option.minuteOfDay)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            .disabled(!settings.weeklyReminderEnabled)
            .padding(.top, 9)
            lineView(settings.reminderIsSilenced ? SettingsCopy.reminderSilenced : SettingsCopy.reminderSilence)
                .padding(.top, 8)
        }
    }

    private var minuteOfDayValue: Int { settings.weeklySchedule.hour * 60 + settings.weeklySchedule.minute }

    private var weekday: Binding<Int> {
        Binding(
            get: { settings.weeklySchedule.weekday },
            set: { settings.weeklySchedule = WeeklySchedule(weekday: $0, hour: settings.weeklySchedule.hour, minute: settings.weeklySchedule.minute) }
        )
    }

    private var minuteOfDay: Binding<Int> {
        Binding(
            get: { minuteOfDayValue },
            set: { settings.weeklySchedule = WeeklySchedule(weekday: settings.weeklySchedule.weekday, hour: $0 / 60, minute: $0 % 60) }
        )
    }

    /// A line of small print, its link (if it has one) in the ink's colour and a little heavier, and clickable.
    private func lineView(_ line: SettingsCopy.Line) -> some View {
        var text = AttributedString(line.before)
        if let link = line.link, let destination = line.destination {
            var linked = AttributedString(link)
            linked.link = destination.url
            linked.font = Typeface.ui(11.5, .medium)
            text += linked
        }
        text += AttributedString(line.after)
        return Text(text)
            .font(Typeface.ui(11.5))
            .foregroundStyle(Theme.ink2)
            .tint(Theme.ink)
            .lineSpacing(16 - 11.5 * 1.257)
            .fixedSize(horizontal: false, vertical: true)
    }
}
