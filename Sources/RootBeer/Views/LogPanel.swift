import AppKit
import SwiftUI

struct LogPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if let operation = model.activeOperation {
                    ProgressView().controlSize(.small)
                    Text(operation).font(.callout.weight(.medium))
                } else {
                    Text("Log").font(.callout.weight(.medium))
                }
                Spacer()
                Button("Clear") { model.clearLog() }
                    .disabled(model.isBusy || model.log.isEmpty)
                Button { model.showLog = false } label: { Image(systemName: "chevron.down") }
                    .help("Hide log")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            if let outcome = model.outcome {
                OutcomeBanner(outcome: outcome)
            }

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(model.log) { entry in
                            Text(entry.text.trimmingCharacters(in: .newlines))
                                .font(.system(.caption, design: .monospaced).weight(entry.kind == .command ? .semibold : .regular))
                                .foregroundStyle(color(for: entry.kind))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(entry.id)
                        }
                    }
                    .textSelection(.enabled)
                    .padding(10)
                }
                .onChange(of: model.log.last?.text.count) {
                    if let last = model.log.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .frame(height: 220)
        .background(.background)
    }

    private func color(for kind: LogEntry.Kind) -> Color {
        switch kind {
        case .command: .primary
        case .stdout: .secondary
        case .stderr: .orange
        case .info: .blue
        case .success: .green
        case .failure: .red
        }
    }
}

struct OutcomeBanner: View {
    let outcome: Outcome

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: outcome.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(outcome.succeeded ? .green : .red)
                .font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text(outcome.succeeded ? "\(outcome.title) succeeded" : "\(outcome.title) FAILED")
                    .font(.callout.bold())
                Text(outcome.detail).font(.callout).textSelection(.enabled)
                if let command = outcome.terminalCommand {
                    HStack {
                        Text(command)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(6)
                            .background(Color.secondary.opacity(0.12), in: .rect(cornerRadius: 4))
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(command, forType: .string)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(tint.opacity(0.12))
    }

    /// Orange when brew changed more than RootBeer asked for, even if every command exited 0.
    private var tint: Color {
        if !outcome.succeeded { return .red }
        return outcome.unexpectedlyRemoved.isEmpty ? .green : .orange
    }
}
