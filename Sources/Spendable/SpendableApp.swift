import AppKit
import SwiftUI

/// Menu bar only (LSUIElement). The placeholder menu below is replaced in milestone 7 by the
/// number-in-the-bar item and the compact panel; until then it exists so the app can be reached.
@main
struct SpendableApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            Button("Open Spendable") {
                MainWindowController.show(model: model)
            }
            .keyboardShortcut("o")
            Divider()
            Button("Quit Spendable") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        } label: {
            Label("Spendable", systemImage: "dollarsign.circle")
                .onAppear {
                    LaunchTiming.markStatusItemVisible()
                    model.start()
                    #if DEBUG
                    DebugLaunchOptions.apply(model: model)
                    #endif
                }
        }
    }
}

extension ProcessInfo {
    /// True when the process is the host of an XCTest / Swift Testing run.
    var isRunningTests: Bool {
        environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil
    }
}
