import RootBeerCore
import SwiftUI

struct PackageGridView: View {
    @Environment(AppModel.self) private var model

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 12)]

    var body: some View {
        let packages = model.visiblePackages
        let item = model.sidebarSelection ?? .all
        Group {
            if let error = model.loadError, model.inventory.packages.isEmpty {
                ContentUnavailableView("Couldn't load packages", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if model.sidebarSelection == .unused, let error = model.unusedError {
                ContentUnavailableView("Couldn't check for unused packages", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if model.sidebarSelection == .unused, packages.isEmpty, model.searchText.isEmpty, !model.isLoading {
                ContentUnavailableView(
                    "Nothing unused",
                    systemImage: "leaf",
                    description: Text("`brew autoremove --dry-run` doesn't list any formulae.")
                )
            } else if packages.isEmpty && !model.isLoading {
                let hidden = model.hiddenDependencyCount(for: item)
                ContentUnavailableView(
                    model.searchText.isEmpty ? "Nothing here" : "No matches",
                    systemImage: "shippingbox",
                    description: hidden > 0 ? Text("Dependencies are hidden. Choose All above to see them.") : nil
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(packages) { package in
                            PackageCard(package: package, isSelected: package.id == model.selectedID, isUnused: model.isUnused(package))
                                .onTapGesture { model.selectedID = package.id }
                        }
                    }
                    .padding()
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if item.supportsRequestedFilter, !model.inventory.packages.isEmpty {
                RequestedFilterBar(item: item)
            }
        }
        .overlay(alignment: .bottom) {
            if let error = model.loadError, !model.inventory.packages.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(.red, in: .rect(cornerRadius: 6))
                    .padding()
            }
        }
    }
}

/// All | Installed by me. "Installed by me" hides formulae brew installed only as dependencies.
private struct RequestedFilterBar: View {
    @Environment(AppModel.self) private var model
    let item: SidebarItem

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 10) {
            Picker("Show", selection: $model.showOnlyRequested) {
                Text("All").tag(false)
                Text("Installed by me").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Installed by me hides packages Homebrew installed only as dependencies of others")

            let hidden = model.hiddenDependencyCount(for: item)
            if hidden > 0 {
                Text("\(hidden) \(hidden == 1 ? "dependency" : "dependencies") hidden")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

struct PackageCard: View {
    let package: Package
    let isSelected: Bool
    let isUnused: Bool

    var body: some View {
        VStack(spacing: 6) {
            PackageIcon(package: package)
            Text(package.displayName)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(versionText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(spacing: 4) {
                if isUnused {
                    Badge(text: "unused", color: .purple)
                } else if package.isDependency {
                    Badge(text: "dependency", color: .gray)
                }
                if package.isOutdated { Badge(text: "outdated", color: .orange) }
            }
            .frame(height: 16)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.07), in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 1.5))
        .contentShape(.rect)
        .help(package.desc ?? package.name)
    }

    private var versionText: String {
        if package.isOutdated, let latest = package.latestVersion {
            return "\(package.installedVersion) → \(latest)"
        }
        return package.installedVersion
    }
}

struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: .capsule)
    }
}
