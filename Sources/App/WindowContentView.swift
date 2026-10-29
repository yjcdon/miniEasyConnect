import AppKit
import SwiftUI

private typealias WindowState<Value> = SwiftUI.State<Value>

/// Releases the main interface while its closed window keeps the connection controller alive.
struct WindowContentView: View {
    @ObservedObject var controller: ConnectionController
    @WindowState private var contentLoaded = true

    var body: some View {
        ZStack {
            if contentLoaded {
                MainView(controller: controller)
            } else {
                Color(nsColor: .windowBackgroundColor)
            }
        }
        .frame(width: 480, height: 540)
        .background(WindowLifecycleObserver(
            onClose: {
                // Form values belong to their sheet; keep that graph until editing finishes.
                if !controller.isEditing && controller.errorMessage == nil {
                    contentLoaded = false
                }
            },
            onShow: { contentLoaded = true }
        ))
    }
}

/// Observes only the hosting window, using native events instead of a visibility timer.
private struct WindowLifecycleObserver: NSViewRepresentable {
    let onClose: () -> Void
    let onShow: () -> Void

    func makeNSView(context: Context) -> LifecycleView {
        LifecycleView(onClose: onClose, onShow: onShow)
    }

    func updateNSView(_ nsView: LifecycleView, context: Context) {
        nsView.onClose = onClose
        nsView.onShow = onShow
    }

    final class LifecycleView: NSView {
        var onClose: () -> Void
        var onShow: () -> Void
        private var observers: [NSObjectProtocol] = []

        init(onClose: @escaping () -> Void, onShow: @escaping () -> Void) {
            self.onClose = onClose
            self.onShow = onShow
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("Use init(onClose:onShow:)") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeObservers()
            guard let window else { return }
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                self?.onClose()
            })
            observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                self?.onShow()
            })
        }

        private func removeObservers() {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
        }

        deinit {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
        }
    }
}
