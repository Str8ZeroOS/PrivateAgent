import Foundation
import Testing
@testable import AgentCore

@Suite("JSON repair engine")
struct JSONRepairEngineTests {
    @Test("extracts JSON from prose and fenced blocks")
    func extractsJSON() {
        let fenced = """
        Sure.
        ```json
        {"summary":"ok","steps":[],"requiresUserApproval":false,"risk":"low"}
        ```
        """
        let extracted = JSONRepairEngine.extractJSONObject(from: fenced)
        #expect(extracted.contains("\"summary\""))
    }

    @Test("describes missing-key schema violations")
    func describesMissingKey() throws {
        struct Payload: Decodable { var summary: String }
        do {
            _ = try JSONDecoder().decode(Payload.self, from: Data("{}".utf8))
            Issue.record("Expected decode failure")
        } catch {
            let description = JSONRepairEngine.describeSchemaViolation(error)
            #expect(description.contains("summary"))
        }
    }

    @Test("repairs malformed JSON up to three times then fails")
    func repairsThenFailsSafely() async {
        let generator = ScriptedGenerator(responses: [
            "still not json",
            "nope",
            "also broken"
        ])
        let engine = JSONRepairEngine()

        do {
            _ = try await engine.decodePlan(
                from: "This is not JSON",
                generator: generator,
                maxRepairAttempts: 3
            )
            Issue.record("Expected JSON repair to fail safely")
        } catch {
            #expect(await generator.issuedCount() == 3)
        }
    }

    @Test("succeeds after bounded repair")
    func succeedsAfterRepair() async throws {
        let generator = ScriptedGenerator(responses: [
            """
            {
              "summary": "Ask for clarification.",
              "steps": [
                {
                  "id": "00000000-0000-0000-0000-000000000003",
                  "action": { "askUser": { "_0": "Which app?" } },
                  "rationale": "Need a target.",
                  "status": "pending"
                }
              ],
              "requiresUserApproval": false,
              "risk": "low"
            }
            """
        ])
        let outcome = try await JSONRepairEngine().decodePlan(
            from: "not json",
            generator: generator,
            maxRepairAttempts: 3
        )
        #expect(outcome.diagnostics.usedRepair)
        #expect(outcome.diagnostics.repairAttempts == 1)
        #expect(outcome.value.summary == "Ask for clarification.")
    }
}

private actor ScriptedStore {
    var responses: [String]
    var issued = 0

    init(responses: [String]) {
        self.responses = responses
    }

    func next() -> String {
        issued += 1
        if responses.isEmpty { return "not-json" }
        return responses.removeFirst()
    }

    func count() -> Int { issued }
}

private struct ScriptedGenerator: AgentTextGenerating {
    private let store: ScriptedStore

    init(responses: [String]) {
        self.store = ScriptedStore(responses: responses)
    }

    @MainActor
    func generateText(prompt: String) async throws -> String {
        await store.next()
    }

    func issuedCount() async -> Int {
        await store.count()
    }
}
