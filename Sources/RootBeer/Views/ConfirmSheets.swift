import RootBeerCore
import SwiftUI

/// Common layout: title, scrolling body, Cancel + one action button.
struct ConfirmSheet<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let actionTitle: String
    var destructive = false
    var actionDisabled = false
    var extraButton: (title: String, action: () -> Void)?
    let action: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 10) { content }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 420)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if let extraButton {
                    Button(extraButton.title) { dismiss(); extraButton.action() }
                }
                // Return doesn't trigger destructive actions; they need a click.
                Button(actionTitle, role: destructive ? .destructive : nil) { dismiss(); action() }
                    .keyboardShortcut(destructive ? nil : .defaultAction)
                    .disabled(actionDisabled)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

struct StalenessNote: View {
    let snapshot: DataSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("From `brew outdated` at \(snapshot.loadedAt.formatted(date: .omitted, time: .shortened)).")
            if let refreshed = snapshot.metadataUpdatedAt {
                Text("Homebrew's package data was last refreshed \(refreshed.formatted(.relative(presentation: .named))).")
            }
            if snapshot.mayBeStale {
                Label("This may be out of date. RootBeer turns off brew's automatic update, so run Update Homebrew first to upgrade to the newest versions.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

struct UpgradeAllSheet: View {
    @Environment(AppModel.self) private var model
    let packages: [Package]
    let snapshot: DataSnapshot

    var body: some View {
        let upgradable = packages.filter { !$0.isPinned }
        ConfirmSheet(
            title: "Upgrade \(upgradable.count) package\(upgradable.count == 1 ? "" : "s")?",
            actionTitle: "Upgrade All",
            actionDisabled: upgradable.isEmpty,
            extraButton: snapshot.mayBeStale ? ("Update Homebrew First", { Task { await model.updateHomebrew() } }) : nil,
            action: { Task { await model.upgradeAll() } }
        ) {
            StalenessNote(snapshot: snapshot)
            Text("Runs `brew upgrade`. brew may also install or upgrade dependencies.")
                .font(.callout)
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(packages) { package in
                    GridRow {
                        Text(package.name).fontWeight(.medium)
                        Text(package.kind == .cask ? "cask" : "formula").foregroundStyle(.secondary)
                        Text("\(package.installedVersion) → \(package.latestVersion ?? "?")").monospacedDigit()
                        if package.isPinned { Text("pinned, skipped").foregroundStyle(.orange) }
                    }
                }
            }
            .font(.callout)
        }
    }
}

struct UpgradeSheet: View {
    @Environment(AppModel.self) private var model
    let package: Package
    let snapshot: DataSnapshot

    var body: some View {
        ConfirmSheet(
            title: "Upgrade \(package.displayName)?",
            actionTitle: "Upgrade",
            actionDisabled: package.isPinned,
            extraButton: snapshot.mayBeStale ? ("Update Homebrew First", { Task { await model.updateHomebrew() } }) : nil,
            action: { Task { await model.upgrade(package) } }
        ) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow { Text("Installed").foregroundStyle(.secondary); Text(package.installedVersion).monospacedDigit() }
                GridRow { Text("New").foregroundStyle(.secondary); Text(package.latestVersion ?? "?").monospacedDigit() }
            }
            if package.isPinned {
                Text("This package is pinned. Unpin it in Terminal to upgrade it.").foregroundStyle(.orange)
            }
            Text("Runs `\(BrewAction.upgrade(package).commandLine)`. brew may also upgrade its dependencies and packages that depend on it.")
                .font(.callout)
            StalenessNote(snapshot: snapshot)
        }
    }
}

struct CaskUninstallSheet: View {
    @Environment(AppModel.self) private var model
    let cask: Package

    var body: some View {
        ConfirmSheet(
            title: "Uninstall \(cask.displayName)?",
            actionTitle: "Uninstall",
            destructive: true,
            action: { Task { await model.uninstallCask(cask) } }
        ) {
            Text("Runs `\(BrewAction.uninstall(cask).commandLine)`.")
            if !cask.appNames.isEmpty {
                Text("Removes: \(cask.appNames.map { ($0 as NSString).lastPathComponent }.uniqued().joined(separator: ", "))")
            }
            Text("Settings and support files are left in place (no --zap).")
                .foregroundStyle(.secondary)
            Text("If the cask's uninstaller needs an administrator password, RootBeer will stop and show the command to run in Terminal.")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
    }
}

struct CleanupSheet: View {
    @Environment(AppModel.self) private var model
    let dryRunOutput: String

    var body: some View {
        ConfirmSheet(
            title: "Clean up?",
            actionTitle: "Clean Up",
            destructive: true,
            actionDisabled: dryRunOutput.isEmpty,
            action: { Task { await model.cleanup() } }
        ) {
            if dryRunOutput.isEmpty {
                Text("`brew cleanup --dry-run` found nothing to remove.")
            } else {
                Text("`brew cleanup --dry-run` says `brew cleanup` would do this:")
                Text(dryRunOutput)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.1), in: .rect(cornerRadius: 6))
            }
        }
    }
}

extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}
