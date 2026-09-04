import AppKit

struct ShortcutModifiers: OptionSet, Codable, Equatable {
    let rawValue: UInt8

    static let command = Self(rawValue: 1 << 0)
    static let shift = Self(rawValue: 1 << 1)
    static let option = Self(rawValue: 1 << 2)
    static let control = Self(rawValue: 1 << 3)

    static func from(_ flags: NSEvent.ModifierFlags) -> Self {
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        var result: Self = []
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.control) { result.insert(.control) }
        return result
    }

    var displayName: String {
        [
            contains(.command) ? "⌘" : "",
            contains(.shift) ? "⇧" : "",
            contains(.option) ? "⌥" : "",
            contains(.control) ? "⌃" : ""
        ].joined()
    }
}

struct KeyboardShortcut: Codable, Equatable {
    let keyCode: UInt16
    let modifiers: ShortcutModifiers
    let keyName: String

    static let commandShiftD = Self(
        keyCode: 2,
        modifiers: [.command, .shift],
        keyName: "D"
    )

    var displayName: String {
        modifiers.displayName + (Self.standardKeyName(for: keyCode) ?? keyName)
    }

    static func standardKeyName(for keyCode: UInt16) -> String? {
        standardKeyNames[keyCode]
    }

    private static let standardKeyNames: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y",
        17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
        24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]",
        31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "Return", 37: "L",
        38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N",
        46: "M", 47: ".", 48: "Tab", 49: "Space", 50: "`", 51: "Delete", 53: "Escape",
        64: "F17", 65: "Keypad .", 67: "Keypad *", 69: "Keypad +", 71: "Clear",
        75: "Keypad /", 76: "Enter", 78: "Keypad -", 79: "F18", 80: "F19",
        81: "Keypad =", 82: "Keypad 0", 83: "Keypad 1", 84: "Keypad 2", 85: "Keypad 3",
        86: "Keypad 4", 87: "Keypad 5", 88: "Keypad 6", 89: "Keypad 7", 90: "F20",
        91: "Keypad 8", 92: "Keypad 9", 96: "F5",
        97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11",
        105: "F13", 106: "F16", 107: "F14", 109: "F10", 111: "F12", 113: "F15",
        114: "Help", 115: "Home", 116: "Page Up", 117: "Forward Delete", 118: "F4",
        119: "End", 120: "F2", 121: "Page Down", 122: "F1", 123: "←", 124: "→",
        125: "↓", 126: "↑"
    ]
}

enum TapAction: Codable, Equatable {
    case disabled
    case shortcut(KeyboardShortcut)
    case typeText(String)
    case openURL(String)
    case openApplication(String)

    var displayName: String {
        switch self {
        case .disabled: "None"
        case let .shortcut(shortcut): shortcut.displayName
        case let .typeText(text):
            "Type \(Self.preview(text, empty: "text…"))"
        case let .openURL(address):
            "Open \(Self.preview(address, empty: "URL…"))"
        case let .openApplication(path):
            path.isEmpty
                ? "Open Application…"
                : "Open \(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)"
        }
    }

    static func resolvedURL(from address: String) -> URL? {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return nil }
        if let url = URL(string: address), url.scheme != nil { return url }
        return URL(string: "https://\(address)")
    }

    private static func preview(_ value: String, empty placeholder: String) -> String {
        let value = value.replacingOccurrences(of: "\n", with: " ")
        guard !value.isEmpty else { return placeholder }
        return value.count > 24 ? "\(value.prefix(24))…" : value
    }
}

struct TapConfiguration: Codable, Equatable {
    var oneTap: TapAction
    var twoTaps: TapAction
    var threeTaps: TapAction

    static let defaults = Self(
        oneTap: .disabled,
        twoTaps: .shortcut(.commandShiftD),
        threeTaps: .disabled
    )

    func action(for tapCount: Int) -> TapAction {
        switch tapCount {
        case 1: oneTap
        case 2: twoTaps
        case 3: threeTaps
        default: preconditionFailure("Tap count must be between 1 and 3")
        }
    }

    mutating func set(_ action: TapAction, for tapCount: Int) {
        switch tapCount {
        case 1: oneTap = action
        case 2: twoTaps = action
        case 3: threeTaps = action
        default: preconditionFailure("Tap count must be between 1 and 3")
        }
    }
}

final class TapConfigurationStore {
    private static let key = "tapConfiguration"
    private let defaults: UserDefaults
    private(set) var configuration: TapConfiguration

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        configuration = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(TapConfiguration.self, from: $0) }
            ?? .defaults
    }

    func action(for tapCount: Int) -> TapAction {
        configuration.action(for: tapCount)
    }

    func set(_ action: TapAction, for tapCount: Int) {
        configuration.set(action, for: tapCount)
        guard let data = try? JSONEncoder().encode(configuration) else {
            assertionFailure("Tap configuration could not be encoded")
            return
        }
        defaults.set(data, forKey: Self.key)
    }
}
