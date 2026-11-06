import Foundation

struct EditorModifiers: OptionSet, Codable, Hashable {
    let rawValue: UInt8
    static let shift = Self(rawValue: 1 << 0)
    static let control = Self(rawValue: 1 << 1)
    static let option = Self(rawValue: 1 << 2)
    static let command = Self(rawValue: 1 << 3)
}

struct EditorKey: Codable, Hashable {
    let code: UInt16
    let modifiers: EditorModifiers

    init(code: UInt16, modifiers: EditorModifiers = []) {
        self.code = code == 76 ? 36 : code
        self.modifiers = modifiers
    }

    private enum CodingKeys: String, CodingKey { case code, modifiers }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(code: try values.decode(UInt16.self, forKey: .code),
                  modifiers: try values.decode(EditorModifiers.self, forKey: .modifiers))
    }

    static let previous = EditorKey(code: 48, modifiers: .shift)
    private static let ansiKeys: [UInt16: String] = [
        0:"A", 1:"S", 2:"D", 3:"F", 4:"H", 5:"G", 6:"Z", 7:"X", 8:"C", 9:"V",
        11:"B", 12:"Q", 13:"W", 14:"E", 15:"R", 16:"Y", 17:"T", 18:"1", 19:"2",
        20:"3", 21:"4", 22:"6", 23:"5", 25:"9", 26:"7", 28:"8", 29:"0", 31:"O",
        32:"U", 34:"I", 35:"P", 37:"L", 38:"J", 40:"K", 45:"N", 46:"M"
    ]

    var keyName: String {
        switch code {
        case 36: return "Enter"
        case 48: return "Tab"
        default: return Self.ansiKeys[code] ?? "键 \(code)"
        }
    }

    var label: String {
        (modifiers.contains(.control) ? "⌃" : "") +
        (modifiers.contains(.option) ? "⌥" : "") +
        (modifiers.contains(.shift) ? "⇧" : "") +
        (modifiers.contains(.command) ? "⌘" : "") + keyName
    }

    var accessibleLabel: String {
        var names: [String] = []
        if modifiers.contains(.control) { names.append("Control") }
        if modifiers.contains(.option) { names.append("Option") }
        if modifiers.contains(.shift) { names.append("Shift") }
        if modifiers.contains(.command) { names.append("Command") }
        return (names + [keyName]).joined(separator: " 加 ")
    }

    var validationMessage: String? {
        if code == 53 { return "Esc 用于取消录制。" }
        if self == .previous { return "Shift + Tab 已用于返回上一栏。" }
        if modifiers.contains(.command) { return "Command 组合保留给系统和应用操作。" }
        if code == 49 && modifiers.contains(.control) { return "Control + 空格保留给系统输入法。" }
        if code == 36 && (modifiers.isEmpty || modifiers == .shift || modifiers == .control || modifiers == [.control, .shift]) { return nil }
        if code == 48 && modifiers.isEmpty { return nil }
        if Self.ansiKeys[code] != nil && modifiers == [.control, .shift] { return nil }
        if modifiers.isEmpty { return "请选择 Enter、Tab，或使用支持的修饰键组合。" }
        return "不支持该组合。可使用 Shift 或 Control 加 Enter，或 Control + Shift 加字母或数字。"
    }
}

enum EditorAction: Equatable {
    case newline, next, previous
    var title: String {
        switch self {
        case .newline: return "换行"
        case .next: return "下一栏"
        case .previous: return "上一栏"
        }
    }
}

struct EditorShortcuts: Codable, Equatable {
    static let storageKey = "editorShortcutsV1"
    static let standard = Self(newline: .init(code: 36), next: .init(code: 48))
    var newline: EditorKey
    var next: EditorKey

    var isValid: Bool {
        newline.validationMessage == nil && next.validationMessage == nil && newline != next
    }

    func issue(with key: EditorKey, for action: EditorAction) -> String? {
        if let issue = key.validationMessage { return issue }
        if action == .newline && key == next { return "该快捷键已用于「下一栏」。" }
        if action == .next && key == newline { return "该快捷键已用于「换行」。" }
        return nil
    }

    func action(for key: EditorKey, marked: Bool = false, repeating: Bool = false) -> EditorAction? {
        guard !marked, !repeating else { return nil }
        if key == .previous { return .previous }
        if key == newline { return .newline }
        if key == next { return .next }
        return nil
    }

    static func load(from defaults: UserDefaults) -> Self {
        if let data = defaults.data(forKey: storageKey) {
            guard let decoded = try? JSONDecoder().decode(Self.self, from: data), decoded.isValid else { return .standard }
            return decoded
        }
        if defaults.string(forKey: "editingMode") == "quick" {
            return Self(newline: .init(code: 36, modifiers: .shift), next: .init(code: 36))
        }
        return .standard
    }

    enum ValidationError: Error { case invalidBindings }

    func save(to defaults: UserDefaults) throws {
        guard isValid else { throw ValidationError.invalidBindings }
        defaults.set(try JSONEncoder().encode(self), forKey: Self.storageKey)
    }
}
