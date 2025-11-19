import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var remapper: ButtonRemapper!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Add menu bar icon
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.title = "🖱️"

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu

        remapper = ButtonRemapper()
    }

    @objc func quit() {
        NSApplication.shared.terminate(nil)
    }
}
