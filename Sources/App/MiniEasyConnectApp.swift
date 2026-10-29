import AppKit
import Combine
import Darwin
import SwiftUI

@main
enum MiniEasyConnectApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = MiniEasyConnectDelegate()
        application.setActivationPolicy(.regular)
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

/// Owns the connection independently of the on-demand SwiftUI window and native menu bar.
@MainActor
final class MiniEasyConnectDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate, NSMenuItemValidation {
    private let controller = ConnectionController()
    private let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 540),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: true)
    private var hostingView: NSHostingView<MainView>?
    private var editorPanel: ConnectionEditorPanel?
    private var editorSheetClosing = false
    private var statusItem: NSStatusItem?
    private let statusMenu = NSMenu()
    private var visibilityObservation: NSKeyValueObservation?
    private var controllerSubscription: AnyCancellable?
    private var memoryReliefWork: DispatchWorkItem?
    private var wasEditing = false
    private var needsAttention = false
    private var quitting = false
    private let menuBarPreference = "showMenuBarExtra"

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [menuBarPreference: true])
        window.title = "miniEasyConnect"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("miniEasyConnect.main")
        if !window.setFrameUsingName("miniEasyConnect.main", force: true) { window.center() }
        configureMenus()
        configureStatusItem()
        controllerSubscription = controller.objectWillChange.sink { [weak self] _ in
            // ObservableObject emits before mutation; read the completed state on the main queue.
            DispatchQueue.main.async { self?.controllerChanged() }
        }
        showMainWindow()
    }

    deinit {
        memoryReliefWork?.cancel()
        visibilityObservation?.invalidate()
        controllerSubscription?.cancel()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitting { return .terminateLater }
        quitting = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.controller.prepareToQuit { [weak self] success in
                self?.quitting = false
                sender.reply(toApplicationShouldTerminate: success)
            }
        }
        return .terminateLater
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func windowWillClose(_ notification: Notification) {
        // Sheet-local drafts remain intact when the user returns to an unfinished edit.
        if !controller.isEditing && controller.errorMessage == nil {
            window.makeFirstResponder(nil)
            window.contentView = nil
            hostingView = nil
            scheduleIdleMemoryRelief()
        }
    }

    /// Recreates the SwiftUI interface after closing while preserving the active connection.
    @objc private func showMainWindow() {
        if hostingView == nil {
            let view = NSHostingView(rootView: MainView(controller: controller))
            hostingView = view
            window.contentView = view
            window.setContentSize(NSSize(width: 480, height: 540))
        }
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func controllerChanged() {
        let editing = controller.isEditing
        if editing {
            memoryReliefWork?.cancel()
            memoryReliefWork = nil
        } else if wasEditing {
            scheduleIdleMemoryRelief()
        }
        wasEditing = editing
        let attention = editing || controller.errorMessage != nil
        if attention && !needsAttention { showMainWindow() }
        needsAttention = attention
        if controller.showingEditor {
            if editorPanel == nil {
                showMainWindow()
                let editor = ConnectionEditorPanel(controller: controller)
                editorPanel = editor
                window.beginSheet(editor.panel) { [weak self, editor] _ in
                    editor.releaseContent()
                    guard let self, self.editorPanel === editor else { return }
                    self.editorPanel = nil
                    self.editorSheetClosing = false
                    self.scheduleIdleMemoryRelief()
                    self.controllerChanged()
                }
            }
            editorPanel?.updateError()
        } else if let editor = editorPanel, !editorSheetClosing {
            editorSheetClosing = true
            window.endSheet(editor.panel)
        }
        statusItem?.button?.toolTip = "miniEasyConnect：\(controller.stateTitle)"
    }

    /// Returns allocator idle pages once after window or sheet teardown has finished animating.
    private func scheduleIdleMemoryRelief() {
        memoryReliefWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.controller.isEditing else { return }
            self.memoryReliefWork = nil
            malloc_zone_pressure_relief(nil, 0)
        }
        memoryReliefWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "miniEasyConnect"
        item.behavior = .removalAllowed
        item.button?.image = NSImage(systemSymbolName: "network", accessibilityDescription: "miniEasyConnect")
        item.button?.image?.isTemplate = true
        item.button?.toolTip = "miniEasyConnect：\(controller.stateTitle)"
        statusMenu.delegate = self
        item.menu = statusMenu
        item.isVisible = UserDefaults.standard.bool(forKey: menuBarPreference)
        statusItem = item
        visibilityObservation = item.observe(\.isVisible, options: [.new]) { [weak self] _, change in
            guard let visible = change.newValue else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                UserDefaults.standard.set(visible, forKey: self.menuBarPreference)
            }
        }
    }

    private func configureMenus() {
        let main = NSMenu()
        let app = NSMenu(title: "miniEasyConnect")
        app.addItem(nativeItem("关于 miniEasyConnect", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: NSApplication.shared))
        app.addItem(.separator())
        app.addItem(commandItem("显示菜单栏图标", #selector(toggleMenuBarIcon)))
        app.addItem(commandItem("停用后台服务…", #selector(disableHelper)))
        app.addItem(.separator())
        let services = NSMenu(title: "服务")
        addMenu(services, to: app)
        NSApplication.shared.servicesMenu = services
        app.addItem(.separator())
        app.addItem(nativeItem("隐藏 miniEasyConnect", #selector(NSApplication.hide(_:)), key: "h", target: NSApplication.shared))
        let hideOthers = nativeItem("隐藏其他", #selector(NSApplication.hideOtherApplications(_:)), key: "h", target: NSApplication.shared)
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        app.addItem(hideOthers)
        app.addItem(nativeItem("全部显示", #selector(NSApplication.unhideAllApplications(_:)), target: NSApplication.shared))
        app.addItem(.separator())
        app.addItem(commandItem("退出 miniEasyConnect", #selector(quit), key: "q"))
        addMenu(app, to: main)

        let edit = NSMenu(title: "编辑")
        edit.addItem(nativeItem("撤销", Selector(("undo:")), key: "z"))
        let redo = nativeItem("重做", Selector(("redo:")), key: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(nativeItem("剪切", #selector(NSText.cut(_:)), key: "x"))
        edit.addItem(nativeItem("复制", #selector(NSText.copy(_:)), key: "c"))
        edit.addItem(nativeItem("粘贴", #selector(NSText.paste(_:)), key: "v"))
        edit.addItem(nativeItem("全选", #selector(NSText.selectAll(_:)), key: "a"))
        addMenu(edit, to: main)

        let connection = NSMenu(title: "连接")
        connection.addItem(commandItem("新建连接…", #selector(newConnection), key: "n"))
        connection.addItem(commandItem("连接最近记录", #selector(connectLastUsed)))
        connection.addItem(commandItem("断开连接", #selector(disconnect)))
        addMenu(connection, to: main)

        let windows = NSMenu(title: "窗口")
        windows.addItem(nativeItem("最小化", #selector(NSWindow.performMiniaturize(_:)), key: "m"))
        windows.addItem(nativeItem("关闭窗口", #selector(NSWindow.performClose(_:)), key: "w"))
        windows.addItem(commandItem("打开 miniEasyConnect", #selector(showMainWindow)))
        addMenu(windows, to: main)
        NSApplication.shared.windowsMenu = windows
        NSApplication.shared.mainMenu = main
    }

    private func addMenu(_ menu: NSMenu, to parent: NSMenu) {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        parent.addItem(item)
    }

    private func nativeItem(_ title: String, _ action: Selector, key: String = "", target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target
        return item
    }

    private func commandItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        nativeItem(title, action, key: key, target: self)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusMenu else { return }
        menu.removeAllItems()
        menu.addItem(NSMenuItem(title: controller.stateTitle, action: nil, keyEquivalent: ""))
        if let profile = controller.activeProfile {
            menu.addItem(NSMenuItem(title: profile.displayName, action: nil, keyEquivalent: ""))
        }
        menu.addItem(.separator())
        menu.addItem(commandItem("打开 miniEasyConnect", #selector(showMainWindow)))
        if controller.hasConnection {
            menu.addItem(commandItem("断开连接", #selector(disconnect)))
        } else {
            for profile in controller.profiles {
                let item = commandItem("连接 \(profile.displayName)", #selector(connectProfile(_:)))
                item.representedObject = profile
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        menu.addItem(commandItem("退出 miniEasyConnect", #selector(quit)))
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(newConnection), #selector(connectProfile(_:)):
            return controller.canStartConnection
        case #selector(connectLastUsed):
            menuItem.title = controller.lastUsedProfile.map { "连接：\($0.displayName)" } ?? "连接最近记录"
            return controller.canConnectLastUsed
        case #selector(disconnect):
            return controller.canDisconnect
        case #selector(toggleMenuBarIcon):
            menuItem.state = statusItem?.isVisible == true ? .on : .off
            return true
        case #selector(disableHelper):
            return !controller.isPerformingCommand && !controller.isDisablingHelper && controller.snapshot.state != .disconnecting
        case #selector(quit):
            return !controller.isDisablingHelper
        default:
            return true
        }
    }

    @objc private func newConnection() {
        showMainWindow()
        controller.newConnection()
    }

    @objc private func connectLastUsed() { controller.connectLastUsed() }
    @objc private func disconnect() { controller.disconnect() }
    @objc private func disableHelper() { controller.confirmDisableHelper() }
    @objc private func quit() { NSApplication.shared.terminate(nil) }

    @objc private func connectProfile(_ sender: NSMenuItem) {
        guard let profile = sender.representedObject as? ConnectionProfile else { return }
        controller.connect(profile)
    }

    @objc private func toggleMenuBarIcon() {
        guard let statusItem else { return }
        statusItem.isVisible.toggle()
        UserDefaults.standard.set(statusItem.isVisible, forKey: menuBarPreference)
    }
}
