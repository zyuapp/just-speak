import XCTest

final class VocabularyListTests: XCTestCase {
    func testParsesTermsSpellingsAndComments() {
        let entries = VocabularyList.parse(
            """
            # comment
            NVIDIA: in video, en vidia

              PyTorch
            :orphan spelling
            """
        )

        XCTAssertEqual(
            entries,
            [
                VocabularyEntry(term: "NVIDIA", soundsLike: ["in video", "en vidia"]),
                VocabularyEntry(term: "PyTorch", soundsLike: []),
            ]
        )
    }

    func testRepeatedTermsMergeSpellingsIgnoringCase() {
        let entries = VocabularyList.parse(
            """
            NVIDIA: in video
            nvidia: In Video, envidia, Nvidia
            """
        )

        XCTAssertEqual(entries, [VocabularyEntry(term: "NVIDIA", soundsLike: ["in video", "envidia"])])
    }

    func testRestoresPunctuationOnReplacedWords() {
        XCTAssertEqual(
            VocabularyList.restoringPunctuation(
                original: "We moved to Superbase, then (Hanno). Done",
                rescored: "We moved to Supabase then Hono Done"
            ),
            "We moved to Supabase, then (Hono). Done"
        )
    }

    func testRestoresPunctuationOnMultiWordSpans() {
        XCTAssertEqual(
            VocabularyList.restoringPunctuation(
                original: "Review the fluid audio. Thanks",
                rescored: "Review the FluidAudio Thanks"
            ),
            "Review the FluidAudio. Thanks"
        )
    }

    func testUnalignedRescoringIsReturnedUnchanged() {
        XCTAssertEqual(
            VocabularyList.restoringPunctuation(original: "a b c", rescored: "x y z w"),
            "x y z w"
        )
        XCTAssertEqual(VocabularyList.restoringPunctuation(original: "", rescored: "Zod"), "Zod")
    }
}
