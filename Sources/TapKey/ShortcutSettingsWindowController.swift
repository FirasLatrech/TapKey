import AppKit
import CoreGraphics
import UniformTypeIdentifiers

final class ShortcutSettingsWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    private let store: TapConfigurationStore
    private let onChange: () -> Void
    private var actionPopups: [Int: NSPopUpButton] = [:]
    private var shortcutButtons: [Int: NSButton] = [:]
    private var valueFields: [Int: NSTextField] = [:]
    private var applicationButtons: [Int: NSButton] = [:]
    private var noneLabels: [Int: NSTextField] = [:]
    private let feedbackLabel = NSTextField(labelWithString: "Choose what each tap should do.")
    private let accessibilityLabel = NSTextField(labelWithString: "")
    private let allowAccessButton = NSButton(title: "Allow Access…", target: nil, action: nil)
    private var recordingTapCount: Int?
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var levelBeforeRecording: NSWindow.Level?
    private var pendingShortcut: KeyboardShortcut?
    private var capturedKeyCode: UInt16?

    private static let keyboardEventMask = [CGEventType.keyDown, .keyUp, .flagsChanged]
        .reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }

    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let controller = Unmanaged<ShortcutSettingsWindowController>
            .fromOpaque(userInfo)
            .takeUnretainedValue()
        return controller.handleGlobalEvent(type: type, event: event)
    }

    init(store: TapConfigurationStore, onChange: @escaping () -> Void) {
        self.store = store
        self.onChange = onChange

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 390),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "TapKey"
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
        window.delegate = self
        buildContent()
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func showWindow(_ sender: Any?) {
        refresh()
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildContent() {
        guard let contentView = window?.contentView else {
            preconditionFailure("Settings window requires a content view")
        }

        let title = NSTextField(labelWithString: "Tap actions")
        title.font = .systemFont(ofSize: 22, weight: .semibold)

        let subtitle = NSTextField(labelWithString: "Choose an action, then customize its value.")
        subtitle.textColor = .secondaryLabelColor

        let actions = NSStackView()
        actions.orientation = .vertical
        actions.alignment = .leading
        actions.spacing = 10

        for count in 1...3 {
            let tapName = tapLabel(count)
            let label = NSTextField(labelWithString: tapName)
            label.font = .systemFont(ofSize: 13, weight: .medium)
            label.alignment = .right
            label.widthAnchor.constraint(equalToConstant: 58).isActive = true

            let actionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
            ["None", "Keyboard Shortcut", "Type Text", "Open URL", "Open Application"]
                .enumerated()
                .forEach { index, title in
                    actionPopup.addItem(withTitle: title)
                    actionPopup.lastItem?.tag = index
                }
            actionPopup.tag = count
            actionPopup.target = self
            actionPopup.action = #selector(changeActionType(_:))
            actionPopup.widthAnchor.constraint(equalToConstant: 150).isActive = true
            actionPopup.setAccessibilityLabel("Action for \(tapName)")
            actionPopups[count] = actionPopup

            let shortcutButton = NSButton(title: "", target: self, action: #selector(startRecording(_:)))
            shortcutButton.tag = count
            shortcutButton.bezelStyle = .rounded
            shortcutButton.controlSize = .large
            shortcutButton.alignment = .center
            shortcutButton.font = .monospacedSystemFont(ofSize: 14, weight: .medium)
            shortcutButton.widthAnchor.constraint(equalToConstant: 360).isActive = true
            shortcutButton.heightAnchor.constraint(equalToConstant: 34).isActive = true
            shortcutButton.toolTip = "Record shortcut for \(tapName)"
            shortcutButtons[count] = shortcutButton

            let valueField = NSTextField()
            valueField.tag = count
            valueField.delegate = self
            valueField.widthAnchor.constraint(equalToConstant: 360).isActive = true
            valueField.heightAnchor.constraint(equalToConstant: 34).isActive = true
            valueFields[count] = valueField

            let applicationButton = NSButton(
                title: "Choose Application…",
                target: self,
                action: #selector(chooseApplication(_:))
            )
            applicationButton.tag = count
            applicationButton.bezelStyle = .rounded
            applicationButton.controlSize = .large
            applicationButton.alignment = .left
            applicationButton.widthAnchor.constraint(equalToConstant: 360).isActive = true
            applicationButton.heightAnchor.constraint(equalToConstant: 34).isActive = true
            applicationButton.setAccessibilityLabel("Application for \(tapName)")
            applicationButtons[count] = applicationButton

            let noneLabel = NSTextField(labelWithString: "No action")
            noneLabel.textColor = .tertiaryLabelColor
            noneLabel.widthAnchor.constraint(equalToConstant: 360).isActive = true
            noneLabels[count] = noneLabel

            let editor = NSStackView(views: [noneLabel, shortcutButton, valueField, applicationButton])
            editor.orientation = .vertical
            editor.alignment = .leading
            editor.spacing = 0
            editor.widthAnchor.constraint(equalToConstant: 360).isActive = true

            let row = NSStackView(views: [label, actionPopup, editor])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 12
            actions.addArrangedSubview(row)
        }

        feedbackLabel.font = .systemFont(ofSize: 12)
        feedbackLabel.textColor = .secondaryLabelColor
        feedbackLabel.maximumNumberOfLines = 2
        feedbackLabel.lineBreakMode = .byWordWrapping
        feedbackLabel.setAccessibilityLabel("Action status")

        let separator = NSBox()
        separator.boxType = .separator

        accessibilityLabel.font = .systemFont(ofSize: 12)
        accessibilityLabel.textColor = .secondaryLabelColor
        accessibilityLabel.maximumNumberOfLines = 2
        accessibilityLabel.lineBreakMode = .byWordWrapping
        accessibilityLabel.setAccessibilityLabel("Accessibility permission status")

        allowAccessButton.target = self
        allowAccessButton.action = #selector(allowAccessibilityAccess)
        allowAccessButton.bezelStyle = .rounded
        allowAccessButton.setAccessibilityLabel("Allow Accessibility access for TapKey")

        let accessRow = NSStackView(views: [accessibilityLabel, allowAccessButton])
        accessRow.orientation = .horizontal
        accessRow.alignment = .centerY
        accessRow.spacing = 12
        accessibilityLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        allowAccessButton.setContentHuggingPriority(.required, for: .horizontal)

        let stack = NSStackView(views: [title, subtitle, actions, feedbackLabel, separator, accessRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.setCustomSpacing(4, after: title)
        stack.setCustomSpacing(20, after: subtitle)
        stack.setCustomSpacing(10, after: actions)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            actions.widthAnchor.constraint(equalTo: stack.widthAnchor),
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor),
            accessRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            feedbackLabel.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    private func refresh() {
        for count in 1...3 {
            let action = store.action(for: count)
            let actionTag: Int
            shortcutButtons[count]?.isHidden = true
            valueFields[count]?.isHidden = true
            applicationButtons[count]?.isHidden = true
            noneLabels[count]?.isHidden = true

            switch action {
            case .disabled:
                actionTag = 0
                noneLabels[count]?.isHidden = false
            case let .shortcut(shortcut):
                actionTag = 1
                shortcutButtons[count]?.title = shortcut.displayName
                shortcutButtons[count]?.setAccessibilityLabel(
                    "Shortcut for \(tapLabel(count)), currently \(shortcut.displayName)"
                )
                shortcutButtons[count]?.setAccessibilityHelp("Press to record a new keyboard shortcut")
                shortcutButtons[count]?.isHidden = false
            case let .typeText(text):
                actionTag = 2
                valueFields[count]?.placeholderString = "Text to type"
                valueFields[count]?.stringValue = text
                valueFields[count]?.setAccessibilityLabel("Text for \(tapLabel(count))")
                valueFields[count]?.isHidden = false
            case let .openURL(address):
                actionTag = 3
                valueFields[count]?.placeholderString = "https://example.com"
                valueFields[count]?.stringValue = address
                valueFields[count]?.setAccessibilityLabel("URL for \(tapLabel(count))")
                valueFields[count]?.isHidden = false
            case let .openApplication(path):
                actionTag = 4
                applicationButtons[count]?.title = path.isEmpty
                    ? "Choose Application…"
                    : URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                applicationButtons[count]?.isHidden = false
            }
            actionPopups[count]?.selectItem(withTag: actionTag)
        }
        updateAccessibilityStatus()
    }

    @objc private func changeActionType(_ sender: NSPopUpButton) {
        let selectedTag = sender.selectedItem?.tag
        let count = sender.tag
        stopRecording(message: nil)
        let current = store.action(for: count)

        switch selectedTag {
        case 0:
            commit(.disabled, for: count, message: "Cleared \(tapLabel(count)).")
        case 1:
            refresh()
            if case .shortcut = current { return }
            if let button = shortcutButtons[count] { startRecording(button) }
        case 2:
            let text = if case let .typeText(text) = current { text } else { "" }
            commit(.typeText(text), for: count, message: "Enter the text TapKey should type.")
            window?.makeFirstResponder(valueFields[count])
        case 3:
            let address = if case let .openURL(address) = current { address } else { "" }
            commit(.openURL(address), for: count, message: "Enter the URL TapKey should open.")
            window?.makeFirstResponder(valueFields[count])
        case 4:
            presentApplicationPicker(for: count)
        default:
            preconditionFailure("Unknown tap action type")
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              let type = actionPopups[field.tag]?.selectedItem?.tag
        else { return }

        switch type {
        case 2: store.set(.typeText(field.stringValue), for: field.tag)
        case 3: store.set(.openURL(field.stringValue), for: field.tag)
        default: return
        }
        onChange()
    }

    @objc private func chooseApplication(_ sender: NSButton) {
        presentApplicationPicker(for: sender.tag)
    }

    private func presentApplicationPicker(for count: Int) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose an application"
        panel.prompt = "Choose"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .OK, let url = panel.url else {
                self.refresh()
                return
            }
            self.commit(
                .openApplication(url.path),
                for: count,
                message: "Saved: \(self.tapLabel(count)) → \(url.deletingPathExtension().lastPathComponent)"
            )
        }
    }

    @objc private func startRecording(_ sender: NSButton) {
        stopRecording(message: nil)
        guard ShortcutRunner.hasAccessibilityPermission else {
            ShortcutRunner.requestAccessibilityPermission()
            feedbackLabel.stringValue = "Allow Accessibility access before recording shortcuts."
            updateAccessibilityStatus()
            return
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: Self.keyboardEventMask,
            callback: Self.eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            feedbackLabel.stringValue = "Recording could not start. Check Accessibility access and try again."
            return
        }

        recordingTapCount = sender.tag
        eventTap = tap
        eventTapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        guard CGEvent.tapIsEnabled(tap: tap) else {
            stopRecording(message: "Recording could not start. Check Accessibility access and try again.")
            return
        }

        levelBeforeRecording = window?.level
        window?.level = .floating
        sender.title = "Press keys…"
        shortcutButtons.values.forEach { $0.isEnabled = $0 === sender }
        actionPopups.values.forEach { $0.isEnabled = false }
        valueFields.values.forEach { $0.isEnabled = false }
        applicationButtons.values.forEach { $0.isEnabled = false }
        feedbackLabel.stringValue = "Hold modifier keys, then press one key. Escape cancels."
        window?.makeKeyAndOrderFront(nil)
    }

    private func handleGlobalEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return nil
        }
        guard let count = recordingTapCount else { return Unmanaged.passUnretained(event) }

        switch type {
        case .flagsChanged:
            let symbols = modifiers(from: event.flags).displayName
            shortcutButtons[count]?.title = symbols.isEmpty ? "Press keys…" : "\(symbols)…"
            feedbackLabel.stringValue = symbols.isEmpty
                ? "Hold modifier keys, then press one key. Escape cancels."
                : "\(symbols) held — now press one key."

        case .keyDown:
            guard capturedKeyCode == nil else { return nil }
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            capturedKeyCode = keyCode
            if keyCode == 53 {
                feedbackLabel.stringValue = "Cancelling…"
            } else {
                let shortcut = KeyboardShortcut(
                    keyCode: keyCode,
                    modifiers: modifiers(from: event.flags),
                    keyName: keyName(for: keyCode)
                )
                pendingShortcut = shortcut
                shortcutButtons[count]?.title = shortcut.displayName
                feedbackLabel.stringValue = "Release the keys to save."
            }

        case .keyUp:
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            guard keyCode == capturedKeyCode else { return nil }
            let shortcut = pendingShortcut
            DispatchQueue.main.async { [weak self] in
                if let shortcut {
                    self?.save(shortcut, for: count)
                } else {
                    self?.stopRecording(message: "Recording cancelled.")
                }
            }

        default:
            return Unmanaged.passUnretained(event)
        }
        return nil
    }

    private func modifiers(from flags: CGEventFlags) -> ShortcutModifiers {
        var modifiers: ShortcutModifiers = []
        if flags.contains(.maskCommand) { modifiers.insert(.command) }
        if flags.contains(.maskShift) { modifiers.insert(.shift) }
        if flags.contains(.maskAlternate) { modifiers.insert(.option) }
        if flags.contains(.maskControl) { modifiers.insert(.control) }
        return modifiers
    }

    private func tearDownEventTap() {
        if let eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
        }
        if let eventTap { CFMachPortInvalidate(eventTap) }
        eventTapSource = nil
        eventTap = nil
    }

    private func save(_ shortcut: KeyboardShortcut, for count: Int) {
        stopRecording(message: nil)
        commit(
            .shortcut(shortcut),
            for: count,
            message: "Saved: \(tapLabel(count)) → \(shortcut.displayName)"
        )
    }

    private func commit(_ action: TapAction, for count: Int, message: String) {
        store.set(action, for: count)
        refresh()
        feedbackLabel.stringValue = message
        onChange()
    }

    @objc private func allowAccessibilityAccess() {
        ShortcutRunner.requestAccessibilityPermission()
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
        feedbackLabel.stringValue = "Turn on TapKey in Accessibility. TapKey will restart automatically."
    }

    private func updateAccessibilityStatus() {
        let allowed = ShortcutRunner.hasAccessibilityPermission
        accessibilityLabel.stringValue = allowed
            ? "Accessibility allowed — keyboard actions are ready."
            : "Accessibility is needed for keyboard actions."
        accessibilityLabel.textColor = allowed ? .secondaryLabelColor : .labelColor
        allowAccessButton.isHidden = allowed
    }

    private func stopRecording(message: String?) {
        tearDownEventTap()
        if let levelBeforeRecording { window?.level = levelBeforeRecording }
        levelBeforeRecording = nil
        recordingTapCount = nil
        pendingShortcut = nil
        capturedKeyCode = nil
        shortcutButtons.values.forEach { $0.isEnabled = true }
        actionPopups.values.forEach { $0.isEnabled = true }
        valueFields.values.forEach { $0.isEnabled = true }
        applicationButtons.values.forEach { $0.isEnabled = true }
        refresh()
        if let message { feedbackLabel.stringValue = message }
    }

    private func tapLabel(_ count: Int) -> String {
        count == 1 ? "1 tap" : "\(count) taps"
    }

    private func keyName(for keyCode: UInt16) -> String {
        KeyboardShortcut.standardKeyName(for: keyCode) ?? "Key \(keyCode)"
    }

    func windowDidBecomeKey(_ notification: Notification) {
        updateAccessibilityStatus()
    }

    func windowWillClose(_ notification: Notification) {
        stopRecording(message: nil)
    }

    deinit {
        tearDownEventTap()
    }

}
