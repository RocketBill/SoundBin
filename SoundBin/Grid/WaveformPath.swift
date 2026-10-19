import CoreGraphics

/// Builds the bar shape used for every waveform in the app, so tiles and the transport bar match.
nonisolated enum WaveformPath {
    static let barWidth: CGFloat = 2
    static let barGap: CGFloat = 1.5

    /// Fixed-size bars, as many as fit in `rect`. Missing waveforms draw as a row of 1pt dashes,
    /// which reads as a placeholder while analysis runs.
    static func make(_ waveform: Waveform?, in rect: CGRect) -> CGPath {
        guard rect.width >= barWidth, rect.height > 0 else { return CGMutablePath() }
        let pitch = barWidth + barGap
        let count = max(1, Int((rect.width + barGap) / pitch))
        let usedWidth = CGFloat(count) * pitch - barGap
        let startX = rect.minX + (rect.width - usedWidth) / 2
        return bars(waveform, in: rect, count: count, startX: startX, pitch: pitch, barWidth: barWidth)
    }

    /// Exactly `barCount` bars stretched across `rect`, so the waveform keeps its shape at any size
    /// and simply grows or shrinks with it.
    static func make(_ waveform: Waveform?, in rect: CGRect, barCount: Int) -> CGPath {
        guard barCount > 0, rect.width > 0, rect.height > 0 else { return CGMutablePath() }
        // Keep the standard bar-to-gap proportions, with bars and gaps spanning the full width.
        let ratio = barGap / barWidth
        let width = rect.width / (CGFloat(barCount) + ratio * CGFloat(barCount - 1))
        return bars(waveform, in: rect, count: barCount, startX: rect.minX, pitch: width * (1 + ratio), barWidth: width)
    }

    /// One rounded bar per value, centred vertically in `rect`. Positions and widths are snapped to
    /// the pixel grid so bars stay crisp on Retina displays.
    private static func bars(_ waveform: Waveform?, in rect: CGRect, count: Int,
                             startX: CGFloat, pitch: CGFloat, barWidth: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let snappedWidth = max(1, snap(barWidth))
        let values = waveform?.bars(count: count) ?? []

        for index in 0..<count {
            let value = values.isEmpty ? 0 : CGFloat(values[index])
            let height = max(1, snap(value * rect.height))
            let x = snap(startX + CGFloat(index) * pitch + (barWidth - snappedWidth) / 2)
            let bar = CGRect(x: x, y: rect.midY - height / 2, width: snappedWidth, height: height)
            let radius = min(snappedWidth / 2, height / 2)
            path.addRoundedRect(in: bar, cornerWidth: radius, cornerHeight: radius)
        }
        return path
    }

    private static func snap(_ value: CGFloat) -> CGFloat {
        (value * 2).rounded() / 2
    }
}
