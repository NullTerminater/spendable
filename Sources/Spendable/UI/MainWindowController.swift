import AppKit
import SwiftUI

/// The main window, hosted by AppKit so it can be created on demand and genuinely released when
/// closed. A SwiftUI `Window` scene keeps its NSWindow and view state alive after close; this
/// controller drops the hosting controller, the window and itself in `windowWillClose`.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    private static var current: MainWindowController?

    /// Shows the window, creating it if it does not exist.
    static func show(model: AppModel) {
        if let current {
            current.window?.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let controller = MainWindowController(model: model)
        current = controller
        controller.showWindow(nil)
        NSApp.activate()
    }

    /// True while a main window exists. Used by measurements to confirm release after close.
    static var isOpen: Bool { current != nil }

    /// Closes the window exactly as the close button would. Used by the memory measurement cycle.
    static func closeForMeasurement() {
        current?.close()
    }

    private init(model: AppModel) {
        let hosting = NSHostingController(rootView: MainWindowView(model: model))
        // Keep the window at the size below (or the user's saved size); do not let SwiftUI's
        // ideal size shrink it to the view's minimum.
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.title = "Spendable"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 720, height: 480))
        window.minSize = NSSize(width: 520, height: 360)
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("MainWindow")
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MainWindowController is created in code only")
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentViewController = nil
        window?.delegate = nil
        Self.current = nil
    }
}
