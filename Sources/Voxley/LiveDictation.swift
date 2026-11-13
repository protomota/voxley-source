import AVFoundation
import Speech

@MainActor
final class LiveDictation {
    private let engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncThrowingStream<AnalyzerInput, Error>.Continuation?
    private var resultTask: Task<String, Error>?
    private var analysisTask: Task<Void, Error>?
    private var started: ContinuousClock.Instant?
    private var hasTap = false

    static func requestMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }

    func start(
        module: SpeechTranscriber, words: [String],
        update: @escaping @Sendable (String) async -> Void,
        meter: @escaping @Sendable (WaveformFrame) -> Void
    ) async throws {
        let input = engine.inputNode
        let natural = input.outputFormat(forBus: 0)
        guard natural.sampleRate > 0, natural.channelCount > 0,
              let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module], considering: natural)
        else { throw VoxleyError.microphoneInput }
        try Task.checkCancellation()

        let analyzer = SpeechAnalyzer(modules: [module])
        self.analyzer = analyzer
        try await AppleModels.configure(analyzer, words: words)
        try Task.checkCancellation()

        let (stream, continuation) = AsyncThrowingStream<AnalyzerInput, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(128)
        )
        self.continuation = continuation
        resultTask = Task { try await AppleModels.collect(module, update: update) }
        let tap = try AudioTap(input: natural, output: format, continuation: continuation, meter: meter)
        input.installTap(onBus: 0, bufferSize: 2048, format: nil, block: tap.block)
        hasTap = true
        try engine.start()
        started = .now
        analysisTask = Task { try await analyzer.start(inputSequence: stream) }
    }

    func finish() async throws -> String {
        guard let analyzer, let resultTask, let analysisTask, let started,
              started.duration(to: .now) > .milliseconds(200) else {
            await cancel()
            throw VoxleyError.emptyAudio
        }
        stopCapture()
        do {
            try await analysisTask.value
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            return try await resultTask.value
        } catch {
            await cancel()
            throw error
        }
    }

    func cancel() async {
        stopCapture()
        analysisTask?.cancel()
        resultTask?.cancel()
        await analyzer?.cancelAndFinishNow()
    }

    private func stopCapture() {
        engine.stop()
        if hasTap {
            engine.inputNode.removeTap(onBus: 0)
            hasTap = false
        }
        continuation?.finish()
    }
}

// AVAudioEngine invokes one tap serially. Only that tap touches the converter.
final class AudioTap: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let output: AVAudioFormat
    private let continuation: AsyncThrowingStream<AnalyzerInput, Error>.Continuation
    private let meter: (@Sendable (WaveformFrame) -> Void)?
    private var waveform: MicrophoneWaveform

    init(input: AVAudioFormat, output: AVAudioFormat,
         continuation: AsyncThrowingStream<AnalyzerInput, Error>.Continuation,
         meter: (@Sendable (WaveformFrame) -> Void)? = nil) throws {
        guard let converter = AVAudioConverter(from: input, to: output) else {
            throw VoxleyError.microphoneInput
        }
        self.converter = converter
        self.output = output
        self.continuation = continuation
        self.meter = meter
        waveform = MicrophoneWaveform(sampleRate: input.sampleRate)
    }

    var block: AVAudioNodeTapBlock {
        { [self] input, time in convert(input, time: time) }
    }

    private func convert(_ input: AVAudioPCMBuffer, time: AVAudioTime) {
        updateMeter(input, time: time)
        let count = ceil(Double(input.frameLength) * output.sampleRate / input.format.sampleRate) + 16
        guard let buffer = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: AVAudioFrameCount(count)) else {
            continuation.finish(throwing: VoxleyError.microphoneInput)
            return
        }
        var error: NSError?
        let feed = InputBuffer(input)
        let status = converter.convert(to: buffer, error: &error) { _, flag in
            feed.provide(flag)
        }
        if let error {
            continuation.finish(throwing: error)
        } else if status == .error {
            continuation.finish(throwing: VoxleyError.microphoneInput)
        } else if buffer.frameLength > 0,
                  case .dropped = continuation.yield(AnalyzerInput(buffer: buffer)) {
            continuation.finish(throwing: VoxleyError.audioOverrun)
        }
    }

    private func updateMeter(_ input: AVAudioPCMBuffer, time: AVAudioTime) {
        guard let meter, let samples = input.floatChannelData?[0] else { return }
        let bufferStart = time.isHostTimeValid
            ? AVAudioTime.seconds(forHostTime: time.hostTime)
            : WaveformFrame.hostTime - Double(input.frameLength) / input.format.sampleRate
        if let frame = waveform.append(samples, count: Int(input.frameLength), stride: input.stride, bufferStart: bufferStart) {
            meter(frame)
        }
    }
}

// The converter requests the input synchronously on the tap's call stack.
private final class InputBuffer: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }

    func provide(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioPCMBuffer? {
        let next = buffer
        buffer = nil
        status.pointee = next == nil ? .noDataNow : .haveData
        return next
    }
}
