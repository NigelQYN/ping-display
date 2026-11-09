import AppKit
import CoreGraphics
import CoreServices
import ServiceManagement
import WebKit

final class MenuApp: NSObject, NSApplicationDelegate, WKScriptMessageHandler {
    private let controller = DisplayController()
    private let keyboard = Keyboard()
    private var commandBridge: CommandBridge?
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private let popoverContent = NSView()
    private var launchWindow: NSPanel?
    private var webView: WKWebView!
    private var ready = false
    private var dragTargets: [String: Double] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        let launchReason = NSAppleEventManager.shared().currentAppleEvent?
            .paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue
        let backgroundLaunch = launchReason == keyAELaunchedAsLogInItem
            || launchReason == keyAELaunchedAsServiceItem
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        item.button?.image = NSImage(systemSymbolName: "sun.max", accessibilityDescription: "屏幕亮度")
        item.button?.image?.isTemplate = true
        item.button?.toolTip = "屏 · 屏幕亮度"
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.setAccessibilityLabel("屏幕亮度")

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(self, name: "brightnessPanel")
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 201), configuration: configuration)
        let content = NSViewController()
        content.view = popoverContent
        popover.contentViewController = content
        popover.contentSize = webView.frame.size
        popover.behavior = .transient
        popover.delegate = self
        if let html = Bundle.main.url(forResource: "brightness_panel", withExtension: "html") {
            webView.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
        }

        controller.onChange = { [weak self] in self?.updatePanel() }
        controller.onError = { [weak self] message in self?.showError(message) }
        keyboard.onCancel = { [weak self] in self?.cancelDimming() }
        keyboard.onBrightness = { [weak self] delta in
            guard let self else { return false }
            let main = CGMainDisplayID()
            guard let display = self.controller.displays.first(where: { $0.id == main && $0.active }),
                  let value = self.controller.currentBrightness(display) else { return false }
            if delta != 0 { self.controller.setBrightness(display, value: value + Double(delta) * 0.05) }
            return true
        }
        keyboard.startRecovery()
        if controller.defaults.bool(forKey: "brightnessKeys") && !keyboard.setBrightnessKeys(true) {
            controller.defaults.set(false, forKey: "brightnessKeys")
        }
        commandBridge = CommandBridge(controller: controller)
        commandBridge?.start()
        controller.start()
        if !backgroundLaunch {
            DispatchQueue.main.async { [weak self] in self?.showLaunchWindow() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        keyboard.stop()
        commandBridge?.stop()
        controller.stop()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "brightnessPanel")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showLaunchWindow()
        return false
    }

    @objc private func togglePanel() {
        if NSApp.currentEvent?.type == .rightMouseUp { showSettings(); return }
        if popover.isShown { popover.performClose(nil) } else { showPanel() }
    }

    private func showPanel() {
        guard let button = statusItem?.button else { return }
        launchWindow?.close()
        attachWebView(to: popoverContent)
        updatePanel()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        controller.refresh()
    }

    private func showLaunchWindow() {
        if popover.isShown { popover.close() }
        if launchWindow == nil {
            let window = NSPanel(contentRect: NSRect(origin: .zero, size: popover.contentSize),
                                 styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "屏幕亮度"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            launchWindow = window
        }
        guard let window = launchWindow, let content = window.contentView else { return }
        attachWebView(to: content)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        updatePanel()
        controller.refresh()
    }

    private func attachWebView(to view: NSView) {
        guard webView.superview !== view else { return }
        webView.removeFromSuperview()
        webView.frame = view.bounds
        webView.autoresizingMask = [.width, .height]
        view.addSubview(webView)
    }

    private var panelIsVisible: Bool {
        popover.isShown || launchWindow?.isVisible == true
    }

    private func updatePanel() {
        let rows = controller.presented
        let count = rows.filter { !$0.builtin || $0.active }.count
        let screen = webView.window?.screen ?? statusItem?.button?.window?.screen ?? NSScreen.main
        let screenHeight = screen?.visibleFrame.height ?? 700
        let height = min(CGFloat(115 + max(1, count) * 86), screenHeight - 20)
        let size = NSSize(width: 320, height: height)
        if popover.contentSize != size { popover.contentSize = size }
        if let window = launchWindow, window.isVisible, window.contentView?.frame.size != size {
            window.setContentSize(size)
        }
        guard ready, let data = try? JSONEncoder().encode(rows) else { return }
        let json = String(decoding: data, as: UTF8.self)
        let pending = controller.builtinPending.map { $0 ? "true" : "false" } ?? "null"
        webView.evaluateJavaScript("updateDisplays(\(json), \(pending))", completionHandler: nil)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any],
              let action = body["action"] as? String else { return }
        switch action {
        case "ready":
            ready = true
            updatePanel()
        case "settings":
            if panelIsVisible, let x = body["x"] as? Double, let y = body["y"] as? Double {
                let point = NSPoint(x: x, y: webView.isFlipped ? y : webView.bounds.height - y)
                showSettings(anchor: webView, at: point)
            }
        case "toggleBuiltin":
            if let built = controller.displays.first(where: \.builtin) {
                controller.setBuiltin(!built.active, manual: true)
            }
        case "brightness":
            guard let uuid = body["uuid"] as? String, let value = body["value"] as? Double,
                  (1...100).contains(value),
                  let display = controller.displays.first(where: { $0.uuid == uuid && $0.active }) else { return }
            let dragging = body["dragging"] as? Bool == true
            let target = value / 100
            if dragging { dragTargets[uuid] = target }
            else { dragTargets.removeValue(forKey: uuid) }
            controller.setBrightness(display, value: target, dragging: dragging)
        default: break
        }
    }

    private func showSettings(anchor: NSView? = nil, at point: NSPoint? = nil) {
        guard let anchor = anchor ?? statusItem?.button else { return }
        let menu = NSMenu()
        func add(_ title: String, _ selector: Selector, checked: Bool = false) -> NSMenuItem {
            let item = menu.addItem(withTitle: title, action: selector, keyEquivalent: "")
            item.target = self
            item.state = checked ? .on : .off
            return item
        }
        _ = add("接外屏时自动关闭内建", #selector(toggleAutoExternal), checked: controller.autoExternal)
        _ = add("亮度键控制主显示器", #selector(toggleBrightnessKeys),
                checked: controller.defaults.bool(forKey: "brightnessKeys"))
        _ = add("环境光自动调节 · \(controller.sensor.status)", #selector(toggleSensor),
                checked: controller.defaults.bool(forKey: "sensorEnabled"))
        _ = add("设置光感串口…", #selector(configureSensor))
        _ = add("登录时启动", #selector(toggleLogin), checked: SMAppService.mainApp.status == .enabled)
        menu.addItem(.separator())
        _ = add(keyboard.recoveryAvailable ? "取消软调暗（⌃⌥⌘B）" : "取消软调暗", #selector(cancelDimming))
        if let error = controller.lastError {
            let item = NSMenuItem(title: "上次错误：\(error)", action: nil, keyEquivalent: "")
            menu.addItem(item)
        }
        _ = add("退出「屏」 app", #selector(quit))
        menu.popUp(positioning: nil, at: point ?? NSPoint(x: 0, y: anchor.bounds.minY), in: anchor)
    }

    @objc private func toggleAutoExternal() {
        controller.autoExternal.toggle()
        controller.refresh { [weak self] ok in if ok { self?.controller.applyAutoPolicy() } }
    }

    @objc private func toggleBrightnessKeys() {
        let enabled = !controller.defaults.bool(forKey: "brightnessKeys")
        if keyboard.setBrightnessKeys(enabled, requestPermission: enabled) {
            controller.defaults.set(enabled, forKey: "brightnessKeys")
        } else {
            showError("请在系统设置的「隐私与安全性」中允许「屏」监听输入，再开启亮度键控制。", explicit: true)
        }
    }

    @objc private func toggleSensor() {
        controller.setSensorEnabled(!controller.defaults.bool(forKey: "sensorEnabled"))
    }

    @objc private func configureSensor() {
        let alert = NSAlert()
        alert.messageText = "设置光感串口"
        alert.informativeText = "输入 /dev/cu. 开头的设备路径"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = controller.sensorPath
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let path = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/dev/cu."), path.count > 8, !path.dropFirst(8).contains("/") else {
            showError("请输入有效的 /dev/cu. 串口路径", explicit: true)
            return
        }
        controller.sensorPath = path
        if controller.defaults.bool(forKey: "sensorEnabled") { controller.setSensorEnabled(true) }
    }

    @objc private func toggleLogin() {
        do {
            switch SMAppService.mainApp.status {
            case .enabled: try SMAppService.mainApp.unregister()
            case .requiresApproval: SMAppService.openSystemSettingsLoginItems()
            default: try SMAppService.mainApp.register()
            }
        } catch { showError(error.localizedDescription, explicit: true) }
    }

    @objc private func cancelDimming() {
        dragTargets.removeAll()
        controller.cancelDimming()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func showError(_ message: String, explicit: Bool = false) {
        guard panelIsVisible || explicit else { return }
        let alert = NSAlert()
        alert.messageText = "屏幕控制"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        if panelIsVisible, let window = webView.window {
            guard window.attachedSheet == nil else { return }
            alert.beginSheetModal(for: window)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
    private func finishDragging() {
        let targets = dragTargets
        dragTargets.removeAll()
        for (uuid, value) in targets {
            if let display = controller.displays.first(where: { $0.uuid == uuid && $0.active }) {
                controller.setBrightness(display, value: value)
            }
        }
        webView.evaluateJavaScript("endBrightnessDrags()", completionHandler: nil)
    }
}

extension MenuApp: NSPopoverDelegate, NSWindowDelegate {
    func popoverWillClose(_ notification: Notification) { finishDragging() }
    func windowWillClose(_ notification: Notification) { finishDragging() }
}
