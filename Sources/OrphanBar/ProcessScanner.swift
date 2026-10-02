import AppKit
import Darwin

/// A process left running after the process that started it exited.
struct OrphanProcess: Identifiable, Hashable, Sendable {
    let pid: pid_t
    /// Seconds since 1970 when it started: with the pid, what tells it apart from a later
    /// process that reuses the number.
    let startedSeconds: UInt64
    /// The executable's file name, e.g. `Python`.
    let name: String
    /// What it is running, e.g. `python http.server` or `java GradleDaemon`.
    let title: String
    /// The command line with the program as its file name, for the row.
    let command: String
    /// The whole command line, the home folder written as `~`, for the tooltip and copying.
    let fullCommand: String
    let executablePath: String
    let workingDirectory: String?
    /// Over the last refresh, or over its lifetime on the first one; 100 is one full core.
    let cpuPercent: Double
    /// The memory footprint Activity Monitor shows as "Memory".
    let memoryBytes: UInt64

    var id: String { "\(pid)-\(startedSeconds)" }
    var startedAt: Date { Date(timeIntervalSince1970: TimeInterval(startedSeconds)) }
}

/// Finds the orphans among the current user's processes.
///
/// Every process whose parent exited is re-parented to launchd, but so is every app, agent and
/// XPC service launchd starts on purpose. An orphan here is a process with launchd as its parent
/// that launchd does not manage: not a launchd job, not an app or an app extension or XPC
/// service, not part of the OS, and not a helper of an app that is still running. A helper
/// whose app has quit is an orphan.
@MainActor
final class ProcessScanner {
    private struct Sample {
        let cpuNanos: UInt64
        let takenAt: UInt64
    }

    private struct Key: Hashable {
        let pid: pid_t
        let started: UInt64
    }

    private var samples: [Key: Sample] = [:]
    private let timebase: (numer: UInt64, denom: UInt64)
    private let uid = getuid()
    private let home = NSHomeDirectory()

    /// OS components, and the simulator's and file systems' own helpers.
    private static let systemPrefixes = [
        "/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/",
        "/Library/Developer/PrivateFrameworks/", "/Library/Developer/CoreSimulator/",
        "/Library/Filesystems/", "/Library/PrivilegedHelperTools/",
    ]

    init() {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        timebase = (UInt64(info.numer), UInt64(max(info.denom, 1)))
    }

    func scan(ignoring ignored: Set<String>) -> [OrphanProcess] {
        let jobs = Self.launchdJobPIDs()
        let apps = NSWorkspace.shared.runningApplications
        let appPIDs = Set(apps.map(\.processIdentifier))
        let appBundles = Set(apps.compactMap { $0.bundleURL?.standardizedFileURL.path })
        let now = DispatchTime.now().uptimeNanoseconds
        let wallClock = Date().timeIntervalSince1970
        var nextSamples: [Key: Sample] = [:]
        var found: [OrphanProcess] = []

        for pid in Self.allPIDs() where pid != getpid() {
            guard let info = Self.bsdInfo(pid), info.pbi_ppid == 1, info.pbi_uid == uid else { continue }
            guard !jobs.contains(pid), !appPIDs.contains(pid) else { continue }
            guard let path = Self.executablePath(pid), !Self.isSystemOrService(path) else { continue }

            if let app = Self.enclosingApp(of: path), appBundles.contains(app) { continue }

            let name = (path as NSString).lastPathComponent
            guard !ignored.contains(name) else { continue }

            let usage = Self.usage(pid)
            let cpuNanos = usage.map { nanos($0.ri_user_time &+ $0.ri_system_time) } ?? 0
            let key = Key(pid: pid, started: info.pbi_start_tvsec)
            let percent: Double

            if let last = samples[key], now > last.takenAt {
                percent = Double(cpuNanos &- min(cpuNanos, last.cpuNanos)) / Double(now - last.takenAt) * 100
            } else {
                let lifetime = max(wallClock - Double(info.pbi_start_tvsec), 1)
                percent = Double(cpuNanos) / 1e9 / lifetime * 100
            }

            nextSamples[key] = Sample(cpuNanos: cpuNanos, takenAt: now)

            let arguments = Self.arguments(pid)

            found.append(
                OrphanProcess(
                    pid: pid,
                    startedSeconds: info.pbi_start_tvsec,
                    name: name,
                    title: Self.title(name: name, arguments: arguments),
                    command: abbreviate(([name] + arguments.dropFirst()).joined(separator: " ")),
                    fullCommand: abbreviate(arguments.isEmpty ? path : arguments.joined(separator: " ")),
                    executablePath: path,
                    workingDirectory: Self.workingDirectory(pid).map(abbreviate),
                    cpuPercent: percent,
                    memoryBytes: usage?.ri_phys_footprint ?? 0
                )
            )
        }

        samples = nextSamples

        return found.sorted {
            ($0.cpuPercent, $0.memoryBytes) > ($1.cpuPercent, $1.memoryBytes)
        }
    }

    /// Sends `signal` unless the pid now belongs to a different process; nil when it was sent
    /// or the process is already gone, the reason otherwise.
    static func send(_ signal: Int32, to process: OrphanProcess) -> String? {
        guard let info = bsdInfo(process.pid), info.pbi_start_tvsec == process.startedSeconds else { return nil }
        guard kill(process.pid, signal) != 0 else { return nil }

        return String(cString: strerror(errno))
    }

    // MARK: - Reading a process

    /// Task times are in mach ticks on Apple silicon, and in nanoseconds on Intel, where the
    /// timebase is 1/1.
    private func nanos(_ ticks: UInt64) -> UInt64 {
        ticks / timebase.denom * timebase.numer + ticks % timebase.denom * timebase.numer / timebase.denom
    }

    private func abbreviate(_ text: String) -> String {
        text.replacingOccurrences(of: home, with: "~")
    }

    private static func allPIDs() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 256)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }

        return count > 0 ? Array(pids.prefix(Int(count))) : []
    }

    private static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)

        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    private static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = buffer.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }

        return length > 0 ? String(decoding: buffer.prefix(Int(length)), as: UTF8.self) : nil
    }

    private static func workingDirectory(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }

        return withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
            let bytes = raw.prefix { $0 != 0 }

            return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
        }
    }

    private static func usage(_ pid: pid_t) -> rusage_info_v4? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }

        return result == 0 ? info : nil
    }

    /// The command line, from `KERN_PROCARGS2`: argc, the executable path and its padding,
    /// then argc null-terminated arguments.
    private static func arguments(_ pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var argmax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctl(&mib, 2, &argmax, &size, nil, 0) == 0, argmax > 0 else { return [] }

        var buffer = [UInt8](repeating: 0, count: Int(argmax))
        mib = [CTL_KERN, KERN_PROCARGS2, pid]
        size = buffer.count
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }

        let argc = Int(buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        var index = MemoryLayout<Int32>.size

        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }

        var arguments: [String] = []

        while arguments.count < argc, index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }

        return arguments
    }

    /// The pids launchd runs as jobs in this user's domain: agents, brew services, apps.
    private static func launchdJobPIDs() -> Set<pid_t> {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["list"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do { try task.run() } catch { return [] }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        return Set(
            String(decoding: data, as: UTF8.self)
                .split(separator: "\n")
                .dropFirst()
                .compactMap { line in line.split(separator: "\t", maxSplits: 1).first.flatMap { pid_t($0) } }
        )
    }

    private static func isSystemOrService(_ path: String) -> Bool {
        systemPrefixes.contains { path.hasPrefix($0) } || path.contains(".xpc/") || path.contains(".appex/")
    }

    /// The outermost app bundle an executable lives in: `/Applications/Brave Browser.app` for
    /// every one of Brave's helpers.
    private static func enclosingApp(of path: String) -> String? {
        guard let range = path.range(of: ".app/") else { return nil }

        return String(path[..<range.lowerBound]) + ".app"
    }

    /// What an interpreter is running reads better than the interpreter: `python http.server`,
    /// `node daemon.js`, `java GradleDaemon`.
    static func title(name: String, arguments: [String]) -> String {
        let lowered = name.lowercased()
        let interpreters = ["python", "node", "ruby", "perl", "java", "bun", "deno", "php"]
        guard let interpreter = interpreters.first(where: { lowered.hasPrefix($0) }) else { return name }

        let takesValue: Set<String> = ["-cp", "-classpath", "--class-path", "-r", "--require", "-X", "-W"]
        var remaining = arguments.dropFirst().makeIterator()

        while let argument = remaining.next() {
            if argument == "-m", let module = remaining.next() { return "\(interpreter) \(module)" }

            if argument == "-jar", let jar = remaining.next() {
                return "\(interpreter) \((jar as NSString).lastPathComponent)"
            }

            if takesValue.contains(argument) {
                _ = remaining.next()
                continue
            }

            if argument.hasPrefix("-") { continue }

            let script = (argument as NSString).lastPathComponent
            let shown = interpreter == "java" ? (script.split(separator: ".").last.map(String.init) ?? script) : script

            return "\(interpreter) \(shown)"
        }

        return name
    }
}
