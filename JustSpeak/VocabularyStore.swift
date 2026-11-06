import AppKit
import CoreServices
import Foundation

/// Owns `~/Library/Application Support/JustSpeak/Vocabulary.txt`; any edit in that folder reloads it.
final class VocabularyStore {
    let fileURL: URL
    private(set) var entries: [VocabularyEntry] = []
    var onChange: (() -> Void)?

    private var directoryURL: URL { fileURL.deletingLastPathComponent() }
    private let ioQueue = DispatchQueue(label: "com.zyu.just-speak.vocabulary", qos: .utility)
    private var eventStream: FSEventStreamRef?

    init(fileURL: URL = VocabularyStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    static func defaultFileURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("JustSpeak", isDirectory: true)
            .appendingPathComponent("Vocabulary.txt")
    }

    func start() {
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        startWatching()
        reload()
    }

    func revealInFinder() {
        let url = fileURL
        ioQueue.async {
            VocabularyFile.createIfMissing(at: url)
            DispatchQueue.main.async {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }

    var agentPrompt: String {
        """
        Add terms to my Just Speak dictation vocabulary so speech recognition spells them correctly.

        File: \(fileURL.path)
        Create the file if it is missing. Just Speak reloads it automatically after every save.

        Format, one term per line:
          Term
          Term: sounds like 1, sounds like 2
        Lines starting with # are comments.

        Rules:
        - Add only proper nouns, product names, jargon, and acronyms a speech model is likely to mishear. Never add common words.
        - "Sounds like" spellings are how a speech model would wrongly write the term, e.g. "Kubernetes: cooper netties, cube or nettis".
        - Terms are unique ignoring case. Keep existing lines and add new spellings to an existing term instead of repeating it.
        - Terms shorter than 3 characters are ignored.
        - Keep the list short and curated; every term adds a chance of a wrong replacement.

        Terms to add:
        """
    }

    private func reload() {
        let url = fileURL
        ioQueue.async { [weak self] in
            guard let entries = VocabularyFile.read(at: url) else { return }
            DispatchQueue.main.async { self?.apply(entries) }
        }
    }

    private func apply(_ newEntries: [VocabularyEntry]) {
        guard newEntries != entries else { return }
        entries = newEntries
        onChange?()
    }

    private func startWatching() {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let store = Unmanaged<VocabularyStore>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { store.reload() }
        }

        guard let stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            [directoryURL.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)
        ) else { return }

        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        eventStream = stream
    }
}

nonisolated enum VocabularyFile {
    private static let template = """
        # Just Speak vocabulary: one term per line, optionally "Term: sounds like, sounds like".

        """

    /// Returns the file's entries (empty when it doesn't exist), or nil when it exists but can't be read.
    static func read(at url: URL) -> [VocabularyEntry]? {
        do {
            return VocabularyList.parse(try String(contentsOf: url, encoding: .utf8))
        } catch CocoaError.fileReadNoSuchFile {
            return []
        } catch {
            print("Could not read vocabulary: \(error)")
            return nil
        }
    }

    static func createIfMissing(at url: URL) {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? template.write(to: url, atomically: true, encoding: .utf8)
    }
}
