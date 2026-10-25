import AppKit
import SwiftUI

@main
struct MiniEasyConnectApp: App {
    @NSApplicationDelegateAdaptor(MiniEasyConnectDelegate.self) private var delegate
    @StateObject private var controller = ConnectionController()

    var body: some Scene {
        Window("miniEasyConnect", id: "main") {
            MainView(controller: controller)
                .onAppear { MiniEasyConnectDelegate.controller = controller }
        }
        .defaultSize(width: 480, height: 540)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("退出 miniEasyConnect") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        MenuBarExtra("miniEasyConnect", systemImage: "network") {
            ConnectionMenu(controller: controller)
        }
    }
}

@MainActor
final class MiniEasyConnectDelegate: NSObject, NSApplicationDelegate {
    static weak var controller: ConnectionController?
    private var quitting = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitting { return .terminateLater }
        guard let controller = Self.controller else { return .terminateNow }
        quitting = true
        DispatchQueue.main.async { [weak self] in
            controller.prepareToQuit { [weak self] success in
                self?.quitting = false
                sender.reply(toApplicationShouldTerminate: success)
            }
        }
        return .terminateLater
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { sender.windows.first(where: { $0.title == "miniEasyConnect" })?.makeKeyAndOrderFront(nil) }
        return true
    }
}

private struct ConnectionMenu: View {
    @ObservedObject var controller: ConnectionController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(controller.stateTitle)
        if let profile = controller.activeProfile { Text(profile.serverHost) }
        Divider()
        Button("打开 miniEasyConnect") {
            openWindow(id: "main")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        if controller.hasConnection {
            Button("断开连接") { controller.disconnect() }
                .disabled(controller.snapshot.state == .disconnecting)
        } else {
            ForEach(controller.profiles) { profile in
                Button("连接 \(profile.serverHost)") { controller.connect(profile) }
            }
        }
        Divider()
        Button("退出 miniEasyConnect") { NSApplication.shared.terminate(nil) }
    }
}
