import AVFoundation
import FluidAudio
import Foundation
import XCTest

final class TranscriptionPerformanceTests: XCTestCase {
    private let coldStartMaximumRealTimeFactor = 0.075
    private let steadyStateMaximumRealTimeFactor = 0.05

    func testOneMinuteSpeechTranscribesAtLeastTwentyTimesFasterThanRealTime() async throws {
        let fixture = try SpeechPerformanceFixture.make()
        defer { fixture.remove() }

        let engine = CoreMLTranscriptionEngine()
        print("Preparing the CoreML Parakeet model; download time is excluded from the benchmark.")
        try await engine.downloadAndInitialize()

        var elapsedTimes: [TimeInterval] = []

        for iteration in 1...3 {
            let measurement = try await transcribe(fixture.audioURL, using: engine)
            elapsedTimes.append(measurement.elapsed)

            XCTAssertFalse(
                measurement.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "The real-speech fixture should produce a transcript."
            )
            XCTAssertTrue(
                measurement.text.lowercased().contains(fixture.requiredEnding),
                "The transcript must include the unique phrase at the end of the fixture. "
                    + "Transcript: \(measurement.text)"
            )
            print(
                String(
                    format: "Iteration %d: %.3fs for %.1fs audio (%.1fx real-time)",
                    iteration,
                    measurement.elapsed,
                    fixture.duration,
                    fixture.duration / measurement.elapsed
                )
            )
        }

        let coldStartRealTimeFactor = elapsedTimes[0] / fixture.duration
        let slowestSteadyStateFactor =
            elapsedTimes.dropFirst().map { $0 / fixture.duration }.max() ?? .infinity

        XCTAssertLessThanOrEqual(
            coldStartRealTimeFactor,
            coldStartMaximumRealTimeFactor,
            performanceFailure(
                phase: "first inference",
                actual: coldStartRealTimeFactor,
                limit: coldStartMaximumRealTimeFactor
            )
        )
        XCTAssertLessThanOrEqual(
            slowestSteadyStateFactor,
            steadyStateMaximumRealTimeFactor,
            performanceFailure(
                phase: "steady state",
                actual: slowestSteadyStateFactor,
                limit: steadyStateMaximumRealTimeFactor
            )
        )
    }

    func testVocabularyBoostingKeepsTwentyTimesRealTime() async throws {
        let fixture = try SpeechPerformanceFixture.make()
        defer { fixture.remove() }

        let engine = CoreMLTranscriptionEngine()
        try await engine.downloadAndInitialize()
        try await engine.updateVocabulary([
            VocabularyEntry(term: "NVIDIA", soundsLike: ["in video"]),
            VocabularyEntry(term: "Kubernetes", soundsLike: []),
            VocabularyEntry(term: "PyTorch", soundsLike: []),
        ])
        _ = try await transcribe(fixture.audioURL, using: engine)

        var slowestFactor = 0.0
        for iteration in 1...2 {
            let measurement = try await transcribe(fixture.audioURL, using: engine)
            XCTAssertTrue(
                measurement.text.lowercased().contains(fixture.requiredEnding),
                "Vocabulary boosting must not alter unrelated speech. Transcript: \(measurement.text)"
            )
            slowestFactor = max(slowestFactor, measurement.elapsed / fixture.duration)
            print(
                String(
                    format: "Vocabulary iteration %d: %.3fs for %.1fs audio (%.1fx real-time)",
                    iteration,
                    measurement.elapsed,
                    fixture.duration,
                    fixture.duration / measurement.elapsed
                )
            )
        }

        XCTAssertLessThanOrEqual(
            slowestFactor,
            steadyStateMaximumRealTimeFactor,
            performanceFailure(
                phase: "vocabulary steady state",
                actual: slowestFactor,
                limit: steadyStateMaximumRealTimeFactor
            )
        )
    }

    func testVocabularyCorrectsMisheardTermsAndKeepsPunctuation() async throws {
        let fixture = try SpeechPerformanceFixture.makeVocabulary()
        defer { fixture.remove() }

        let engine = CoreMLTranscriptionEngine()
        try await engine.downloadAndInitialize()
        let plain = try await engine.transcribe(audioFile: fixture.audioURL)
        try await engine.updateVocabulary([
            VocabularyEntry(term: "Supabase", soundsLike: []),
            VocabularyEntry(term: "Hono", soundsLike: []),
        ])
        let boosted = try await engine.transcribe(audioFile: fixture.audioURL)

        XCTAssertFalse(plain.contains("Supabase"), "Fixture no longer exercises a misheard term: \(plain)")
        XCTAssertTrue(boosted.contains("Supabase,"), "Expected the corrected term with its comma: \(boosted)")
        XCTAssertTrue(boosted.contains("Hono"), "Expected the corrected term: \(boosted)")
    }

    func testCtcLogProbsMatchFluidAudioSpotter() async throws {
        let fixture = try SpeechPerformanceFixture.makeVocabulary()
        defer { fixture.remove() }

        let models = try await CtcModels.downloadAndLoad()
        let samples = try AudioConverter(sampleRate: 16_000).resampleAudioFile(fixture.audioURL)
        let reference = try await CtcKeywordSpotter(models: models, blankId: models.vocabulary.count)
            .spotKeywordsWithLogProbs(
                audioSamples: samples,
                customVocabulary: CustomVocabularyContext(terms: []),
                minScore: nil
            )
        let fast = try await CtcLogProbs.compute(samples: samples, models: models)

        XCTAssertEqual(fast.frames.count, reference.logProbs.count)
        XCTAssertEqual(fast.frameDuration, reference.frameDuration, accuracy: 1e-9)
        let largestDifference = zip(fast.frames, reference.logProbs)
            .flatMap { zip($0, $1).map { abs($0 - $1) } }
            .max() ?? .infinity
        XCTAssertLessThan(largestDifference, 1e-3)
    }

    func testCachedModelTranscribesSubsecondSpeech() async throws {
        let fixture = try SpeechPerformanceFixture.makeShort()
        defer { fixture.remove() }

        let setupEngine = CoreMLTranscriptionEngine()
        try await setupEngine.downloadAndInitialize()

        let cachedEngine = CoreMLTranscriptionEngine()
        XCTAssertTrue(cachedEngine.isModelDownloaded)
        try await cachedEngine.initialize()

        let measurement = try await transcribe(fixture.audioURL, using: cachedEngine)
        XCTAssertTrue(
            measurement.text.lowercased().contains(fixture.requiredEnding),
            "Expected cached startup and subsecond padding to preserve transcription. "
                + "Transcript: \(measurement.text)"
        )
    }

    private func transcribe(
        _ audioURL: URL,
        using engine: CoreMLTranscriptionEngine
    ) async throws -> (text: String, elapsed: TimeInterval) {
        let start = ProcessInfo.processInfo.systemUptime
        let text = try await engine.transcribe(audioFile: audioURL)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        return (text, elapsed)
    }

    private func performanceFailure(
        phase: String,
        actual: Double,
        limit: Double
    ) -> String {
        String(
            format: "%@ transcription regressed to %.1fx real-time; expected at least %.1fx.",
            phase,
            1 / actual,
            1 / limit
        )
    }
}

private struct SpeechPerformanceFixture {
    let directory: URL
    let audioURL: URL
    let duration: TimeInterval
    let requiredEnding: String

    static func make() throws -> SpeechPerformanceFixture {
        let sentence =
            "The quick brown fox jumps over the lazy dog while a careful engineer measures transcription speed."
        let requiredEnding = "orange bicycle"
        let finalSentence = "The final validation words are \(requiredEnding)."
        let script =
            Array(repeating: sentence, count: 13).joined(separator: " ")
            + " \(finalSentence)"

        return try make(
            script: script,
            speakingRate: 200,
            requiredEnding: requiredEnding,
            durationRange: 55..<80
        )
    }

    static func makeVocabulary() throws -> SpeechPerformanceFixture {
        try make(
            script: "We moved auth to Supabase, put the cluster behind Tailscale, and call the API from Hono.",
            speakingRate: 200,
            requiredEnding: "hono",
            durationRange: 3..<15
        )
    }

    static func makeShort() throws -> SpeechPerformanceFixture {
        try make(
            script: "hello world",
            speakingRate: 220,
            requiredEnding: "hello",
            durationRange: 0.5..<1
        )
    }

    private static func make(
        script: String,
        speakingRate: Int,
        requiredEnding: String,
        durationRange: Range<TimeInterval>
    ) throws -> SpeechPerformanceFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("JustSpeakPerformance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let sourceURL = directory.appendingPathComponent("speech.aiff")
        let audioURL = directory.appendingPathComponent("speech.wav")
        try run(
            executable: "/usr/bin/say",
            arguments: [
                "-v", "Samantha",
                "-r", String(speakingRate),
                "-o", sourceURL.path,
                script,
            ]
        )
        try run(
            executable: "/usr/bin/afconvert",
            arguments: [
                "-f", "WAVE",
                "-d", "LEI16@16000",
                "-c", "1",
                sourceURL.path,
                audioURL.path,
            ]
        )

        let duration = try validateAudio(at: audioURL, durationRange: durationRange)
        return SpeechPerformanceFixture(
            directory: directory,
            audioURL: audioURL,
            duration: duration,
            requiredEnding: requiredEnding
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    private static func validateAudio(
        at url: URL,
        durationRange: Range<TimeInterval>
    ) throws -> TimeInterval {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let duration = Double(file.length) / format.sampleRate

        guard format.channelCount == 1,
              abs(format.sampleRate - 16_000) < 0.5,
              durationRange.contains(duration) else {
            throw SpeechPerformanceFixtureError.invalidAudio(
                "Expected \(durationRange.lowerBound)–<\(durationRange.upperBound) "
                    + "seconds of 16 kHz mono speech; received "
                    + "\(String(format: "%.1f", duration))s at "
                    + "\(String(format: "%.0f", format.sampleRate)) Hz with "
                    + "\(format.channelCount) channels."
            )
        }

        return duration
    }

    private static func run(executable: String, arguments: [String]) throws {
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw SpeechPerformanceFixtureError.commandFailed(
                message ?? "\(executable) exited with status \(process.terminationStatus)."
            )
        }
    }
}

private enum SpeechPerformanceFixtureError: LocalizedError {
    case commandFailed(String)
    case invalidAudio(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let message), .invalidAudio(let message):
            return message
        }
    }
}
