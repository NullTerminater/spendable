import AppKit

@MainActor
final class SpendableApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model?.unsavedConnection != nil else { return .terminateNow }
        Task { @MainActor in
            let alert = NSAlert()
            alert.messageText = "Your bank connection isn't saved yet."
            alert.informativeText = "If you quit now it's gone and you'll have to make a new setup token on the SimpleFIN website."
            alert.addButton(withTitle: "Keep Spendable open")
            alert.addButton(withTitle: "Quit anyway")
            sender.reply(toApplicationShouldTerminate: alert.runModal() == .alertSecondButtonReturn)
        }
        return .terminateLater
    }
}
