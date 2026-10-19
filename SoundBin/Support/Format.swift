import Foundation

nonisolated enum Format {
    /// Compact length for tiles: "0.4s", "12.3s", "3:07".
    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "–" }
        if seconds < 60 {
            return seconds.formatted(.number.precision(.fractionLength(1))) + "s"
        }
        return clock(seconds)
    }

    /// Playback position for the transport. Short sounds get tenths so the counter visibly moves.
    static func position(_ seconds: TimeInterval, total: TimeInterval) -> String {
        guard seconds.isFinite else { return "0:00" }
        let seconds = max(0, seconds)
        if total < 60 {
            let whole = Int(seconds)
            let tenths = Int((seconds - Double(whole)) * 10)
            return String(format: "0:%02d.%d", whole, tenths)
        }
        return clock(seconds)
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    static func sampleRate(_ hertz: Double) -> String {
        (hertz / 1000).formatted(.number.precision(.fractionLength(0...2))) + " kHz"
    }

    static func soundCount(_ count: Int) -> String {
        count == 1 ? "1 sound" : "\(count.formatted()) sounds"
    }
}
