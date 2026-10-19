import RootBeerCore
import SwiftUI

struct UninstallSheet: View {
    @Environment(AppModel.self) private var model
    @Bindable var draft: UninstallDraft

    var body: some View {
        let plan = draft.plan
        ConfirmSheet(
            title: "Uninstall \(draft.target.name)?",
            actionTitle: "Uninstall \(plan.uninstallOrder.count) package\(plan.uninstallOrder.count == 1 ? "" : "s")",
            destructive: true,
            actionDisabled: !draft.canConfirm,
            action: { Task { await model.uninstall(confirmed: plan, force: draft.force) } }
        ) {
            section("Package") {
                Label(draft.target.name, systemImage: "shippingbox").fontWeight(.medium)
            }

            if !plan.candidateDependencies.isEmpty {
                section("Dependencies that nothing else needs") {
                    ForEach(plan.candidateDependencies, id: \.self) { id in
                        dependencyRow(id, plan: plan)
                    }
                    Text("After the package is removed, RootBeer runs `brew autoremove --dry-run` and only removes the ticked dependencies that brew also lists as unneeded. The rest stay installed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("No dependencies will be removed.").foregroundStyle(.secondary)
            }

            if !plan.candidateDependents.isEmpty {
                section("Packages that depend on \(draft.target.name)") {
                    ForEach(plan.candidateDependents, id: \.self) { id in
                        Toggle(isOn: membership(id, in: \.includedDependents)) {
                            Text("Also uninstall \(name(id))")
                        }
                    }
                }
            }

            if plan.isBlocked {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Still needed by: \(plan.blockingDependents.map(name).joined(separator: ", "))",
                          systemImage: "exclamationmark.octagon.fill")
                        .foregroundStyle(.red)
                        .fontWeight(.medium)
                    Text("brew will most likely refuse to uninstall it while these are installed. Tick them above to remove them too.")
                        .font(.caption)
                    Toggle("Force: try anyway", isOn: $draft.force)
                    Text("Force only clears this warning. It doesn't change the brew command or remove anything else. If brew refuses, RootBeer shows its error and stops.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .background(Color.red.opacity(0.08), in: .rect(cornerRadius: 8))
            }

            section("Commands, in order") {
                ForEach(plan.uninstallOrder, id: \.self) { id in
                    if let package = draft.package(id) {
                        Text(BrewAction.uninstall(package).commandLine)
                            .font(.system(.caption, design: .monospaced))
                    }
                    if id == plan.roots.last, !plan.dependencies.isEmpty {
                        Text("brew autoremove --dry-run   (cross-check)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .font(.callout)
    }

    @ViewBuilder
    private func dependencyRow(_ id: Package.ID, plan: RemovalPlan) -> some View {
        let excluded = plan.excludedDependencies.contains(id)
        let keptByOther = !excluded && !plan.dependencies.contains(id)
        Toggle(isOn: Binding(
            get: { !draft.excludedDependencies.contains(id) },
            set: { keep in
                if keep { draft.excludedDependencies.remove(id) } else { draft.excludedDependencies.insert(id) }
            }
        )) {
            HStack {
                Text(name(id))
                if keptByOther {
                    Text("kept: needed by a dependency you unticked").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .disabled(keptByOther)
    }

    private func membership(_ id: Package.ID, in keyPath: ReferenceWritableKeyPath<UninstallDraft, Set<Package.ID>>) -> Binding<Bool> {
        Binding(
            get: { draft[keyPath: keyPath].contains(id) },
            set: { on in
                if on { draft[keyPath: keyPath].insert(id) } else { draft[keyPath: keyPath].remove(id) }
            }
        )
    }

    private func name(_ id: Package.ID) -> String { draft.graph.name(id) }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content()
        }
    }
}
