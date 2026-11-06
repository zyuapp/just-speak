import AVFoundation
import FluidAudio
import Foundation

enum CoreMLTranscriptionEngineError: LocalizedError, Sendable {
    case modelNotDownloaded
    case modelInitializationFailed(String)
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotDownloaded:
            return "The Parakeet model is not downloaded."
        case .modelInitializationFailed(let message):
            return "Could not initialize the Parakeet model: \(message)"
        case .transcriptionFailed(let message):
            return "Transcription failed: \(message)"
        }
    }
}

nonisolated enum ModelSetupProgress: Equatable, Sendable {
    case downloading(fractionCompleted: Double)
    case preparing

    static func from(_ update: DownloadUtils.DownloadProgress) -> Self {
        switch update.phase {
        case .listing:
            return .downloading(fractionCompleted: 0)
        case .downloading(_, let totalFiles):
            guard totalFiles > 0 else { return .preparing }

            let downloadFraction = min(max(update.fractionCompleted * 2, 0), 1)
            return .downloading(fractionCompleted: downloadFraction)
        case .compiling:
            return .preparing
        }
    }
}

actor CoreMLTranscriptionEngine {
    typealias ProgressHandler = @Sendable (ModelSetupProgress) -> Void

    private static let modelVersion: AsrModelVersion = .v2
    private static let minimumInferenceSamples = 16_000

    private let audioConverter = AudioConverter(sampleRate: 16_000)
    private var manager: AsrManager?
    private var isTranscribing = false
    private var transcriptionWaiters: [CheckedContinuation<Void, Never>] = []
    private var vocabulary: [VocabularyEntry] = []
    private var vocabularyGeneration = 0
    private var boosting: VocabularyBoosting?
    private var ctcTask: Task<CtcResources, Error>?

    nonisolated var isModelDownloaded: Bool {
        let directory = AsrModels.defaultCacheDirectory(for: Self.modelVersion)
        return AsrModels.modelsExist(at: directory, version: Self.modelVersion)
    }

    func initialize() async throws {
        guard isModelDownloaded else {
            throw CoreMLTranscriptionEngineError.modelNotDownloaded
        }

        do {
            let models = try await AsrModels.loadFromCache(version: Self.modelVersion)
            try await configureManager(with: models)
        } catch let error as CoreMLTranscriptionEngineError {
            throw error
        } catch {
            throw CoreMLTranscriptionEngineError.modelInitializationFailed(
                error.localizedDescription
            )
        }
    }

    func downloadAndInitialize(progress: ProgressHandler? = nil) async throws {
        progress?(.downloading(fractionCompleted: 0))

        do {
            let models = try await AsrModels.downloadAndLoad(
                version: Self.modelVersion
            ) { update in
                progress?(ModelSetupProgress.from(update))
            }
            progress?(.preparing)
            try await configureManager(with: models)
        } catch let error as CoreMLTranscriptionEngineError {
            throw error
        } catch {
            throw CoreMLTranscriptionEngineError.modelInitializationFailed(
                error.localizedDescription
            )
        }
    }

    func transcribe(audioFile: URL) async throws -> String {
        guard let manager else {
            throw CoreMLTranscriptionEngineError.modelNotDownloaded
        }

        await waitForTranscriptionSlot()
        defer { releaseTranscriptionSlot() }

        do {
            return try await transcribe(audioFile, using: manager)
        } catch {
            throw CoreMLTranscriptionEngineError.transcriptionFailed(
                error.localizedDescription
            )
        }
    }

    private func transcribe(
        _ audioFile: URL,
        using manager: AsrManager
    ) async throws -> String {
        guard try boosting != nil || requiresMinimumPadding(audioFile) else {
            return try await manager.transcribe(audioFile, source: .microphone).text
        }

        let samples = try audioConverter.resampleAudioFile(audioFile)
        let paddingCount = max(0, Self.minimumInferenceSamples - samples.count)
        let paddedSamples = samples + Array(repeating: 0, count: paddingCount)

        guard let boosting else {
            return try await manager.transcribe(paddedSamples, source: .microphone).text
        }
        return try await boosting.transcribe(paddedSamples, using: manager)
    }

    private func requiresMinimumPadding(_ audioFile: URL) throws -> Bool {
        let file = try AVAudioFile(forReading: audioFile)
        let sampleRateRatio = 16_000 / file.processingFormat.sampleRate
        let estimatedSamples = Double(file.length) * sampleRateRatio
        return estimatedSamples < Double(Self.minimumInferenceSamples)
    }

    private func configureManager(with models: AsrModels) async throws {
        let newManager = AsrManager(config: .default)
        try await newManager.initialize(models: models)

        guard await newManager.isAvailable else {
            throw CoreMLTranscriptionEngineError.modelInitializationFailed(
                "FluidAudio did not make all CoreML models available."
            )
        }

        manager = newManager
    }

    /// Replaces the boosted vocabulary. A list without usable terms turns boosting off and releases the
    /// CTC models, so transcription without a vocabulary pays nothing. Before initialization the list is
    /// only stored. Returns how many terms are boosted, or nil when the model isn't initialized or a
    /// newer list superseded this one.
    @discardableResult
    func updateVocabulary(_ entries: [VocabularyEntry]) async throws -> Int? {
        vocabulary = entries
        vocabularyGeneration += 1
        return try await applyVocabulary()
    }

    private func applyVocabulary() async throws -> Int? {
        guard manager != nil else { return nil }

        let generation = vocabularyGeneration
        let usableEntries = vocabulary.filter { $0.term.count >= CtcResources.minimumTermLength }
        let ctc = usableEntries.isEmpty ? nil : try await loadCtcResources()
        let terms = ctc?.terms(for: usableEntries) ?? []
        var newBoosting: VocabularyBoosting?
        if let ctc, !terms.isEmpty {
            newBoosting = try await VocabularyBoosting.make(terms: terms, ctc: ctc)
        }

        guard generation == vocabularyGeneration else { return nil }
        boosting = newBoosting
        if newBoosting == nil {
            ctcTask = nil
        }
        return newBoosting == nil ? 0 : terms.count
    }

    private func loadCtcResources() async throws -> CtcResources {
        if let ctcTask {
            return try await ctcTask.value
        }

        let task = Task { try await CtcResources.load() }
        ctcTask = task
        do {
            return try await task.value
        } catch {
            if ctcTask == task {
                ctcTask = nil
            }
            throw error
        }
    }

    private func waitForTranscriptionSlot() async {
        guard isTranscribing else {
            isTranscribing = true
            return
        }

        await withCheckedContinuation { continuation in
            transcriptionWaiters.append(continuation)
        }
    }

    private func releaseTranscriptionSlot() {
        guard !transcriptionWaiters.isEmpty else {
            isTranscribing = false
            return
        }

        transcriptionWaiters.removeFirst().resume()
    }
}

/// The CTC keyword-spotting model and its tokenizer; the rescorer only matches terms that carry CTC token IDs.
nonisolated private struct CtcResources: Sendable {
    static let minimumTermLength = 3

    let models: CtcModels
    let tokenizer: CtcTokenizer

    static func load() async throws -> CtcResources {
        let models = try await CtcModels.downloadAndLoad()
        let tokenizer = try await CtcTokenizer.load(
            from: CtcModels.defaultCacheDirectory(for: models.variant)
        )
        _ = try await CtcLogProbs.compute(
            samples: [Float](repeating: 0, count: 16_000),
            models: models
        )
        return CtcResources(models: models, tokenizer: tokenizer)
    }

    func terms(for entries: [VocabularyEntry]) -> [CustomVocabularyTerm] {
        entries.compactMap { entry in
            let tokenIds = tokenizer.encode(entry.term)
            guard !tokenIds.isEmpty else { return nil }
            return CustomVocabularyTerm(
                text: entry.term,
                aliases: entry.soundsLike.isEmpty ? nil : entry.soundsLike,
                ctcTokenIds: tokenIds
            )
        }
    }
}

/// Runs the CTC model alongside Parakeet on the same samples, then rescores the transcript with the
/// vocabulary. A CTC failure keeps Parakeet's transcript.
nonisolated private struct VocabularyBoosting: Sendable {
    let models: CtcModels
    let rescorer: VocabularyRescorer
    let cbw: Float
    let minSimilarity: Float

    static func make(terms: [CustomVocabularyTerm], ctc: CtcResources) async throws -> VocabularyBoosting {
        let vocabulary = CustomVocabularyContext(
            terms: terms,
            minTermLength: CtcResources.minimumTermLength
        )
        let rescorer = try await VocabularyRescorer.create(
            spotter: CtcKeywordSpotter(models: ctc.models, blankId: ctc.models.vocabulary.count),
            vocabulary: vocabulary,
            ctcModelDirectory: CtcModels.defaultCacheDirectory(for: ctc.models.variant)
        )
        let sizeConfig = ContextBiasingConstants.rescorerConfig(forVocabSize: terms.count)
        return VocabularyBoosting(
            models: ctc.models,
            rescorer: rescorer,
            cbw: sizeConfig.cbw,
            minSimilarity: max(sizeConfig.minSimilarity, vocabulary.minSimilarity)
        )
    }

    func transcribe(_ samples: [Float], using manager: AsrManager) async throws -> String {
        async let logProbs = CtcLogProbs.compute(samples: samples, models: models)
        let result = try await manager.transcribe(samples, source: .microphone)

        guard let tokenTimings = result.tokenTimings, !tokenTimings.isEmpty,
              let ctc = try? await logProbs, !ctc.frames.isEmpty else {
            return result.text
        }

        let output = rescorer.ctcTokenRescore(
            transcript: result.text,
            tokenTimings: tokenTimings,
            logProbs: ctc.frames,
            frameDuration: ctc.frameDuration,
            cbw: cbw,
            marginSeconds: ContextBiasingConstants.defaultMarginSeconds,
            minSimilarity: minSimilarity
        )
        guard output.wasModified else { return result.text }
        return VocabularyList.restoringPunctuation(original: result.text, rescored: output.text)
    }
}
