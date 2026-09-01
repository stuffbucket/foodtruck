import AppKit

// FoodTruck — a deliberately trivial AppKit app.
//
// Its only job is to be a REAL, signable Mach-O bundle so the
// stuffbucket/macos-builder pipeline can be exercised end to end:
//   producer builds .app -> builder signs -> dmg -> notarize -> staple
//   -> checksum -> attach to a DRAFT release.
//
// Keep it dependency-free. Anything that needs a package manager or a
// network fetch makes this a worse pipeline test, not a better app.

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Stamped by .macos-builder/build.sh from the release tag.
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "unknown"

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 220),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "FoodTruck"
        window.center()

        let label = NSTextField(labelWithString: "🚚  Hello from FoodTruck\n\nversion \(version)")
        label.alignment = .center
        label.font = .systemFont(ofSize: 20, weight: .medium)
        label.maximumNumberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false

        let content = window.contentView!
        content.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

// `delegate` is a top-level binding, so it lives for the process lifetime —
// NSApplication holds its delegate weakly.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
