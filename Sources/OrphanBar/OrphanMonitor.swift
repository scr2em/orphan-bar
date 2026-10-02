import AppKit
import Observation
import ServiceManagement

/// Where a termination the user asked for has got to.
enum Termination: Equatable {
    /// SIGTERM was sent and the process has not exited yet.
    case requested(Date)
    /// It ignored SIGTERM for longer than `stubbornAfter`; only SIGKILL will end it.
    case stubborn
    case failed(String)
}

@MainActor
@Observable
final class OrphanMonitor {
    private(set) var processes: [OrphanProcess] = []
    private(set) var terminations: [OrphanProcess.ID: Termination] = [:]
    private(set) var ignoredNames: [String]
    private(set) var launchesAtLogin: Bool
    private(set) var lastError: String?

    /// The panel refreshes quickly while it is open, and the menu bar count slowly otherwise.
    var isPanelOpen = false {
        didSet { if isPanelOpen != oldValue { startRefreshing() } }
    }

    var totalCPU: Double { processes.reduce(0) { $0 + $1.cpuPercent } }
    var totalMemory: UInt64 { processes.reduce(0) { $0 + $1.memoryBytes } }
    /// Something is burning a real share of a core.
    var isHot: Bool { processes.contains { $0.cpuPercent >= 50 } }

    private let scanner = ProcessScanner()
    private var refreshing: Task<Void, Never>?
    private static let ignoredKey = "ignoredNames"
    private static let defaultIgnored = ["ssh-agent", "gpg-agent", "keyboxd", "dirmngr"]
    private static let stubbornAfter: TimeInterval = 2

    init(autoRefresh: Bool = true) {
        ignoredNames = UserDefaults.standard.stringArray(forKey: Self.ignoredKey) ?? Self.defaultIgnored
        launchesAtLogin = SMAppService.mainApp.status == .enabled

        if autoRefresh { startRefreshing() }
    }

    func refresh() {
        processes = scanner.scan(ignoring: Set(ignoredNames))

        let alive = Set(processes.map(\.id))
        let now = Date()

        terminations = terminations.reduce(into: [:]) { kept, entry in
            guard alive.contains(entry.key) else { return }

            if case .requested(let at) = entry.value, now.timeIntervalSince(at) > Self.stubbornAfter {
                kept[entry.key] = .stubborn
            } else {
                kept[entry.key] = entry.value
            }
        }
    }

    /// SIGTERM, or SIGKILL when `force` is set; the list refreshes shortly after either way.
    func terminate(_ process: OrphanProcess, force: Bool = false) {
        if let failure = ProcessScanner.send(force ? SIGKILL : SIGTERM, to: process) {
            terminations[process.id] = .failed(failure)
        } else {
            terminations[process.id] = .requested(Date())
        }

        Task {
            try? await Task.sleep(for: .milliseconds(400))
            refresh()
        }
    }

    func terminateAll() {
        for process in processes { terminate(process) }
    }

    func ignore(_ name: String) {
        guard !ignoredNames.contains(name) else { return }
        ignoredNames.append(name)
        saveIgnored()
        refresh()
    }

    func unignore(_ name: String) {
        ignoredNames.removeAll { $0 == name }
        saveIgnored()
        refresh()
    }

    func setLaunchesAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }

            lastError = nil
        } catch {
            lastError = "Launch at login: \(error.localizedDescription)"
        }

        launchesAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func saveIgnored() {
        UserDefaults.standard.set(ignoredNames, forKey: Self.ignoredKey)
    }

    private func startRefreshing() {
        refreshing?.cancel()
        refreshing = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.refresh()
                try? await Task.sleep(for: self.isPanelOpen ? .seconds(2) : .seconds(10))
            }
        }
    }
}
