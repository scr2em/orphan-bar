import SwiftUI

enum Format {
    static func cpu(_ percent: Double) -> String {
        if percent < 0.05 { return "0%" }
        if percent < 10 { return String(format: "%.1f%%", percent) }

        return String(format: "%.0f%%", percent)
    }

    static func memory(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .memory)
    }

    /// `45s`, `12m`, `3h 5m`, `2d 4h`.
    static func uptime(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        let days = seconds / 86_400
        let hours = seconds % 86_400 / 3_600
        let minutes = seconds % 3_600 / 60

        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }

        return "\(seconds)s"
    }
}

/// The glyph and tint a row is drawn with, from what the process is.
struct ProcessKind {
    let symbol: String
    let tint: Color

    static func of(_ name: String) -> ProcessKind {
        let name = name.lowercased()

        if name.hasPrefix("python") { return ProcessKind(symbol: "chevron.left.forwardslash.chevron.right", tint: .blue) }
        if ["node", "bun", "deno"].contains(where: name.hasPrefix) { return ProcessKind(symbol: "hexagon.fill", tint: .green) }
        if name.hasPrefix("java") { return ProcessKind(symbol: "cup.and.saucer.fill", tint: .orange) }
        if name.hasPrefix("ruby") { return ProcessKind(symbol: "diamond.fill", tint: .red) }
        if ["adb", "emulator", "qemu"].contains(where: name.hasPrefix) { return ProcessKind(symbol: "iphone", tint: .teal) }
        if ["xcodebuild", "swift", "clang"].contains(where: name.hasPrefix) { return ProcessKind(symbol: "hammer.fill", tint: .indigo) }

        return ProcessKind(symbol: "terminal.fill", tint: .gray)
    }
}
