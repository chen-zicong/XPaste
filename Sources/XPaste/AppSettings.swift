import Carbon.HIToolbox
import Foundation
import Observation

struct GlobalShortcut: Codable, Hashable, Identifiable, Sendable {
    let keyCode: UInt32
    let carbonModifiers: UInt32
    let displayName: String

    var id: String { "\(keyCode)-\(carbonModifiers)" }

    /// A conservative validation for shortcuts entered from the recorder. Function
    /// keys may be used alone; ordinary keys should include at least one modifier.
    var isReasonable: Bool {
        guard keyCode <= UInt32(UInt16.max), !Self.modifierOnlyKeyCodes.contains(keyCode) else {
            return false
        }
        let primaryModifiers = UInt32(cmdKey | optionKey | controlKey)
        return carbonModifiers & primaryModifiers != 0 || Self.functionKeyCodes.contains(keyCode)
    }

    init(keyCode: UInt32, carbonModifiers: UInt32) {
        let modifiers = carbonModifiers & Self.supportedModifierMask
        self.keyCode = keyCode
        self.carbonModifiers = modifiers
        self.displayName = Self.makeDisplayName(keyCode: keyCode, carbonModifiers: modifiers)
    }

    static func == (lhs: GlobalShortcut, rhs: GlobalShortcut) -> Bool {
        lhs.keyCode == rhs.keyCode && lhs.carbonModifiers == rhs.carbonModifiers
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(keyCode)
        hasher.combine(carbonModifiers)
    }

    static let defaultHistory = GlobalShortcut(
        keyCode: UInt32(kVK_ANSI_V),
        carbonModifiers: UInt32(controlKey | optionKey)
    )
    static let defaultFavorites = GlobalShortcut(
        keyCode: UInt32(kVK_ANSI_F),
        carbonModifiers: UInt32(controlKey | optionKey)
    )

    // Kept as source-compatible names for tests and code migrating from the old presets.
    static let controlOptionV = defaultHistory
    static let commandShiftV = GlobalShortcut(
        keyCode: UInt32(kVK_ANSI_V),
        carbonModifiers: UInt32(cmdKey | shiftKey)
    )
    static let controlShiftV = GlobalShortcut(
        keyCode: UInt32(kVK_ANSI_V),
        carbonModifiers: UInt32(controlKey | shiftKey)
    )
    static let optionV = GlobalShortcut(
        keyCode: UInt32(kVK_ANSI_V),
        carbonModifiers: UInt32(optionKey)
    )
    static let controlOptionF = defaultFavorites
    static let commandShiftF = GlobalShortcut(
        keyCode: UInt32(kVK_ANSI_F),
        carbonModifiers: UInt32(cmdKey | shiftKey)
    )
    static let controlShiftF = GlobalShortcut(
        keyCode: UInt32(kVK_ANSI_F),
        carbonModifiers: UInt32(controlKey | shiftKey)
    )
    static let optionShiftV = GlobalShortcut(
        keyCode: UInt32(kVK_ANSI_V),
        carbonModifiers: UInt32(optionKey | shiftKey)
    )

    private enum CodingKeys: String, CodingKey {
        case keyCode
        case carbonModifiers
        case displayName
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let keyCode = try values.decode(UInt32.self, forKey: .keyCode)
        let modifiers = try values.decode(UInt32.self, forKey: .carbonModifiers) & Self.supportedModifierMask
        let persistedDisplayName = try values.decodeIfPresent(String.self, forKey: .displayName)

        self.keyCode = keyCode
        self.carbonModifiers = modifiers
        self.displayName = persistedDisplayName?.isEmpty == false
            ? persistedDisplayName!
            : Self.makeDisplayName(keyCode: keyCode, carbonModifiers: modifiers)
    }

    private static let supportedModifierMask = UInt32(cmdKey | optionKey | controlKey | shiftKey)

    private static let modifierOnlyKeyCodes: Set<UInt32> = [
        UInt32(kVK_Command), UInt32(kVK_RightCommand),
        UInt32(kVK_Shift), UInt32(kVK_RightShift),
        UInt32(kVK_Option), UInt32(kVK_RightOption),
        UInt32(kVK_Control), UInt32(kVK_RightControl),
        UInt32(kVK_CapsLock), UInt32(kVK_Function)
    ]

    private static let functionKeyCodes: Set<UInt32> = [
        UInt32(kVK_F1), UInt32(kVK_F2), UInt32(kVK_F3), UInt32(kVK_F4),
        UInt32(kVK_F5), UInt32(kVK_F6), UInt32(kVK_F7), UInt32(kVK_F8),
        UInt32(kVK_F9), UInt32(kVK_F10), UInt32(kVK_F11), UInt32(kVK_F12),
        UInt32(kVK_F13), UInt32(kVK_F14), UInt32(kVK_F15), UInt32(kVK_F16),
        UInt32(kVK_F17), UInt32(kVK_F18), UInt32(kVK_F19), UInt32(kVK_F20)
    ]

    private static func makeDisplayName(keyCode: UInt32, carbonModifiers: UInt32) -> String {
        var value = ""
        if carbonModifiers & UInt32(controlKey) != 0 { value += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { value += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { value += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { value += "⌘" }
        value += keyDisplayNames[keyCode] ?? String(format: "Key %02X", keyCode)
        return value
    }

    private static let keyDisplayNames: [UInt32: String] = [
        UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B",
        UInt32(kVK_ANSI_C): "C", UInt32(kVK_ANSI_D): "D",
        UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F",
        UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H",
        UInt32(kVK_ANSI_I): "I", UInt32(kVK_ANSI_J): "J",
        UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
        UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N",
        UInt32(kVK_ANSI_O): "O", UInt32(kVK_ANSI_P): "P",
        UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R",
        UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T",
        UInt32(kVK_ANSI_U): "U", UInt32(kVK_ANSI_V): "V",
        UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
        UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z",
        UInt32(kVK_ANSI_0): "0", UInt32(kVK_ANSI_1): "1",
        UInt32(kVK_ANSI_2): "2", UInt32(kVK_ANSI_3): "3",
        UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5",
        UInt32(kVK_ANSI_6): "6", UInt32(kVK_ANSI_7): "7",
        UInt32(kVK_ANSI_8): "8", UInt32(kVK_ANSI_9): "9",
        UInt32(kVK_ANSI_Equal): "=", UInt32(kVK_ANSI_Minus): "-",
        UInt32(kVK_ANSI_RightBracket): "]", UInt32(kVK_ANSI_LeftBracket): "[",
        UInt32(kVK_ANSI_Quote): "'", UInt32(kVK_ANSI_Semicolon): ";",
        UInt32(kVK_ANSI_Backslash): "\\", UInt32(kVK_ANSI_Comma): ",",
        UInt32(kVK_ANSI_Slash): "/", UInt32(kVK_ANSI_Period): ".",
        UInt32(kVK_ANSI_Grave): "`",
        UInt32(kVK_Return): "↩", UInt32(kVK_Tab): "⇥",
        UInt32(kVK_Space): "Space", UInt32(kVK_Delete): "⌫",
        UInt32(kVK_Escape): "⎋", UInt32(kVK_ForwardDelete): "⌦",
        UInt32(kVK_Home): "↖", UInt32(kVK_End): "↘",
        UInt32(kVK_PageUp): "⇞", UInt32(kVK_PageDown): "⇟",
        UInt32(kVK_LeftArrow): "←", UInt32(kVK_RightArrow): "→",
        UInt32(kVK_UpArrow): "↑", UInt32(kVK_DownArrow): "↓",
        UInt32(kVK_Help): "Help",
        UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2",
        UInt32(kVK_F3): "F3", UInt32(kVK_F4): "F4",
        UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6",
        UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8",
        UInt32(kVK_F9): "F9", UInt32(kVK_F10): "F10",
        UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
        UInt32(kVK_F13): "F13", UInt32(kVK_F14): "F14",
        UInt32(kVK_F15): "F15", UInt32(kVK_F16): "F16",
        UInt32(kVK_F17): "F17", UInt32(kVK_F18): "F18",
        UInt32(kVK_F19): "F19", UInt32(kVK_F20): "F20",
        UInt32(kVK_ANSI_Keypad0): "Num 0", UInt32(kVK_ANSI_Keypad1): "Num 1",
        UInt32(kVK_ANSI_Keypad2): "Num 2", UInt32(kVK_ANSI_Keypad3): "Num 3",
        UInt32(kVK_ANSI_Keypad4): "Num 4", UInt32(kVK_ANSI_Keypad5): "Num 5",
        UInt32(kVK_ANSI_Keypad6): "Num 6", UInt32(kVK_ANSI_Keypad7): "Num 7",
        UInt32(kVK_ANSI_Keypad8): "Num 8", UInt32(kVK_ANSI_Keypad9): "Num 9",
        UInt32(kVK_ANSI_KeypadDecimal): "Num .", UInt32(kVK_ANSI_KeypadMultiply): "Num ×",
        UInt32(kVK_ANSI_KeypadPlus): "Num +", UInt32(kVK_ANSI_KeypadClear): "Num Clear",
        UInt32(kVK_ANSI_KeypadDivide): "Num ÷", UInt32(kVK_ANSI_KeypadEnter): "Num ↩",
        UInt32(kVK_ANSI_KeypadMinus): "Num -", UInt32(kVK_ANSI_KeypadEquals): "Num ="
    ]

    fileprivate static func legacy(rawValue: String) -> GlobalShortcut? {
        switch rawValue {
        case "controlOptionV": .controlOptionV
        case "commandShiftV": .commandShiftV
        case "controlShiftV": .controlShiftV
        case "optionV": .optionV
        case "controlOptionF": .controlOptionF
        case "commandShiftF": .commandShiftF
        case "controlShiftF": .controlShiftF
        case "optionShiftV": .optionShiftV
        default: nil
        }
    }
}

enum SettingsChange: Equatable, Sendable {
    case shortcuts
    case monitoring
    case historySort
    case maxItems
    case other
}

@MainActor
@Observable
final class AppSettings {
    var isMonitoringEnabled: Bool {
        didSet { persistIfChanged("isMonitoringEnabled", isMonitoringEnabled, oldValue: oldValue, change: .monitoring) }
    }
    var maxItems: Int {
        didSet { persistIfChanged("maxItems", maxItems, oldValue: oldValue, change: .maxItems) }
    }
    var maxCaptureMegabytes: Int {
        didSet { persistIfChanged("maxCaptureMegabytes", maxCaptureMegabytes, oldValue: oldValue, change: .other) }
    }
    var pollInterval: Double {
        didSet { persistIfChanged("pollInterval", pollInterval, oldValue: oldValue, change: .monitoring) }
    }
    var historyShortcut: GlobalShortcut {
        didSet { persistShortcutIfChanged("historyShortcut", historyShortcut, oldValue: oldValue) }
    }
    var favoritesShortcut: GlobalShortcut {
        didSet { persistShortcutIfChanged("favoritesShortcut", favoritesShortcut, oldValue: oldValue) }
    }
    var closeAfterCopy: Bool {
        didSet { persistIfChanged("closeAfterCopy", closeAfterCopy, oldValue: oldValue, change: .other) }
    }
    var promotePastedItems: Bool {
        didSet { persistIfChanged("promotePastedItems", promotePastedItems, oldValue: oldValue, change: .historySort) }
    }
    var launchAtLogin: Bool {
        didSet { persistIfChanged("launchAtLogin", launchAtLogin, oldValue: oldValue, change: .other) }
    }

    @ObservationIgnored var onChange: ((SettingsChange) -> Void)?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var isInitializing = true

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isMonitoringEnabled = defaults.object(forKey: "isMonitoringEnabled") as? Bool ?? true
        self.maxItems = defaults.object(forKey: "maxItems") as? Int ?? 1_000
        self.maxCaptureMegabytes = defaults.object(forKey: "maxCaptureMegabytes") as? Int ?? 30
        self.pollInterval = defaults.object(forKey: "pollInterval") as? Double ?? 0.45
        self.historyShortcut = Self.loadShortcut(
            defaults: defaults,
            key: "historyShortcut",
            fallback: .defaultHistory
        )
        self.favoritesShortcut = Self.loadShortcut(
            defaults: defaults,
            key: "favoritesShortcut",
            fallback: .defaultFavorites
        )
        self.closeAfterCopy = defaults.object(forKey: "closeAfterCopy") as? Bool ?? true
        self.promotePastedItems = defaults.object(forKey: "promotePastedItems") as? Bool ?? false
        self.launchAtLogin = defaults.object(forKey: "launchAtLogin") as? Bool ?? false
        self.isInitializing = false

        // Always write the current format. This transparently migrates legacy preset strings.
        Self.storeShortcut(historyShortcut, defaults: defaults, key: "historyShortcut")
        Self.storeShortcut(favoritesShortcut, defaults: defaults, key: "favoritesShortcut")
    }

    func restoreShortcutsWithoutNotification(
        history: GlobalShortcut,
        favorites: GlobalShortcut
    ) {
        let wasInitializing = isInitializing
        isInitializing = true
        historyShortcut = history
        favoritesShortcut = favorites
        Self.storeShortcut(history, defaults: defaults, key: "historyShortcut")
        Self.storeShortcut(favorites, defaults: defaults, key: "favoritesShortcut")
        isInitializing = wasInitializing
    }

    private func persistIfChanged<Value: Equatable>(
        _ key: String,
        _ value: Value,
        oldValue: Value,
        change: SettingsChange
    ) {
        guard !isInitializing, value != oldValue else { return }
        defaults.set(value, forKey: key)
        onChange?(change)
    }

    private func persistShortcutIfChanged(
        _ key: String,
        _ value: GlobalShortcut,
        oldValue: GlobalShortcut
    ) {
        guard !isInitializing, value != oldValue else { return }
        Self.storeShortcut(value, defaults: defaults, key: key)
        onChange?(.shortcuts)
    }

    private static func loadShortcut(
        defaults: UserDefaults,
        key: String,
        fallback: GlobalShortcut
    ) -> GlobalShortcut {
        if let data = defaults.data(forKey: key),
           let shortcut = try? JSONDecoder().decode(GlobalShortcut.self, from: data) {
            return shortcut
        }
        if let rawValue = defaults.string(forKey: key),
           let shortcut = GlobalShortcut.legacy(rawValue: rawValue) {
            return shortcut
        }
        return fallback
    }

    private static func storeShortcut(
        _ shortcut: GlobalShortcut,
        defaults: UserDefaults,
        key: String
    ) {
        guard let data = try? JSONEncoder().encode(shortcut) else { return }
        defaults.set(data, forKey: key)
    }
}
