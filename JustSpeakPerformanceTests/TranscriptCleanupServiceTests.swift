import Foundation
import XCTest

final class TranscriptCleanupServiceTests: XCTestCase {
    func testRequestUsesHaikuWithThinkingDisabled() throws {
        let request = try TranscriptCleanupService.makeRequest(
            transcript: "um hello there",
            apiKey: "test-key",
            additionalContext: ""
        )
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
        )
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "test-key")
        XCTAssertNotNil(request.value(forHTTPHeaderField: "anthropic-version"))
        XCTAssertEqual(body["model"] as? String, "claude-haiku-5-5")
        XCTAssertEqual(body["thinking"] as? [String: String], ["type": "disabled"])
        XCTAssertEqual(body["output_config"] as? [String: String], ["effort": "low"])
        XCTAssertEqual(messages.first?["content"], "<transcript>\num hello there\n</transcript>")
        XCTAssertEqual(body["system"] as? String, TranscriptCleanupService.systemPrompt)
    }

    func testSystemPromptIncludesAdditionalContext() {
        let prompt = TranscriptCleanupService.systemPrompt(
            additionalContext: "  Swift code reviews, FluidAudio  \n"
        )

        XCTAssertTrue(prompt.hasPrefix(TranscriptCleanupService.systemPrompt))
        XCTAssertTrue(
            prompt.hasSuffix("<dictation_context>\nSwift code reviews, FluidAudio\n</dictation_context>")
        )
    }

    func testSystemPromptOmitsBlankAdditionalContext() {
        XCTAssertEqual(
            TranscriptCleanupService.systemPrompt(additionalContext: " \n "),
            TranscriptCleanupService.systemPrompt
        )
    }

    func testParseResponseJoinsTextBlocksAndSkipsOthers() throws {
        let data = Data("""
            {"content": [
                {"type": "thinking", "thinking": ""},
                {"type": "text", "text": " Hello, "},
                {"type": "text", "text": "there. "}
            ], "stop_reason": "end_turn"}
            """.utf8)

        XCTAssertEqual(
            try TranscriptCleanupService.parseResponse(data, statusCode: 200),
            "Hello, there."
        )
    }

    func testParseResponseRejectsIncompleteOutput() {
        let data = Data("""
            {"content": [{"type": "text", "text": "Hello"}], "stop_reason": "max_tokens"}
            """.utf8)

        XCTAssertThrowsError(try TranscriptCleanupService.parseResponse(data, statusCode: 200))
    }

    func testParseResponseRejectsEmptyText() {
        let data = Data("""
            {"content": [{"type": "text", "text": "  "}], "stop_reason": "end_turn"}
            """.utf8)

        XCTAssertThrowsError(try TranscriptCleanupService.parseResponse(data, statusCode: 200))
    }

    func testParseResponseSurfacesAPIErrorMessage() {
        let data = Data("""
            {"type": "error", "error": {"type": "authentication_error", "message": "invalid x-api-key"}}
            """.utf8)

        XCTAssertThrowsError(try TranscriptCleanupService.parseResponse(data, statusCode: 401)) { error in
            XCTAssertEqual(error.localizedDescription, "invalid x-api-key")
        }
    }
}
