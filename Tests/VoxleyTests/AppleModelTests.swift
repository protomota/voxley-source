import AVFoundation
import Foundation
import Speech
import Testing
@testable import Voxley

private let fixture = ProcessInfo.processInfo.environment["VOXLEY_TEST_AUDIO"]

@Test(.enabled(if: fixture != nil, "Run Scripts/test-app.sh --with-models to exercise local Apple models"))
func recorderMeterReflectsMicrophoneAmplitude() async throws {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
    let module = try await AppleModels.transcriber(locale: "en-US", live: true)
    let output = try #require(await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]))
    let (_, audio) = AsyncThrowingStream<AnalyzerInput, Error>.makeStream()
    let (readings, meter) = AsyncStream<WaveformFrame>.makeStream()
    let tap = try AudioTap(input: format, output: output, continuation: audio) { meter.yield($0) }
    let framesPerColumn = 224 // 14 ms at 16 kHz.
    let split = 4 * framesPerColumn + framesPerColumn / 2
    for range in [0..<split, split..<(12 * framesPerColumn)] {
        let input = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(range.count)))
        input.frameLength = AVAudioFrameCount(range.count)
        let samples = try #require(input.floatChannelData?[0])
        for (index, frame) in range.enumerated() {
            samples[index] = (4..<8).contains(frame / framesPerColumn) ? (frame.isMultiple(of: 2) ? -0.125 : 0.25) : 0
        }
        let bufferStart = 100 + Double(range.lowerBound) / format.sampleRate
        let time = AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: bufferStart),
                               sampleTime: Int64(range.lowerBound), atRate: format.sampleRate)
        tap.block(input, time)
    }
    meter.finish()
    audio.finish()

    var iterator = readings.makeAsyncIterator()
    let initial = try #require(await iterator.next())
    let waveform = try #require(await iterator.next())
    #expect(initial.peaks == MicrophoneWaveform.silence)
    #expect(waveform.peaks.count > MicrophoneWaveform.columnCount)
    #expect(waveform.peaks.suffix(8).prefix(4).allSatisfy { $0 == WaveformPeak(low: -0.125, high: 0.25) })
    #expect(waveform.peaks.suffix(4).allSatisfy { $0 == WaveformPeak() })

    // A buffer can replace the history without changing where a shared peak appears on screen.
    let sameDisplayTime = 100.17
    let oldEdge = initial.rightEdge(at: sameDisplayTime)
    let newEdge = waveform.rightEdge(at: sameDisplayTime)
    #expect(abs(oldEdge - newEdge - 8) < 0.001)
    let nextDisplayFrame = waveform.rightEdge(at: sameDisplayTime + 1.0 / 60)
    #expect(abs(nextDisplayFrame - newEdge - (1.0 / 60) / 0.014) < 0.001)
}

@Test(.enabled(if: fixture != nil, "Run Scripts/test-app.sh --with-models to exercise local Apple models"))
func appleSpeechRecognizesAnActualRecording() async throws {
    let url = URL(filePath: try #require(fixture))
    let transcript = try await AppleModels.transcribeFile(url, locale: "en-US", words: [])
    #expect(transcript.localizedCaseInsensitiveContains("purple"))
    #expect(transcript.localizedCaseInsensitiveContains("elephant"))
    print("Apple Speech (file): \(transcript)")
}

@Test(.enabled(if: fixture != nil, "Run Scripts/test-app.sh --with-models to exercise local Apple models"))
func appleSpeechRecognizesProgressiveAudioThroughCaptureConverter() async throws {
    let url = URL(filePath: try #require(fixture))
    let file = try AVAudioFile(forReading: url)
    let module = try await AppleModels.transcriber(locale: "en-US", live: true)
    let format = try #require(await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]))
    let analyzer = SpeechAnalyzer(modules: [module])
    var preferences = Preferences()
    _ = try preferences.importVocabulary("purple elephant, sketch")
    try await AppleModels.configure(analyzer, words: preferences.contextWords)
    try await analyzer.prepareToAnalyze(in: format)
    let (stream, continuation) = AsyncThrowingStream<AnalyzerInput, Error>.makeStream()
    let tap = try AudioTap(input: file.processingFormat, output: format, continuation: continuation)
    let results = Task { try await AppleModels.collect(module) }
    defer { results.cancel() }
    do {
        try await analyzer.start(inputSequence: stream)
        let time = AVAudioTime(sampleTime: 0, atRate: file.processingFormat.sampleRate)
        while file.framePosition < file.length {
            let input = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 2048))
            try file.read(into: input)
            guard input.frameLength > 0 else { break }
            tap.block(input, time)
        }
        continuation.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        let transcript = try await results.value
        #expect(transcript.localizedCaseInsensitiveContains("purple"))
        #expect(transcript.localizedCaseInsensitiveContains("elephant"))
        print("Apple Speech (stream): \(transcript)")
    } catch {
        continuation.finish()
        await analyzer.cancelAndFinishNow()
        throw error
    }
}

@Test(.enabled(if: fixture != nil, "Run Scripts/test-app.sh --with-models to exercise local Apple models"))
func foundationModelRefinesOrPreservesTranscript() async {
    let input = "um please send the purple elephant sketch to Jordan"
    let result = await AppleModels.refine(input, mode: .clean, locale: "en-US")
    print("Foundation Models status: \(AppleModels.modelStatus), result: \(result.text)")
    if AppleModels.modelStatus == "Ready" {
        #expect(result.note == nil)
        #expect(result.text.localizedCaseInsensitiveContains("purple elephant"))
        #expect(result.text.localizedCaseInsensitiveContains("Jordan"))
        #expect(!result.text.localizedCaseInsensitiveContains("um please"))
    } else {
        #expect(result.text == input)
        #expect(result.note != nil)
    }
}
