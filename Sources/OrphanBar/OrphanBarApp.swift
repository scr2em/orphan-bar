import AppKit
import SwiftUI

@main
enum Entry {
    /// `--list` prints the orphans and exits, `--snapshot <file.png>` draws the panel into a PNG;
    /// anything else starts the menu bar app.
    @MainActor
    static func main() {
        let arguments = CommandLine.arguments

        if arguments.contains("--list") {
            CommandLine.printList()
        } else if let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count {
            CommandLine.snapshot(to: arguments[index + 1])
        } else {
            OrphanBarApp.main()
        }
    }
}

struct OrphanBarApp: App {
    @State private var monitor = OrphanMonitor()

    var body: some Scene {
        MenuBarExtra {
            PanelView(monitor: monitor)
        } label: {
            MenuBarLabel(monitor: monitor)
        }
        .menuBarExtraStyle(.window)
    }
}

extension CommandLine {
    @MainActor
    static func printList() {
        let monitor = sampledMonitor()
        let rows = monitor.processes.map { process in
            [
                String(process.pid), Format.cpu(process.cpuPercent), Format.memory(process.memoryBytes),
                Format.uptime(since: process.startedAt), process.title, process.fullCommand,
            ]
        }
        let header = ["PID", "CPU", "MEMORY", "UPTIME", "TITLE", "COMMAND"]
        let widths = (0..<5).map { column in ([header] + rows).map { $0[column].count }.max() ?? 0 }

        for row in [header] + rows {
            let padded = (0..<5).map { row[$0].padding(toLength: widths[$0], withPad: " ", startingAt: 0) }
            print((padded + [row[5]]).joined(separator: "  "))
        }

        if rows.isEmpty { print("No orphaned processes.") }
    }

    @MainActor
    static func snapshot(to path: String) {
        // An NSHostingView in a window, not ImageRenderer: ImageRenderer draws AppKit-backed controls
        // (the header buttons and menu) as placeholders.
        let view = NSHostingView(rootView: PanelView(monitor: sampledMonitor(), scrolls: false).background(.background))
        view.frame.size = view.fittingSize
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()

        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            print("Could not render the panel.")
            return
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)

        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            print("Could not render the panel.")
            return
        }

        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("Wrote \(path)")
        } catch {
            print("Could not write \(path): \(error.localizedDescription)")
        }
    }

    /// Two scans a second apart, so CPU is a rate over that second rather than a lifetime average.
    @MainActor
    private static func sampledMonitor() -> OrphanMonitor {
        let monitor = OrphanMonitor(autoRefresh: false)
        monitor.refresh()
        Thread.sleep(forTimeInterval: 1)
        monitor.refresh()

        return monitor
    }
}
