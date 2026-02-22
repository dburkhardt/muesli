@testable import Muesli
import XCTest

/// Tests for TranscriptRefinementService guardrail logic.
/// Guardrails reject LLM output that over-edits or strips required structure tokens
/// (speaker labels and timestamps), preventing silent quality degradation.
@MainActor
final class GuardrailTests: XCTestCase {

    private var service: TranscriptRefinementService!

    override func setUp() async throws {
        try await super.setUp()
        service = TranscriptRefinementService(llmManager: LLMManager(skipHubAccess: true))
    }

    override func tearDown() async throws {
        service = nil
        try await super.tearDown()
    }

    func testGuardrailsPassWhenEditsAreMinor() {
        let original = "Hello everyone how are you doing today"
        let candidate = "Hello everyone, how are you doing today?"
        XCTAssertTrue(service.passesGuardrails(original: original, candidate: candidate),
                      "Minor punctuation changes should pass guardrails")
    }

    func testGuardrailsRejectWhenEditRatioTooHigh() {
        let original = "Hello everyone how are you doing today I am fine thanks"
        let candidate = "Completely different text that was entirely rewritten by the model for no reason whatsoever"
        XCTAssertFalse(service.passesGuardrails(original: original, candidate: candidate),
                       "Excessive rewrites should be rejected by guardrails")
    }

    func testGuardrailsRejectWhenSpeakerLabelStripped() {
        let original = "**Me** said hello"
        let candidate = "Said hello"
        XCTAssertFalse(service.passesGuardrails(original: original, candidate: candidate),
                       "Stripping speaker labels should fail guardrails")
    }

    func testGuardrailsPassWhenSpeakerLabelPreserved() {
        let original = "**Me** said hello world"
        let candidate = "**Me** said hello, world"
        XCTAssertTrue(service.passesGuardrails(original: original, candidate: candidate),
                      "Preserving speaker labels should pass guardrails")
    }

    func testGuardrailsRejectWhenTimestampStripped() {
        let original = "**Me** _[1:23]_ said something important"
        let candidate = "**Me** said something important"
        XCTAssertFalse(service.passesGuardrails(original: original, candidate: candidate),
                       "Stripping timestamps should fail guardrails")
    }

    func testGuardrailsPassForEmptyOriginal() {
        XCTAssertTrue(service.passesGuardrails(original: "", candidate: "anything"),
                      "Empty original should always pass guardrails")
    }

    func testGuardrailsPassWhenBothSpeakersPreserved() {
        let original = "**Me** said this and that and something else entirely\n**Them** replied with a thoughtful response"
        let candidate = "**Me** said this and that and something else entirely\n**Them** replied with a very thoughtful response"
        XCTAssertTrue(service.passesGuardrails(original: original, candidate: candidate),
                      "Both speaker labels preserved with minor insertion should pass")
    }
}
