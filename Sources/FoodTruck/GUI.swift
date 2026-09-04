import AppKit
import SwiftUI
import FoodTruckKit

/// The window, brought up programmatically rather than with `@main struct App`.
///
/// One binary has to be able to decide at launch whether it is a command or an
/// app, and the SwiftUI `App` lifecycle takes that decision away -- it wants the
/// entry point. So the process starts as a plain executable, works out which
/// face it is wearing, and only then builds an `NSApplication`. The cost is this
/// file; the benefit is that `foodtruck audit` in a terminal and the Check
/// Again button run the same code, because there is only one binary and one
/// engine.
enum GUI {
    @MainActor
    static func run() async {
        let app = NSApplication.shared
        let delegate = Delegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    @MainActor
    final class Delegate: NSObject, NSApplicationDelegate {
        private var window: NSWindow!

        func applicationDidFinishLaunching(_ notification: Notification) {
            let content = NSHostingView(rootView: RootView())
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false)
            window.title = t("window.title")
            window.contentView = content
            // Below this the sidebar and the detail form start fighting for
            // room, and a cramped list is worse than a scroll bar.
            window.minSize = NSSize(width: 720, height: 420)
            window.setFrameAutosaveName("FoodTruckMain")
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }

        func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
            true
        }
    }
}
