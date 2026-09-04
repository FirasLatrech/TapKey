import AppKit
import CoreGraphics

struct ShortcutKeyEvent: Equatable {
    let keyCode: CGKeyCode
    let isKeyDown: Bool
    let flags: CGEventFlags
}

enum ShortcutRunner {
    static var hasAccessibilityPermission: Bool {
        CGPreflightPostEventAccess()
    }

    static func requestAccessibilityPermission() {
        _ = CGRequestPostEventAccess()
    }

    @discardableResult
    static func run(_ shortcut: KeyboardShortcut) -> Bool {
        guard hasAccessibilityPermission,
              let source = CGEventSource(stateID: .hidSystemState)
        else { return false }

        let steps = eventSequence(for: shortcut)
        let events = steps.compactMap { step -> CGEvent? in
            guard let event = CGEvent(
                keyboardEventSource: source,
                virtualKey: step.keyCode,
                keyDown: step.isKeyDown
            ) else { return nil }
            event.flags = step.flags
            return event
        }
        guard events.count == steps.count else { return false }
        events.forEach { $0.post(tap: .cghidEventTap) }
        return true
    }

    @discardableResult
    static func typeText(_ text: String) -> Bool {
        guard !text.isEmpty, hasAccessibilityPermission else { return false }

        let pasteboard = NSPasteboard.general
        let savedItems = pasteboard.pasteboardItems?.map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }

        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            restorePasteboard(savedItems, on: pasteboard)
            return false
        }
        let textChangeCount = pasteboard.changeCount
        let paste = KeyboardShortcut(keyCode: 9, modifiers: .command, keyName: "V")
        guard run(paste) else {
            restorePasteboard(savedItems, on: pasteboard)
            return false
        }

        // ponytail: Paste delivery has no completion callback; keep the delay unless a target app proves slower.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard pasteboard.changeCount == textChangeCount else { return }
            restorePasteboard(savedItems, on: pasteboard)
        }
        return true
    }

    private static func restorePasteboard(_ items: [NSPasteboardItem]?, on pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        if let items, !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }

    static func eventSequence(for shortcut: KeyboardShortcut) -> [ShortcutKeyEvent] {
        let modifierKeys: [(ShortcutModifiers, CGKeyCode, CGEventFlags)] = [
            (.command, 55, .maskCommand),
            (.shift, 56, .maskShift),
            (.option, 58, .maskAlternate),
            (.control, 59, .maskControl)
        ]
        var flags: CGEventFlags = []
        var events: [ShortcutKeyEvent] = []

        for (modifier, keyCode, flag) in modifierKeys where shortcut.modifiers.contains(modifier) {
            flags.insert(flag)
            events.append(ShortcutKeyEvent(keyCode: keyCode, isKeyDown: true, flags: flags))
        }
        events.append(ShortcutKeyEvent(keyCode: shortcut.keyCode, isKeyDown: true, flags: flags))
        events.append(ShortcutKeyEvent(keyCode: shortcut.keyCode, isKeyDown: false, flags: flags))
        for (modifier, keyCode, flag) in modifierKeys.reversed() where shortcut.modifiers.contains(modifier) {
            flags.remove(flag)
            events.append(ShortcutKeyEvent(keyCode: keyCode, isKeyDown: false, flags: flags))
        }
        return events
    }
}
