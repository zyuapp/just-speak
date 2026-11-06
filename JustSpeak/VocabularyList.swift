import Foundation

nonisolated struct VocabularyEntry: Equatable, Sendable {
    var term: String
    var soundsLike: [String]
}

/// Plain-text vocabulary: one `Term` or `Term: sounds like, sounds like` per line; `#` starts a comment.
/// Terms are unique ignoring case; repeated terms merge their spellings.
nonisolated enum VocabularyList {
    static func parse(_ text: String) -> [VocabularyEntry] {
        var entries: [VocabularyEntry] = []
        var indexByKey: [String: Int] = [:]

        for line in text.split(whereSeparator: \.isNewline) {
            guard let entry = parseLine(String(line)) else { continue }
            let key = entry.term.lowercased()

            if let index = indexByKey[key] {
                entries[index].soundsLike = mergedSpellings(entries[index], adding: entry.soundsLike)
            } else {
                indexByKey[key] = entries.count
                entries.append(
                    VocabularyEntry(term: entry.term, soundsLike: mergedSpellings(entry, adding: []))
                )
            }
        }

        return entries
    }

    /// Re-attaches punctuation that vocabulary rescoring strips from replaced words. `rescored` must be
    /// `original` with some word spans each replaced by one word; otherwise `rescored` is returned as is.
    static func restoringPunctuation(original: String, rescored: String) -> String {
        let originalWords = original.split(separator: " ").map(String.init)
        let rescoredWords = rescored.split(separator: " ").map(String.init)
        var restored: [String] = []
        var index = 0

        for (position, word) in rescoredWords.enumerated() {
            guard index < originalWords.count else { return rescored }
            if originalWords[index] == word {
                restored.append(word)
                index += 1
                continue
            }

            let next = rescoredWords.indices.contains(position + 1) ? rescoredWords[position + 1] : nil
            var end = index + 1
            while end < originalWords.count, originalWords[end] != next { end += 1 }

            let leading = originalWords[index].prefix { $0.isPunctuation }
            let trailing = String(originalWords[end - 1].reversed().prefix { $0.isPunctuation }.reversed())
            restored.append(leading + word + (word.hasSuffix(trailing) ? "" : trailing))
            index = end
        }

        return index == originalWords.count ? restored.joined(separator: " ") : rescored
    }

    private static func parseLine(_ line: String) -> VocabularyEntry? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }

        let parts = trimmed.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let term = parts[0].trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return nil }

        let soundsLike = parts.count > 1
            ? parts[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            : []
        return VocabularyEntry(term: term, soundsLike: soundsLike.filter { !$0.isEmpty })
    }

    private static func mergedSpellings(_ entry: VocabularyEntry, adding spellings: [String]) -> [String] {
        var seen: Set<String> = [entry.term.lowercased()]
        return (entry.soundsLike + spellings).filter { seen.insert($0.lowercased()).inserted }
    }
}
