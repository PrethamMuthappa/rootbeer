import AppKit
import RootBeerCore
import SwiftUI

/// Resolves and caches app icons off the main thread. `nil` means "use an SF Symbol".
actor IconCache {
    static let shared = IconCache()

    private struct Entry: @unchecked Sendable { let image: NSImage? }
    private var cache: [String: Entry] = [:]

    private let searchRoots = [
        "/Applications",
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path,
    ]

    func icon(for package: Package) -> NSImage? {
        if let hit = cache[package.id] { return hit.image }
        let image = appPath(for: package).map { NSWorkspace.shared.icon(forFile: $0) }
        cache[package.id] = Entry(image: image)
        return image
    }

    private func appPath(for package: Package) -> String? {
        guard package.kind == .cask else { return nil }
        let fm = FileManager.default
        for app in package.appNames {
            let expanded = (app as NSString).expandingTildeInPath
            if expanded.hasPrefix("/") {
                if fm.fileExists(atPath: expanded) { return expanded }
                continue
            }
            for root in searchRoots {
                let path = (root as NSString).appendingPathComponent(app)
                if fm.fileExists(atPath: path) { return path }
            }
        }
        return nil
    }
}

struct PackageIcon: View {
    let package: Package
    var size: CGFloat = 48

    // Explicit `State` storage; see RootBeerApp for why `@State` isn't used.
    private let imageState = State<NSImage?>(initialValue: nil)
    private let resolvedState = State(initialValue: false)
    private var image: NSImage? {
        get { imageState.wrappedValue }
        nonmutating set { imageState.wrappedValue = newValue }
    }
    private var resolved: Bool {
        get { resolvedState.wrappedValue }
        nonmutating set { resolvedState.wrappedValue = newValue }
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Image(systemName: package.kind == .formula ? "terminal" : "shippingbox")
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.2)
                    .foregroundStyle(.secondary)
                    .opacity(resolved ? 1 : 0.4)
            }
        }
        .frame(width: size, height: size)
        .task(id: package.id) {
            image = await IconCache.shared.icon(for: package)
            resolved = true
        }
    }
}
