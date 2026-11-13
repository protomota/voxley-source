import AVFoundation
import SwiftUI

struct WaveformPeak: Equatable, Sendable {
    var low: Float = 0
    var high: Float = 0
}

struct WaveformFrame: Sendable {
    let peaks: [WaveformPeak]
    let newestTime: TimeInterval?
    let columnDuration: TimeInterval

    static let silence = WaveformFrame(peaks: MicrophoneWaveform.silence, newestTime: nil, columnDuration: 0.014)

    static var hostTime: TimeInterval { AVAudioTime.seconds(forHostTime: mach_absolute_time()) }

    func rightEdge(at hostTime: TimeInterval) -> Double {
        let lastIndex = Double(peaks.count - 1)
        guard let newestTime else { return lastIndex }
        // Leave time for the next audio buffer to arrive before its peaks reach the visible edge.
        let displayTime = hostTime - 0.125
        let position = lastIndex + (displayTime - newestTime) / columnDuration
        return min(lastIndex, max(Double(MicrophoneWaveform.columnCount - 1), position))
    }
}

struct MicrophoneWaveform {
    static let columnCount = 96
    private static let historyCount = columnCount + 20
    static let silence = Array(repeating: WaveformPeak(), count: historyCount)
    private let framesPerColumn: Int
    private let columnDuration: TimeInterval
    private var columns = Self.silence
    private var nextColumn = 0
    private var currentPeak = WaveformPeak()
    private var framesInColumn = 0
    private var columnsSinceUpdate = 0
    private var columnsWritten = 0
    private var firstSampleTime: TimeInterval?

    init(sampleRate: Double) {
        framesPerColumn = max(1, Int((sampleRate * 0.014).rounded()))
        columnDuration = Double(framesPerColumn) / sampleRate
    }

    // Keep 1.34 seconds on screen plus enough history to scroll between audio callbacks.
    mutating func append(_ samples: UnsafePointer<Float>, count: Int, stride: Int,
                         bufferStart: TimeInterval) -> WaveformFrame? {
        let start = firstSampleTime ?? bufferStart
        firstSampleTime = start
        for frame in 0..<count {
            let sample = samples[frame * stride]
            currentPeak.low = min(currentPeak.low, sample)
            currentPeak.high = max(currentPeak.high, sample)
            framesInColumn += 1
            if framesInColumn == framesPerColumn {
                columns[nextColumn] = currentPeak
                nextColumn = (nextColumn + 1) % Self.historyCount
                framesInColumn = 0
                currentPeak = WaveformPeak()
                columnsSinceUpdate += 1
                columnsWritten += 1
            }
        }
        guard columnsSinceUpdate >= 3 else { return nil }
        columnsSinceUpdate = 0
        return WaveformFrame(peaks: Array(columns[nextColumn...] + columns[..<nextColumn]),
                             newestTime: start + (Double(columnsWritten) - 0.5) * columnDuration,
                             columnDuration: columnDuration)
    }
}

struct RecorderWave: View {
    let frame: WaveformFrame
    private static let smoothingWeights: [Float] = [1, 2, 3, 2, 1]

    var body: some View {
        let envelope = frame.peaks.indices.map { smoothedPeak(at: $0) }
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: frame.newestTime == nil)) { _ in
            trace(envelope, rightEdge: frame.rightEdge(at: WaveformFrame.hostTime))
        }
    }

    private func trace(_ envelope: [WaveformPeak], rightEdge: Double) -> some View {
        Canvas { context, size in
            let center = size.height / 2
            let spacing = size.width / CGFloat(MicrophoneWaveform.columnCount - 1)
            let maxHeight = max(0, center - 1)
            context.clip(to: Path(CGRect(origin: .zero, size: size)))
            let baseline = Path { path in
                path.move(to: CGPoint(x: 0, y: center))
                path.addLine(to: CGPoint(x: size.width, y: center))
            }
            context.stroke(baseline, with: .color(.white.opacity(0.18)), lineWidth: 0.5)

            let upper = envelope.enumerated().map { index, peak in
                CGPoint(x: size.width + (CGFloat(index) - rightEdge) * spacing,
                        y: center - Self.height(for: peak.high) * maxHeight)
            }
            let lower = envelope.enumerated().reversed().map { index, peak in
                CGPoint(x: size.width + (CGFloat(index) - rightEdge) * spacing,
                        y: center + Self.height(for: -peak.low) * maxHeight)
            }
            let trace = Path { path in
                path.move(to: upper[0])
                Self.addCurve(through: upper, to: &path)
                path.addLine(to: lower[0])
                Self.addCurve(through: lower, to: &path)
                path.closeSubpath()
            }
            context.fill(trace, with: .color(.white.opacity(0.20)))
            let edges = Path { path in
                path.move(to: upper[0])
                Self.addCurve(through: upper, to: &path)
                path.move(to: lower[0])
                Self.addCurve(through: lower, to: &path)
            }
            context.drawLayer { layer in
                layer.clip(to: trace)
                layer.stroke(edges, with: .color(.white.opacity(0.92)), lineWidth: 1.8)
            }
        }
    }

    private func smoothedPeak(at index: Int) -> WaveformPeak {
        let peaks = frame.peaks
        var weighted = WaveformPeak()
        var totalWeight: Float = 0
        let radius = Self.smoothingWeights.count / 2
        for offset in -radius...radius where peaks.indices.contains(index + offset) {
            let peak = peaks[index + offset]
            let weight = Self.smoothingWeights[offset + radius]
            weighted.low += peak.low * weight
            weighted.high += peak.high * weight
            totalWeight += weight
        }
        return WaveformPeak(low: weighted.low / totalWeight, high: weighted.high / totalWeight)
    }

    private static func addCurve(through points: [CGPoint], to path: inout Path) {
        for (point, next) in zip(points, points.dropFirst()) {
            let midpoint = CGPoint(x: (point.x + next.x) / 2, y: (point.y + next.y) / 2)
            path.addQuadCurve(to: midpoint, control: point)
        }
        if let last = points.last { path.addQuadCurve(to: last, control: last) }
    }

    private static func height(for amplitude: Float) -> CGFloat {
        let audible = min(1, max(0, amplitude - 0.0025))
        return CGFloat(1 - exp(-2.52 * pow(audible, 0.58)))
    }
}
