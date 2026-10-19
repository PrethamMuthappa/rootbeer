import RootBeerCore
import SwiftUI

struct DetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let package = model.selectedPackage {
            PackageDetail(package: package)
                .id(package.id)
        } else {
            ContentUnavailableView("No Selection", systemImage: "shippingbox", description: Text("Select a package to see its details."))
        }
    }
}

private struct PackageDetail: View {
    @Environment(AppModel.self) private var model
    let package: Package

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    PackageIcon(package: package, size: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(package.displayName).font(.title2.bold())
                        Text(package.kind == .formula ? "Formula · \(package.fullName)" : "Cask · \(package.fullName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        HStack(spacing: 4) {
                            if package.isDependency { Badge(text: "dependency", color: .gray) }
                            if package.isOutdated { Badge(text: "outdated", color: .orange) }
                        }
                    }
                }

                HStack {
                    if package.isOutdated {
                        Button("Upgrade…") { model.requestUpgrade(package) }
                    }
                    Button("Uninstall…", role: .destructive) { model.requestUninstall(package) }
                }
                .disabled(model.isBusy)

                if let desc = package.desc {
                    Text(desc)
                }

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    row("Installed", package.installedVersion)
                    if package.isOutdated {
                        row("Available", package.latestVersion ?? "newer version")
                    }
                    if let tap = package.tap { row("Tap", tap) }
                    if package.kind == .formula {
                        row("Reason", package.installedOnRequest ? "Installed on request" : "Installed as a dependency")
                    }
                    if let homepage = package.homepage, let url = URL(string: homepage) {
                        GridRow {
                            Text("Homepage").foregroundStyle(.secondary)
                            Link(homepage, destination: url).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
                .font(.callout)

                section("Dependencies") {
                    if package.dependencies.isEmpty {
                        Text("None").foregroundStyle(.secondary)
                    } else {
                        nameList(package.dependencies)
                    }
                }

                section("Used by (installed)") {
                    usedBy
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: package.id) { await model.loadUses(for: package) }
    }

    @ViewBuilder
    private var usedBy: some View {
        if package.kind == .cask {
            Text("Casks can't be dependencies of other packages.").foregroundStyle(.secondary)
        } else {
            switch model.uses[package.name] {
            case nil, .loading?:
                ProgressView().controlSize(.small)
            case .failed(let message)?:
                Text(message).foregroundStyle(.red).font(.caption).textSelection(.enabled)
            case .loaded(let names)?:
                if names.isEmpty {
                    Text("Nothing installed depends on this.").foregroundStyle(.secondary)
                } else {
                    nameList(names)
                }
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content()
        }
    }

    /// Names link to the package when it's installed.
    private func nameList(_ names: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(names, id: \.self) { name in
                if let target = model.package(named: name) {
                    Button(name) { model.selectedID = target.id }
                        .buttonStyle(.link)
                } else {
                    Text(name).foregroundStyle(.secondary)
                }
            }
        }
    }
}
