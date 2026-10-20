import AppKit
import SwiftUI

@main
struct RootBeerApp: App {
    @NSApplicationDelegateAdaptor(RootBeerAppDelegate.self) private var appDelegate
    // Explicit `State` storage instead of `@State`: in the macOS 27 SDK `@State` is a macro whose
    // plugin ships only with Xcode, so the attribute won't compile with the Command Line Tools.
    private let modelState = State(initialValue: AppModel())
    private var model: AppModel { modelState.wrappedValue }

    var body: some Scene {
        // A single window: a second one would share the same model, sheets and operations.
        Window("RootBeer", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 560)
                .onAppear { appDelegate.model = model }
                .task { await model.reload() }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Reload Packages") { Task { await model.reload() } }
                    .keyboardShortcut("r")
                    .disabled(model.isBusy)
            }
            CommandGroup(after: .sidebar) {
                Toggle("Show Only Packages I Installed", isOn: Binding(
                    get: { model.showOnlyRequested },
                    set: { model.showOnlyRequested = $0 }
                ))
                .keyboardShortcut("d", modifiers: [.command, .shift])
            }
        }
    }
}

final class RootBeerAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (`swift run`) rather than from RootBeer.app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if Bundle.main.bundleURL.pathExtension != "app", let icon = Self.developmentIcon() {
            NSApp.applicationIconImage = icon
        }
    }

    /// RootBeer.app gets its icon from AppIcon.icns. A development build (.build/…/RootBeer) has no
    /// bundle, so look for the project's Resources/AppIcon.png a few folders up from the executable.
    private static func developmentIcon() -> NSImage? {
        var folder = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<5 {
            guard let current = folder else { return nil }
            let candidate = current.appendingPathComponent("Resources/AppIcon.png")
            if FileManager.default.fileExists(atPath: candidate.path) { return NSImage(contentsOf: candidate) }
            folder = current.deletingLastPathComponent()
        }
        return nil
    }

    /// Closing the window quits, except while brew is changing things: then RootBeer stays open
    /// until brew finishes, so it isn't cut off halfway through an upgrade or uninstall.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        guard let model, model.activeOperation != nil else { return true }
        model.quitWhenOperationFinishes = true
        return false
    }

    /// Quitting while brew is changing things asks first; the safe choice is the default.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, let operation = model.activeOperation else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "\(operation) is still running"
        alert.informativeText = "Quitting now stops brew partway through, which can leave packages half-installed or half-removed. "
            + "If you close the window instead, RootBeer quits by itself when brew finishes."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Keep Running")
        alert.addButton(withTitle: "Quit Anyway")
        guard alert.runModal() == .alertSecondButtonReturn else {
            model.quitWhenOperationFinishes = false
            return .terminateCancel
        }
        return .terminateNow
    }
}
