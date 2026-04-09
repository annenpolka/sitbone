/// Ghost Teacherのキーボードショートカット設定
public struct KeyBinding: Sendable, Codable, Equatable {
    public var keyCode: UInt16
    /// NSEvent.ModifierFlags.rawValue のサブセット（Shift, Control, Option, Command）
    public var modifierFlags: UInt

    public init(keyCode: UInt16, modifierFlags: UInt = 0) {
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags
    }

    /// 表示用の文字列（例: "⌃F", "⎋"）
    public var displayString: String {
        var parts: [String] = []
        if modifierFlags & (1 << 18) != 0 { parts.append("⌃") }  // Control
        if modifierFlags & (1 << 19) != 0 { parts.append("⌥") }  // Option
        if modifierFlags & (1 << 17) != 0 { parts.append("⇧") }  // Shift
        if modifierFlags & (1 << 20) != 0 { parts.append("⌘") }  // Command
        parts.append(keyCodeName)
        return parts.joined()
    }

    // swiftlint:disable cyclomatic_complexity
    private var keyCodeName: String {
        switch keyCode {
        case 53: return "⎋"
        case 36: return "↩"
        case 48: return "⇥"
        case 49: return "Space"
        case 51: return "⌫"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default: return keyCodeToCharacter(keyCode)
        }
    }
    // swiftlint:enable cyclomatic_complexity
}

public struct GhostTeacherKeyBindings: Sendable, Codable, Equatable {
    public var flow: KeyBinding
    public var drift: KeyBinding
    public var dismiss: KeyBinding

    public init(
        flow: KeyBinding = KeyBinding(keyCode: 3, modifierFlags: 1 << 18),      // ⌃F
        drift: KeyBinding = KeyBinding(keyCode: 2, modifierFlags: 1 << 18),     // ⌃D
        dismiss: KeyBinding = KeyBinding(keyCode: 53)                            // Escape
    ) {
        self.flow = flow
        self.drift = drift
        self.dismiss = dismiss
    }
}

// MARK: - keyCode → 文字変換

private func keyCodeToCharacter(_ keyCode: UInt16) -> String {
    // US keyboard layout の主要キー
    let map: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
        23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L",
        38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
        45: "N", 46: "M", 47: ".",
    ]
    return map[keyCode] ?? "?\(keyCode)"
}
