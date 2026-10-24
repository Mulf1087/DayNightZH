import AppKit
import Carbon
import CoreGraphics
import Foundation

private enum PreferenceKey {
    static let scheduled = "scheduled"
    static let darkStart = "darkStart"
    static let lightStart = "lightStart"
    static let hotkeyEnabled = "hotkeyEnabled"
    static let hotkeyCode = "hotkeyCode"
    static let hotkeyModifiers = "hotkeyModifiers"
    static let hotkeyLabel = "hotkeyLabel"
}

@MainActor
final class DayNightApp: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var lightItem: NSMenuItem!
    private var darkItem: NSMenuItem!
    private var scheduleItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var hotkeyItem: NSMenuItem!
    private var hotkeyRef: EventHotKeyRef?
    private var hotkeyHandler: EventHandlerRef?
    private var modifierTap: CFMachPort?
    private var modifierSource: CFRunLoopSource?
    private var modifierChord: CGEventFlags = []
    private var modifierLatched = false
    private var timer: Timer?
    private var lastAppliedDark: Bool?
    private let defaults = UserDefaults.standard
    private let launchAgentName = "cn.liming.daynightzh.plist"
    private static let hotkeyKeys: [(String, Int)] = [
        ("无（仅用两个修饰键）", -1),
        ("A", Int(kVK_ANSI_A)), ("B", Int(kVK_ANSI_B)), ("C", Int(kVK_ANSI_C)),
        ("D", Int(kVK_ANSI_D)), ("E", Int(kVK_ANSI_E)), ("F", Int(kVK_ANSI_F)),
        ("G", Int(kVK_ANSI_G)), ("H", Int(kVK_ANSI_H)), ("I", Int(kVK_ANSI_I)),
        ("J", Int(kVK_ANSI_J)), ("K", Int(kVK_ANSI_K)), ("L", Int(kVK_ANSI_L)),
        ("M", Int(kVK_ANSI_M)), ("N", Int(kVK_ANSI_N)), ("O", Int(kVK_ANSI_O)),
        ("P", Int(kVK_ANSI_P)), ("Q", Int(kVK_ANSI_Q)), ("R", Int(kVK_ANSI_R)),
        ("S", Int(kVK_ANSI_S)), ("T", Int(kVK_ANSI_T)), ("U", Int(kVK_ANSI_U)),
        ("V", Int(kVK_ANSI_V)), ("W", Int(kVK_ANSI_W)), ("X", Int(kVK_ANSI_X)),
        ("Y", Int(kVK_ANSI_Y)), ("Z", Int(kVK_ANSI_Z)),
        ("0", Int(kVK_ANSI_0)), ("1", Int(kVK_ANSI_1)), ("2", Int(kVK_ANSI_2)),
        ("3", Int(kVK_ANSI_3)), ("4", Int(kVK_ANSI_4)), ("5", Int(kVK_ANSI_5)),
        ("6", Int(kVK_ANSI_6)), ("7", Int(kVK_ANSI_7)), ("8", Int(kVK_ANSI_8)),
        ("9", Int(kVK_ANSI_9))
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: [PreferenceKey.darkStart: "19:00", PreferenceKey.lightStart: "07:00"])
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "◐"
        statusItem.button?.toolTip = "昼夜外观 · 点击切换"

        let menu = NSMenu()
        lightItem = item("切换到浅色模式", #selector(useLight))
        darkItem = item("切换到深色模式", #selector(useDark))
        menu.addItem(lightItem)
        menu.addItem(darkItem)
        menu.addItem(.separator())
        scheduleItem = item("按时间自动切换", #selector(toggleSchedule))
        menu.addItem(scheduleItem)
        menu.addItem(item("设置切换时间…", #selector(editSchedule)))
        menu.addItem(.separator())
        hotkeyItem = item("启用快捷键", #selector(toggleHotkey))
        menu.addItem(hotkeyItem)
        menu.addItem(item("设置切换快捷键…", #selector(editHotkey)))
        menu.addItem(.separator())
        loginItem = item("登录时启动", #selector(toggleLogin))
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(item("关于昼夜外观", #selector(showAbout)))
        menu.addItem(item("退出昼夜外观", #selector(quit)))
        statusItem.menu = menu
        installHotkeyHandler()
        if defaults.bool(forKey: PreferenceKey.hotkeyEnabled) {
            let code = defaults.integer(forKey: PreferenceKey.hotkeyCode)
            let modifiers = UInt32(defaults.integer(forKey: PreferenceKey.hotkeyModifiers))
            if !activateHotkey(code: code, modifiers: modifiers) {
                defaults.set(false, forKey: PreferenceKey.hotkeyEnabled)
                showHotkeyFailure(code: code)
            }
        }
        updateMenu()

        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.applySchedule() }
        }
        applySchedule()
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func updateMenu() {
        scheduleItem.state = defaults.bool(forKey: PreferenceKey.scheduled) ? .on : .off
        hotkeyItem.state = defaults.bool(forKey: PreferenceKey.hotkeyEnabled) ? .on : .off
        let hotkeyLabel = defaults.string(forKey: PreferenceKey.hotkeyLabel) ?? "未设置"
        hotkeyItem.title = "启用快捷键（\(hotkeyLabel)）"
        let darkTime = defaults.string(forKey: PreferenceKey.darkStart) ?? "19:00"
        let lightTime = defaults.string(forKey: PreferenceKey.lightStart) ?? "07:00"
        scheduleItem.title = "按时间自动切换（\(darkTime) 深色 / \(lightTime) 浅色）"
        loginItem.state = FileManager.default.fileExists(atPath: launchAgentURL.path) ? .on : .off
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        lightItem.state = dark ? .off : .on
        darkItem.state = dark ? .on : .off
        statusItem.button?.title = dark ? "☾" : "☀︎"
    }

    @objc private func useLight() { setMode(dark: false, manual: true) }
    @objc private func useDark() { setMode(dark: true, manual: true) }

    private func toggleAppearance() {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        setMode(dark: !dark, manual: true)
    }

    private func installHotkeyHandler() {
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let result = InstallEventHandler(GetApplicationEventTarget(), { _, carbonEvent, userData in
            guard let carbonEvent, let userData else { return noErr }
            var hotkeyID = EventHotKeyID()
            let status = GetEventParameter(carbonEvent, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hotkeyID)
            guard status == noErr, hotkeyID.id == 1 else { return noErr }
            MainActor.assumeIsolated {
                Unmanaged<DayNightApp>.fromOpaque(userData).takeUnretainedValue().toggleAppearance()
            }
            return noErr
        }, 1, &event, userData, &hotkeyHandler)
        if result != noErr { showError("快捷键初始化失败", "系统未能建立快捷键事件处理器（\(result)）。") }
    }

    private func activateHotkey(code: Int, modifiers: UInt32) -> Bool {
        if code == -1 { return activateModifierChord(modifiers: modifiers) }
        guard hotkeyHandler != nil else { return false }
        var newRef: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: OSType(0x44595A48), id: 1)
        let result = RegisterEventHotKey(UInt32(code), modifiers, identifier, GetApplicationEventTarget(), 0, &newRef)
        guard result == noErr, let newRef else { return false }
        deactivateHotkey()
        hotkeyRef = newRef
        return true
    }

    private func activateModifierChord(modifiers: UInt32) -> Bool {
        guard CGPreflightListenEventAccess() || CGRequestListenEventAccess() else { return false }
        let mask = CGEventMask(1) << CGEventType.flagsChanged.rawValue
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .listenOnly, eventsOfInterest: mask,
                                          callback: { _, type, event, userData in
            guard let userData else { return Unmanaged.passUnretained(event) }
            MainActor.assumeIsolated {
                let app = Unmanaged<DayNightApp>.fromOpaque(userData).takeUnretainedValue()
                if type == .flagsChanged {
                    app.handleModifierFlags(event.flags)
                } else if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput,
                          let tap = app.modifierTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        deactivateHotkey()
        modifierTap = tap
        modifierSource = source
        modifierChord = Self.cgFlags(for: modifiers)
        modifierLatched = false
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private static func cgFlags(for modifiers: UInt32) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.maskControl) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.maskAlternate) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.maskShift) }
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.maskCommand) }
        return flags
    }

    private func handleModifierFlags(_ flags: CGEventFlags) {
        let supported: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]
        let pressed = flags.intersection(supported)
        if !pressed.isSuperset(of: modifierChord) { modifierLatched = false }
        guard pressed == modifierChord, !modifierLatched else { return }
        modifierLatched = true
        DispatchQueue.main.async { [weak self] in self?.toggleAppearance() }
    }

    private func deactivateHotkey() {
        if let ref = hotkeyRef { UnregisterEventHotKey(ref) }
        hotkeyRef = nil
        if let source = modifierSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap = modifierTap { CFMachPortInvalidate(tap) }
        modifierSource = nil
        modifierTap = nil
        modifierChord = []
        modifierLatched = false
    }

    private func showHotkeyFailure(code: Int) {
        if code == -1 {
            showError("修饰键监听不可用", "请在“系统设置 → 隐私与安全性 → 输入监控”中允许“昼夜外观”，然后退出并重新打开应用。")
        } else {
            showError("快捷键被占用", "这个组合键已被系统或其他应用使用，请换一个。")
        }
    }

    @objc private func toggleHotkey() {
        if defaults.bool(forKey: PreferenceKey.hotkeyEnabled) {
            deactivateHotkey()
            defaults.set(false, forKey: PreferenceKey.hotkeyEnabled)
        } else if defaults.object(forKey: PreferenceKey.hotkeyCode) == nil {
            editHotkey()
            return
        } else {
            let code = defaults.integer(forKey: PreferenceKey.hotkeyCode)
            let modifiers = UInt32(defaults.integer(forKey: PreferenceKey.hotkeyModifiers))
            if activateHotkey(code: code, modifiers: modifiers) {
                defaults.set(true, forKey: PreferenceKey.hotkeyEnabled)
            } else {
                showHotkeyFailure(code: code)
            }
        }
        updateMenu()
    }

    @objc private func editHotkey() {
        let alert = NSAlert()
        alert.messageText = "设置切换快捷键"
        alert.informativeText = "可只选两个修饰键（例如 ⌃⌘）；也可搭配字母或数字。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        let controls = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 100))
        let keyLabel = NSTextField(labelWithString: "按键")
        keyLabel.frame = NSRect(x: 0, y: 66, width: 50, height: 24)
        controls.addSubview(keyLabel)
        let keyMenu = NSPopUpButton(frame: NSRect(x: 54, y: 63, width: 210, height: 28), pullsDown: false)
        keyMenu.addItems(withTitles: Self.hotkeyKeys.map(\.0))
        let savedCode = defaults.integer(forKey: PreferenceKey.hotkeyCode)
        let savedIndex = defaults.object(forKey: PreferenceKey.hotkeyCode) == nil
            ? 4 : (Self.hotkeyKeys.firstIndex { $0.1 == savedCode } ?? 4)
        keyMenu.selectItem(at: savedIndex)
        controls.addSubview(keyMenu)

        let savedModifiers = UInt32(defaults.integer(forKey: PreferenceKey.hotkeyModifiers))
        let modifierItems: [(String, UInt32)] = [
            ("⌃ Control", UInt32(controlKey)), ("⌥ Option", UInt32(optionKey)),
            ("⇧ Shift", UInt32(shiftKey)), ("⌘ Command", UInt32(cmdKey))
        ]
        var checkboxes: [(NSButton, UInt32)] = []
        for (index, modifier) in modifierItems.enumerated() {
            let button = NSButton(checkboxWithTitle: modifier.0, target: nil, action: nil)
            button.frame = NSRect(x: (index % 2) * 140, y: 34 - (index / 2) * 30, width: 135, height: 25)
            button.state = savedModifiers == 0
                ? ((modifier.1 == UInt32(controlKey) || modifier.1 == UInt32(optionKey)) ? .on : .off)
                : ((savedModifiers & modifier.1 != 0) ? .on : .off)
            controls.addSubview(button)
            checkboxes.append((button, modifier.1))
        }
        alert.accessoryView = controls
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        let selectedModifiers = checkboxes.reduce(UInt32(0)) { $0 | ($1.0.state == .on ? $1.1 : 0) }
        let selected = Self.hotkeyKeys[keyMenu.indexOfSelectedItem]
        if selected.1 == -1 && checkboxes.filter({ $0.0.state == .on }).count != 2 {
            showError("需要两个修饰键", "选择“无（仅用两个修饰键）”时，请恰好勾选两个修饰键。")
            return
        }
        guard selectedModifiers & (UInt32(controlKey) | UInt32(optionKey) | UInt32(cmdKey)) != 0 else {
            showError("缺少修饰键", "至少勾选 ⌘、⌃ 或 ⌥ 之一。")
            return
        }
        let labels: [(UInt32, String)] = [
            (UInt32(controlKey), "⌃"), (UInt32(optionKey), "⌥"),
            (UInt32(shiftKey), "⇧"), (UInt32(cmdKey), "⌘")
        ]
        let selection = (code: selected.1, modifiers: selectedModifiers,
                         label: labels.filter { selectedModifiers & $0.0 != 0 }.map(\.1).joined() + (selected.1 == -1 ? "" : selected.0))

        let oldCode = defaults.integer(forKey: PreferenceKey.hotkeyCode)
        let oldModifiers = UInt32(defaults.integer(forKey: PreferenceKey.hotkeyModifiers))
        let sameActive = (hotkeyRef != nil || modifierTap != nil) && oldCode == selection.code && oldModifiers == selection.modifiers
        guard sameActive || activateHotkey(code: selection.code, modifiers: selection.modifiers) else {
            showHotkeyFailure(code: selection.code)
            return
        }
        defaults.set(Int(selection.code), forKey: PreferenceKey.hotkeyCode)
        defaults.set(Int(selection.modifiers), forKey: PreferenceKey.hotkeyModifiers)
        defaults.set(selection.label, forKey: PreferenceKey.hotkeyLabel)
        defaults.set(true, forKey: PreferenceKey.hotkeyEnabled)
        updateMenu()
    }

    private func setMode(dark: Bool, manual: Bool) {
        if manual { defaults.set(false, forKey: PreferenceKey.scheduled) }
        let script = "tell application \"System Events\" to tell appearance preferences to set dark mode to \(dark ? "true" : "false")"
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error {
            let detail = error[NSAppleScript.errorMessage] as? String ?? error.description
            showError("切换外观失败", detail + "\n\n请在“系统设置 → 隐私与安全性 → 自动化”中允许本应用控制“系统事件”。")
            return
        }
        lastAppliedDark = dark
        updateMenu()
    }

    @objc private func toggleSchedule() {
        let enabled = !defaults.bool(forKey: PreferenceKey.scheduled)
        defaults.set(enabled, forKey: PreferenceKey.scheduled)
        lastAppliedDark = nil
        updateMenu()
        if enabled { applySchedule() }
    }

    @objc private func editSchedule() {
        let alert = NSAlert()
        alert.messageText = "设置自动切换时间"
        alert.informativeText = "使用 24 小时格式 HH:mm。深色时间可跨越午夜。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 10
        stack.frame = NSRect(x: 0, y: 0, width: 250, height: 60)
        for (title, value) in [("进入深色模式", defaults.string(forKey: PreferenceKey.darkStart) ?? "19:00"),
                               ("进入浅色模式", defaults.string(forKey: PreferenceKey.lightStart) ?? "07:00")] {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 12
            let label = NSTextField(labelWithString: title)
            label.frame.size.width = 110
            let field = NSTextField(string: value)
            field.frame.size.width = 80
            row.addArrangedSubview(label)
            row.addArrangedSubview(field)
            stack.addArrangedSubview(row)
        }
        alert.accessoryView = stack
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let fields = stack.arrangedSubviews.compactMap { ($0 as? NSStackView)?.arrangedSubviews.last as? NSTextField }
        guard fields.count == 2,
              let dark = Self.minutes(fields[0].stringValue),
              let light = Self.minutes(fields[1].stringValue), dark != light else {
            showError("时间格式无效", "请输入不同的深色和浅色时间，例如 19:00 与 07:00。")
            return
        }
        defaults.set(Self.clock(dark), forKey: PreferenceKey.darkStart)
        defaults.set(Self.clock(light), forKey: PreferenceKey.lightStart)
        lastAppliedDark = nil
        updateMenu()
        applySchedule()
    }

    private func applySchedule() {
        guard defaults.bool(forKey: PreferenceKey.scheduled),
              let dark = Self.minutes(defaults.string(forKey: PreferenceKey.darkStart) ?? ""),
              let light = Self.minutes(defaults.string(forKey: PreferenceKey.lightStart) ?? "") else { return }
        let now = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let current = (now.hour ?? 0) * 60 + (now.minute ?? 0)
        let targetDark = dark < light ? (current >= dark && current < light) : (current >= dark || current < light)
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if targetDark != isDark && targetDark != lastAppliedDark { setMode(dark: targetDark, manual: false) }
        else { updateMenu() }
    }

    private static func minutes(_ value: String) -> Int? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 2, parts[1].count == 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        return hour * 60 + minute
    }

    private static func clock(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    private var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(launchAgentName)")
    }

    @objc private func toggleLogin() {
        let url = launchAgentURL
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            } else {
                let appPath = Bundle.main.bundlePath
                let executable = Bundle.main.executablePath ?? ""
                let agent: [String: Any] = ["Label": "cn.liming.daynightzh",
                                             "ProgramArguments": [executable],
                                             "RunAtLoad": true,
                                             "WorkingDirectory": appPath]
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try PropertyListSerialization.data(fromPropertyList: agent, format: .xml, options: 0)
                try data.write(to: url, options: .atomic)
            }
            updateMenu()
        } catch { showError("设置登录启动失败", error.localizedDescription) }
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "昼夜外观 1.2"
        alert.informativeText = "独立的中文 macOS 菜单栏工具。支持手动、定时和组合快捷键切换浅色／深色外观，快捷键可只用两个修饰键。不会加载 NightOwl 或代理网络组件。\n\n首次切换时，macOS 可能询问是否允许控制“系统事件”；纯修饰键快捷键还需要“输入监控”权限。"
        alert.runModal()
    }

    private func showError(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail
        alert.runModal()
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = DayNightApp()
    app.delegate = delegate
    app.run()
}
