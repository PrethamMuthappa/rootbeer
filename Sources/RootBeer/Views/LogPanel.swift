import AppKit
import SwiftUI

struct LogPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            ResizeHandle()
            header
            Divider()
            if let outcome = model.outcome {
                OutcomeBanner(outcome: outcome)
                Divider()
            }
            logLines
        }
        .frame(height: model.logHeight)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let operation = model.activeOperation {
                ProgressView().controlSize(.small)
                Text(operation).font(.callout.weight(.semibold))
            } else {
                Text("Log").font(.callout.weight(.semibold))
            }
            Spacer()
            Button("Copy Log") { copy(model.log.map(\.text).joined(separator: "\n")) }
                .disabled(model.log.isEmpty)
            Button("Clear") { model.clearLog() }
                .disabled(model.isBusy || model.log.isEmpty)
            Button { model.showLog = false } label: { Image(systemName: "chevron.down") }
                .help("Hide log")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var logLines: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(model.log) { entry in
                        LogLine(entry: entry)
                            .id(entry.id)
                    }
                }
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .frame(maxHeight: .infinity)
            .onChange(of: model.log.last?.text.count) {
                if let last = model.log.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }
}

private struct LogLine: View {
    let entry: LogEntry

    var body: some View {
        Text(entry.text.trimmingCharacters(in: .newlines))
            .font(.system(size: 11.5, design: .monospaced).weight(entry.kind == .command ? .semibold : .regular))
            .foregroundStyle(color)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Space above each command and section header so separate steps read as blocks.
            .padding(.top, entry.kind == .command || entry.kind == .info ? 6 : 0)
    }

    private var color: Color {
        switch entry.kind {
        case .command: .primary
        case .stdout: .secondary
        case .stderr: .orange
        case .info: .blue
        case .success: .green
        case .failure: .red
        }
    }
}

/// Drag the top edge of the log panel to resize it.
private struct ResizeHandle: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: 6)
            .overlay(Capsule().fill(.tertiary).frame(width: 36, height: 3))
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        // Measure from the height at drag start; this view is rebuilt as the height changes.
                        let base = model.logDragStartHeight ?? model.logHeight
                        model.logDragStartHeight = base
                        model.logHeight = min(max(base - value.translation.height, 140), 800)
                    }
                    .onEnded { _ in model.logDragStartHeight = nil }
            )
            .help("Drag to resize the log")
    }
}

struct OutcomeBanner: View {
    let outcome: Outcome

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: outcome.succeeded
                  ? (outcome.unexpectedlyRemoved.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                  : "xmark.octagon.fill")
                .foregroundStyle(tint)
                .font(.title3)

            VStack(alignment: .leading, spacing: 8) {
                Text(outcome.succeeded ? "\(outcome.title) succeeded" : "\(outcome.title) failed")
                    .font(.callout.bold())
                Text(outcome.detail)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let command = outcome.terminalCommand {
                    CommandBox(command: command)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .fixedSize(horizontal: false, vertical: true)
        .background(tint.opacity(0.10))
    }

    /// Orange when brew changed more than RootBeer asked for, even if every command exited 0.
    private var tint: Color {
        if !outcome.succeeded { return .red }
        return outcome.unexpectedlyRemoved.isEmpty ? .green : .orange
    }
}

/// A Terminal command on its own row, wrapped rather than truncated, with a Copy button.
private struct CommandBox: View {
    let command: String

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(command)
                .font(.system(size: 12, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                copy(command)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
    }
}

private func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
