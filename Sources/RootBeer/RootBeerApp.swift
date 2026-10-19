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
        WindowGroup("RootBeer") {
            ContentView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 560)
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
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (`swift run`) rather than from RootBeer.app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
