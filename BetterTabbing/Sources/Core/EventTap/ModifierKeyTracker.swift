import CoreGraphics

enum ModifierKey: String, Codable, Hashable, CaseIterable {
    case command
    case shift
    case option
    case control

    var cgFlag: CGEventFlags {
        switch self {
        case .command: return .maskCommand
        case .shift: return .maskShift
        case .option: return .maskAlternate
        case .control: return .maskControl
        }
    }

    var symbol: String {
        switch self {
        case .command: return "⌘"
        case .shift: return "⇧"
        case .option: return "⌥"
        case .control: return "⌃"
        }
    }
}

final class ModifierKeyTracker {
    private(set) var currentFlags: CGEventFlags = []

    var isCommandPressed: Bool { currentFlags.contains(.maskCommand) }
    var isShiftPressed: Bool { currentFlags.contains(.maskShift) }
    var isOptionPressed: Bool { currentFlags.contains(.maskAlternate) }
    var isControlPressed: Bool { currentFlags.contains(.maskControl) }

    func update(flags: CGEventFlags) {
        currentFlags = flags
    }

    func matches(_ modifiers: Set<ModifierKey>) -> Bool {
        let current = currentModifierSet()
        return current == modifiers
    }

    func contains(_ modifiers: Set<ModifierKey>) -> Bool {
        let current = currentModifierSet()
        return modifiers.isSubset(of: current)
    }

    func currentModifierSet() -> Set<ModifierKey> {
        var result = Set<ModifierKey>()
        if isCommandPressed { result.insert(.command) }
        if isShiftPressed { result.insert(.shift) }
        if isOptionPressed { result.insert(.option) }
        if isControlPressed { result.insert(.control) }
        return result
    }

    func wasModifierReleased(oldFlags: CGEventFlags, newFlags: CGEventFlags, modifier: ModifierKey) -> Bool {
        let wasPressed = oldFlags.contains(modifier.cgFlag)
        let isPressed = newFlags.contains(modifier.cgFlag)
        return wasPressed && !isPressed
    }
}
