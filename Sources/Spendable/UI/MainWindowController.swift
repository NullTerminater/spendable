import AppKit
import Observation
import SwiftUI

/// State shared between the AppKit window chrome and the SwiftUI content of the main window.
@MainActor
@Observable
final class MainWindowState {
    var addingAccount = false
}

/// The main window, hosted by AppKit so it can be created on demand and genuinely released when
/// closed. A SwiftUI `Window` scene keeps its NSWindow and view state alive after close; this
/// controller drops the content view, the window and itself in `windowWillClose`.
///
/// The SwiftUI content sits inside a plain container view rather than being the window's content
/// view directly: when an `NSHostingView` is the content view, SwiftUI resizes the window to the
/// content's ideal size after every layout (a spinner state shrinks the window to 151×53 and a
/// user's resize is undone within 100 ms). Inside a container the window's size is AppKit's alone.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    private static var current: MainWindowController?

    private static let addAccountItem = NSToolbarItem.Identifier("spendable.addAccount")
    private static let contentSize = NSSize(width: 720, height: 480)
    private static let minimumContentSize = NSSize(width: 520, height: 360)

    private let model: AppModel
    private let state = MainWindowState()

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

    static func protectSetupWindow(_ protect: Bool) {
        current?.window?.sharingType = protect ? .none : .readOnly
        current?.window?.isRestorable = false
    }

    static func clearSetupField() {
        guard let window = current?.window else { return }
        window.fieldEditor(false, for: nil)?.undoManager?.removeAllActions()
        window.makeFirstResponder(nil)
    }

    /// True while a main window exists. Used by measurements to confirm release after close.
    static var isOpen: Bool { current != nil }

    /// Closes the window exactly as the close button would. Used by the memory measurement cycle.
    static func closeForMeasurement() {
        current?.close()
    }

    private init(model: AppModel) {
        self.model = model

        let hostingView = NSHostingView(rootView: MainWindowView(model: model, state: state))
        hostingView.sizingOptions = []
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(origin: .zero, size: Self.contentSize))
        container.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: container.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "Spendable"
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        window.contentView = container
        window.contentMinSize = Self.minimumContentSize
        window.setContentSize(Self.contentSize)
        window.center()
        window.setFrameAutosaveName("MainWindow")
        super.init(window: window)

        let toolbar = NSToolbar(identifier: "spendable.main")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MainWindowController is created in code only")
    }

    func windowWillClose(_ notification: Notification) {
        window?.toolbar = nil
        window?.contentView = nil
        window?.delegate = nil
        Self.current = nil
    }

    // MARK: Toolbar

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.addAccountItem]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.addAccountItem]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard identifier == Self.addAccountItem else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "Add an account by hand"
        item.paletteLabel = item.label
        item.toolTip = item.label
        item.image = NSImage(systemSymbolName: "plus", accessibilityDescription: item.label)
        item.isBordered = true
        item.target = self
        item.action = #selector(addAccount(_:))
        return item
    }

    @objc private func addAccount(_ sender: Any?) {
        guard model.database != nil else { return }
        state.addingAccount = true
    }
}
