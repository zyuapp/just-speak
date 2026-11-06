import Foundation

enum TranscriptionServiceError: LocalizedError, Sendable {
    case modelNotDownloaded
    case modelSetupFailed(String)
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotDownloaded:
            return "The Parakeet model is not downloaded."
        case .modelSetupFailed(let message), .transcriptionFailed(let message):
            return message
        }
    }
}

final class TranscriptionService {
    static let shared = TranscriptionService()

    private let engine: CoreMLTranscriptionEngine
    private var ready = false

    init(engine: CoreMLTranscriptionEngine = CoreMLTranscriptionEngine()) {
        self.engine = engine
    }

    var isReady: Bool {
        ready
    }

    var isModelDownloaded: Bool {
        engine.isModelDownloaded
    }

    func initialize() async throws {
        ready = false

        do {
            try await engine.initialize()
            ready = true
        } catch {
            throw TranscriptionServiceError.modelSetupFailed(error.localizedDescription)
        }
    }

    func downloadModelIfNeeded(
        progress: @escaping @MainActor @Sendable (ModelSetupProgress) -> Void,
        completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void
    ) {
        ready = false
        let (progressStream, progressContinuation) =
            AsyncStream<ModelSetupProgress>.makeStream()
        let progressDelivery = Task {
            for await setupProgress in progressStream {
                progress(setupProgress)
            }
        }

        Task { [weak self] in
            guard let self else {
                progressContinuation.finish()
                await progressDelivery.value
                return
            }

            let result: Result<Void, Error>
            do {
                try await engine.downloadAndInitialize { setupProgress in
                    progressContinuation.yield(setupProgress)
                }
                ready = true
                result = .success(())
            } catch {
                ready = false
                result = .failure(
                    TranscriptionServiceError.modelSetupFailed(error.localizedDescription)
                )
            }

            progressContinuation.finish()
            await progressDelivery.value
            completion(result)
        }
    }

    func updateVocabulary(_ entries: [VocabularyEntry]) async throws -> Int? {
        try await engine.updateVocabulary(entries)
    }

    func transcribe(audioFile: URL) async throws -> String {
        guard ready else {
            throw TranscriptionServiceError.modelNotDownloaded
        }

        do {
            return try await engine.transcribe(audioFile: audioFile)
        } catch {
            throw TranscriptionServiceError.transcriptionFailed(error.localizedDescription)
        }
    }
}
