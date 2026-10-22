import AppKit
import SwiftUI

@MainActor
final class TranscriptCleanupSettingsWindowController: NSWindowController {
    init(settings: TranscriptCleanupSettings) {
        let hostingController = NSHostingController(
            rootView: TranscriptCleanupSettingsView(settings: settings)
        )
        let window = NSWindow(contentViewController: hostingController)

        window.title = "Claude Cleanup"
        window.styleMask = [.titled, .closable]
        window.collectionBehavior = [.moveToActiveSpace]
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed

        hostingController.sizingOptions = [.preferredContentSize]
        window.center()

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }

            NSApplication.shared.activate(ignoringOtherApps: true)
            self.showWindow(nil)
            window.makeKeyAndOrderFront(nil)
        }
    }
}
