import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let configurationStore = TapConfigurationStore()
    private var listener: MotionTapListener?
    private var settingsWindowController: ShortcutSettingsWindowController?
    private var statusMenuItem: NSMenuItem!
    private var actionMenuItems: [Int: NSMenuItem] = [:]
    private var accessibilityTimer: Timer?
    private var isRelaunching = false
    private let accessibilityPromptedBuildKey = "accessibilityPromptedBuild"
    static let accessibilityRelaunchArgument = "--accessibility-relaunch"
    private var currentBuildStamp: String {
        guard let executableURL = Bundle.main.executableURL,
              let values = try? executableURL.resourceValues(forKeys: [.contentModificationDateKey]),
              let modifiedAt = values.contentModificationDate
        else { return Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown" }
        return String(modifiedAt.timeIntervalSinceReferenceDate)
    }

    private let thresholds: [(name: String, value: Float)] = [
        ("Very High", 0.006),
        ("High", 0.012),
        ("Normal", 0.020),
        ("Low", 0.032)
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.button?.image = NSImage(
            systemSymbolName: "hand.tap.fill",
            accessibilityDescription: "TapKey"
        )
        statusItem.menu = makeMenu()
        requestAccessibilityPermissionIfNeeded()
        watchForAccessibilityPermission()
        startListening()
        openShortcutSettings()
    }

    private func requestAccessibilityPermissionIfNeeded() {
        guard !ShortcutRunner.hasAccessibilityPermission else { return }
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: accessibilityPromptedBuildKey) != currentBuildStamp else { return }
        defaults.set(currentBuildStamp, forKey: accessibilityPromptedBuildKey)
        ShortcutRunner.requestAccessibilityPermission()
    }

    static func shouldWatchForAccessibilityPermission(hasAccess: Bool, arguments: [String]) -> Bool {
        !hasAccess && !arguments.contains(accessibilityRelaunchArgument)
    }

    private func watchForAccessibilityPermission() {
        guard Self.shouldWatchForAccessibilityPermission(
            hasAccess: ShortcutRunner.hasAccessibilityPermission,
            arguments: ProcessInfo.processInfo.arguments
        ) else { return }

        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard ShortcutRunner.hasAccessibilityPermission else { return }
            self?.relaunchAfterAccessibilityPermission()
        }
    }

    private func relaunchAfterAccessibilityPermission() {
        guard !isRelaunching else { return }
        isRelaunching = true
        accessibilityTimer?.invalidate()
        accessibilityTimer = nil
        listener?.stop()
        listener = nil
        statusMenuItem.title = "Accessibility enabled — restarting…"

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = [Self.accessibilityRelaunchArgument]
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL,
            configuration: configuration
        ) { [weak self] application, _ in
            DispatchQueue.main.async {
                guard application != nil else {
                    self?.isRelaunching = false
                    self?.statusMenuItem.title = "Restart TapKey to finish access"
                    self?.startListening()
                    return
                }
                NSApp.terminate(nil)
            }
        }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        statusMenuItem = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())

        let configure = NSMenuItem(
            title: "Configure Tap Actions…",
            action: #selector(openShortcutSettings),
            keyEquivalent: ""
        )
        configure.target = self
        menu.addItem(configure)

        for count in 1...3 {
            let item = NSMenuItem(title: actionTitle(for: count), action: nil, keyEquivalent: "")
            actionMenuItems[count] = item
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let sensitivity = NSMenuItem(title: "Sensitivity", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for (index, option) in thresholds.enumerated() {
            let item = NSMenuItem(title: option.name, action: #selector(changeSensitivity(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = index == savedSensitivityIndex ? .on : .off
            submenu.addItem(item)
        }
        sensitivity.submenu = submenu
        menu.addItem(sensitivity)
        menu.addItem(.separator())

        let permissions = NSMenuItem(title: "Open Privacy Settings…", action: #selector(openPrivacySettings), keyEquivalent: "")
        permissions.target = self
        menu.addItem(permissions)

        let quit = NSMenuItem(title: "Quit TapKey", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        return menu
    }

    private var savedSensitivityIndex: Int {
        let value = UserDefaults.standard.object(forKey: "sensitivity") as? Int ?? 0
        return thresholds.indices.contains(value) ? value : 0
    }

    private func startListening() {
        let listener = MotionTapListener(
            threshold: thresholds[savedSensitivityIndex].value,
            onReady: { [weak self] in
                self?.showIdleState()
            },
            onFailure: { [weak self] message in
                self?.statusMenuItem.title = message
            },
            onGesture: { [weak self] count in
                self?.runAction(for: count)
            }
        )

        do {
            try listener.start()
            self.listener = listener
            statusMenuItem.title = "Starting motion sensor…"
        } catch {
            statusMenuItem.title = "Could not start: \(error.localizedDescription)"
        }
    }

    private func runAction(for tapCount: Int) {
        let action = configurationStore.action(for: tapCount)
        switch action {
        case .disabled:
            showTemporaryStatus("\(tapCount) tap\(tapCount == 1 ? "" : "s") → No action")
        case let .shortcut(shortcut):
            let didRun = ShortcutRunner.run(shortcut)
            guard didRun else {
                statusMenuItem.title = "Accessibility access needed"
                return
            }
            showTemporaryStatus("Triggered \(shortcut.displayName)")
        case let .typeText(text):
            guard !text.isEmpty else {
                showTemporaryStatus("Add text for \(tapCount) tap\(tapCount == 1 ? "" : "s")")
                return
            }
            guard ShortcutRunner.typeText(text) else {
                statusMenuItem.title = "Accessibility access needed"
                return
            }
            showTemporaryStatus("Typed text")
        case let .openURL(address):
            guard let url = TapAction.resolvedURL(from: address), NSWorkspace.shared.open(url) else {
                showTemporaryStatus("Could not open URL")
                return
            }
            showTemporaryStatus("Opened \(url.host ?? url.absoluteString)")
        case let .openApplication(path):
            let url = URL(fileURLWithPath: path)
            guard !path.isEmpty,
                  FileManager.default.fileExists(atPath: path),
                  NSWorkspace.shared.open(url)
            else {
                showTemporaryStatus("Choose an installed application")
                return
            }
            showTemporaryStatus("Opened \(url.deletingPathExtension().lastPathComponent)")
        }
    }

    private func showTemporaryStatus(_ message: String) {
        statusMenuItem.title = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.showIdleState()
        }
    }

    private func showIdleState() {
        statusMenuItem.title = "Motion sensor active"
    }

    private func actionTitle(for tapCount: Int) -> String {
        let tap = tapCount == 1 ? "1 tap" : "\(tapCount) taps"
        return "\(tap) → \(configurationStore.action(for: tapCount).displayName)"
    }

    private func refreshActionMenu() {
        for count in 1...3 {
            actionMenuItems[count]?.title = actionTitle(for: count)
        }
    }

    @objc private func openShortcutSettings() {
        if settingsWindowController == nil {
            settingsWindowController = ShortcutSettingsWindowController(
                store: configurationStore,
                onChange: { [weak self] in self?.refreshActionMenu() }
            )
        }
        settingsWindowController?.showWindow(nil)
    }

    @objc private func changeSensitivity(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.tag, forKey: "sensitivity")
        listener?.setThreshold(thresholds[sender.tag].value)
        sender.menu?.items.forEach { $0.state = $0 === sender ? .on : .off }
    }

    @objc private func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openShortcutSettings()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        accessibilityTimer?.invalidate()
        listener?.stop()
    }
}
