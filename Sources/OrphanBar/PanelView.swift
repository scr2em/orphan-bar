import AppKit
import SwiftUI

/// What the menu bar icon opens: the orphans, what each costs, and a way to end them.
struct PanelView: View {
    let monitor: OrphanMonitor
    /// Off only for `--snapshot`: `ImageRenderer` draws nothing inside a scroll view.
    var scrolls = true

    private static let rowHeight: CGFloat = 64
    private static let maxListHeight: CGFloat = 448

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(monitor: monitor)
            Divider()

            if monitor.processes.isEmpty {
                EmptyStateView()
            } else if scrolls {
                ScrollView {
                    LazyVStack(spacing: 2) { rows }.padding(6)
                }
                .frame(height: min(CGFloat(monitor.processes.count) * Self.rowHeight + 12, Self.maxListHeight))
            } else {
                VStack(spacing: 2) { rows }.padding(6)
            }

            Divider()
            FooterView(count: monitor.processes.count, onTerminateAll: monitor.terminateAll)
        }
        .frame(width: 460)
        .onAppear { monitor.isPanelOpen = true }
        .onDisappear { monitor.isPanelOpen = false }
    }

    private var rows: some View {
        ForEach(monitor.processes) { process in
            ProcessRow(
                process: process,
                termination: monitor.terminations[process.id],
                onTerminate: { force in monitor.terminate(process, force: force) },
                onIgnore: { monitor.ignore(process.name) }
            )
        }
    }
}

private struct HeaderView: View {
    let monitor: OrphanMonitor

    private var summary: String {
        let count = monitor.processes.count
        guard count > 0 else { return "Nothing left behind" }

        let noun = count == 1 ? "process" : "processes"

        return "\(count) \(noun) · \(Format.cpu(monitor.totalCPU)) CPU · \(Format.memory(monitor.totalMemory))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: monitor.isHot ? "flame.fill" : "cpu.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill((monitor.isHot ? Color.red : Color.accentColor).gradient)
                    )

                VStack(alignment: .leading, spacing: 1) {
                    Text("Orphaned Processes").font(.headline)
                    Text(summary).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }

                Spacer()

                Button(action: monitor.refresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh now")

                SettingsMenu(monitor: monitor)
            }

            if let error = monitor.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(12)
    }
}

private struct SettingsMenu: View {
    let monitor: OrphanMonitor

    var body: some View {
        Menu {
            Toggle(
                "Launch at Login",
                isOn: Binding(get: { monitor.launchesAtLogin }, set: { monitor.setLaunchesAtLogin($0) })
            )

            Menu("Ignored Names") {
                if monitor.ignoredNames.isEmpty {
                    Text("None")
                }

                ForEach(monitor.ignoredNames, id: \.self) { name in
                    Button("Show “\(name)” Again") { monitor.unignore(name) }
                }
            }

            Divider()

            Button("Quit OrphanBar") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

private struct ProcessRow: View {
    let process: OrphanProcess
    let termination: Termination?
    let onTerminate: (_ force: Bool) -> Void
    let onIgnore: () -> Void

    @State private var hovering = false
    @State private var hoveringButton = false

    private var kind: ProcessKind { ProcessKind.of(process.name) }

    private var details: String {
        var parts = ["PID \(process.pid)", Format.uptime(since: process.startedAt)]
        if let folder = process.workingDirectory { parts.append(folder) }

        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: kind.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(kind.tint)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(kind.tint.opacity(0.14)))

            VStack(alignment: .leading, spacing: 2) {
                Text(process.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)

                Text(process.command)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if case .failed(let reason) = termination {
                    Text("Couldn’t terminate: \(reason)").font(.caption2).foregroundStyle(.red)
                } else {
                    Text(details)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 4) {
                CPUBadge(percent: process.cpuPercent)
                Text(Format.memory(process.memoryBytes))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 64, alignment: .trailing)

            action.frame(width: termination == .stubborn ? 84 : 22)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .opacity(isTerminating ? 0.5 : 1)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hovering ? Color.primary.opacity(0.06) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(process.fullCommand)
        .contextMenu { contextMenu }
    }

    private var isTerminating: Bool {
        if case .requested = termination { return true }

        return false
    }

    @ViewBuilder
    private var action: some View {
        switch termination {
        case .requested:
            ProgressView().controlSize(.small)
        case .stubborn:
            Button { onTerminate(true) } label: {
                Label("Force Kill", systemImage: "bolt.fill").font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.small)
            .help("It ignored the request to quit; send SIGKILL")
        case .failed, nil:
            Button { onTerminate(NSEvent.modifierFlags.contains(.option)) } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(hoveringButton ? Color.red : Color.secondary)
            }
            .buttonStyle(.plain)
            .onHover { hoveringButton = $0 }
            .help("Terminate (⌥-click to force kill)")
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button("Terminate") { onTerminate(false) }
        Button("Force Kill") { onTerminate(true) }
        Divider()
        Button("Copy Command") { copy(process.fullCommand) }
        Button("Copy PID") { copy(String(process.pid)) }

        if let folder = process.workingDirectory {
            Button("Show Working Folder in Finder") {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: (folder as NSString).expandingTildeInPath)
            }
        }

        Divider()
        Button("Ignore “\(process.name)”") { onIgnore() }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct CPUBadge: View {
    let percent: Double

    private var tint: Color {
        if percent >= 50 { return .red }
        if percent >= 5 { return .orange }

        return .secondary
    }

    var body: some View {
        Text(Format.cpu(percent))
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.14)))
    }
}

private struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 30))
                .foregroundStyle(.green)
            Text("No orphaned processes").font(.headline)
            Text("Processes whose parent has exited show up here.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}

private struct FooterView: View {
    let count: Int
    let onTerminateAll: () -> Void

    @State private var confirming = false

    var body: some View {
        HStack(spacing: 8) {
            if confirming {
                Text("Terminate all \(count)?").font(.caption.weight(.medium))
                Spacer()
                Button("Cancel") { confirming = false }.controlSize(.small)
                Button("Terminate All", role: .destructive) {
                    onTerminateAll()
                    confirming = false
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.small)
            } else {
                Text("Right-click a row for more").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("Terminate All…") { confirming = true }
                    .controlSize(.small)
                    .disabled(count == 0)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        // the question takes itself back if it is left unanswered
        .task(id: confirming) {
            guard confirming else { return }
            try? await Task.sleep(for: .seconds(5))
            confirming = false
        }
    }
}

/// The menu bar item: a chip when nothing is left behind, the count beside it otherwise, and
/// a flame while one of them burns half a core or more.
struct MenuBarLabel: View {
    let monitor: OrphanMonitor

    var body: some View {
        let count = monitor.processes.count

        if count == 0 {
            Image(systemName: "cpu")
        } else {
            Label("\(count)", systemImage: monitor.isHot ? "flame.fill" : "cpu.fill")
                .labelStyle(.titleAndIcon)
        }
    }
}
