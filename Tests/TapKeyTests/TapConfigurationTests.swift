import AppKit
import XCTest
@testable import TapKey

final class TapConfigurationTests: XCTestCase {
    func testAccessibilityWatcherRunsOnlyBeforeThePermissionRelaunch() {
        XCTAssertTrue(AppDelegate.shouldWatchForAccessibilityPermission(hasAccess: false, arguments: []))
        XCTAssertFalse(AppDelegate.shouldWatchForAccessibilityPermission(hasAccess: true, arguments: []))
        XCTAssertFalse(AppDelegate.shouldWatchForAccessibilityPermission(
            hasAccess: false,
            arguments: [AppDelegate.accessibilityRelaunchArgument]
        ))
    }

    func testCustomShortcutDisplaysAndPersists() throws {
        let suiteName = "TapConfigurationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let shortcut = KeyboardShortcut(
            keyCode: 49,
            modifiers: .from([.command, .option]),
            keyName: "Space"
        )
        let store = TapConfigurationStore(defaults: defaults)
        store.set(.shortcut(shortcut), for: 3)

        XCTAssertEqual(shortcut.displayName, "⌘⌥Space")
        XCTAssertEqual(
            ShortcutModifiers.from([.command, .shift, .option, .control]).displayName,
            "⌘⇧⌥⌃"
        )
        XCTAssertEqual(TapConfigurationStore(defaults: defaults).action(for: 3), .shortcut(shortcut))

        XCTAssertEqual(
            KeyboardShortcut(keyCode: 23, modifiers: [.command, .shift], keyName: "%").displayName,
            "⌘⇧5"
        )
        XCTAssertEqual(
            KeyboardShortcut(keyCode: 2, modifiers: [.command, .shift], keyName: "ى").displayName,
            "⌘⇧D"
        )
    }

    func testCommandShiftShortcutPostsACompleteChord() {
        XCTAssertEqual(
            ShortcutRunner.eventSequence(for: .commandShiftD),
            [
                ShortcutKeyEvent(keyCode: 55, isKeyDown: true, flags: .maskCommand),
                ShortcutKeyEvent(keyCode: 56, isKeyDown: true, flags: [.maskCommand, .maskShift]),
                ShortcutKeyEvent(keyCode: 2, isKeyDown: true, flags: [.maskCommand, .maskShift]),
                ShortcutKeyEvent(keyCode: 2, isKeyDown: false, flags: [.maskCommand, .maskShift]),
                ShortcutKeyEvent(keyCode: 56, isKeyDown: false, flags: .maskCommand),
                ShortcutKeyEvent(keyCode: 55, isKeyDown: false, flags: [])
            ]
        )
    }

    func testEveryActionRoundTripsWithUsefulDisplayNames() throws {
        let actions: [TapAction] = [
            .disabled,
            .shortcut(.commandShiftD),
            .typeText("Hello from TapKey"),
            .openURL("example.com"),
            .openApplication("/Applications/Safari.app")
        ]

        let data = try JSONEncoder().encode(actions)
        XCTAssertEqual(try JSONDecoder().decode([TapAction].self, from: data), actions)
        XCTAssertEqual(actions.map(\.displayName), [
            "None",
            "⌘⇧D",
            "Type Hello from TapKey",
            "Open example.com",
            "Open Safari"
        ])
        XCTAssertEqual(TapAction.resolvedURL(from: "example.com")?.absoluteString, "https://example.com")
        XCTAssertEqual(TapAction.resolvedURL(from: "mailto:hello@example.com")?.scheme, "mailto")
    }

    func testLegacySavedShortcutsStillDecode() throws {
        let data = Data(#"{"twoTaps":{"shortcut":{"_0":{"modifiers":3,"keyName":"D","keyCode":2}}},"threeTaps":{"disabled":{}},"oneTap":{"disabled":{}}}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(TapConfiguration.self, from: data), .defaults)
    }
}
