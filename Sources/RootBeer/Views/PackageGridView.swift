import RootBeerCore
import SwiftUI

struct PackageGridView: View {
    @Environment(AppModel.self) private var model

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 12)]

    var body: some View {
        let packages = model.visiblePackages
        Group {
            if let error = model.loadError, model.inventory.packages.isEmpty {
                ContentUnavailableView("Couldn't load packages", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if packages.isEmpty && !model.isLoading {
                ContentUnavailableView(
                    model.searchText.isEmpty ? "Nothing here" : "No matches",
                    systemImage: "shippingbox"
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(packages) { package in
                            PackageCard(package: package, isSelected: package.id == model.selectedID)
                                .onTapGesture { model.selectedID = package.id }
                        }
                    }
                    .padding()
                }
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

struct PackageCard: View {
    let package: Package
    let isSelected: Bool

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
                if package.isDependency { Badge(text: "dependency", color: .gray) }
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
