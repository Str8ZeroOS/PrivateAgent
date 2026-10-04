import Testing
@testable import AgentCore

@Suite("WebDriverAgent bridge")
struct WebDriverAgentTests {
    @Test("executor sends tap actions to a developer-device client")
    func executorUsesClient() async throws {
        let client = ScriptedWDAClient(
            response: WebDriverAgentResponse(status: .completed, message: "Tapped play", wdaSessionId: "wda-1")
        )
        let executor = WebDriverAgentActionExecutor(client: client, requiresUserApproval: false)
        #expect(executor.canExecute(.tap(controlId: "play")))
        #expect(!executor.canExecute(.answer("no")))

        let result = try await executor.execute(.tap(controlId: "play"))
        #expect(result.status == .completed)
        #expect(result.message == "Tapped play")
        #expect(await client.actionCount() == 1)
    }

    @Test("observer falls back to the in-app workspace when WDA is down")
    func observerFallsBack() async throws {
        let observer = WebDriverAgentObserver(client: FailingWDAClient())
        let observation = try await observer.observe(goal: "Stay local", context: AgentObservationContext())
        #expect(observation.source == .privateAgentApp)
        #expect(!observation.controls.isEmpty)
    }
}

private actor WDAActionCounter {
    var count = 0
    func increment() { count += 1 }
    func current() -> Int { count }
}

private struct ScriptedWDAClient: WebDriverAgentClient {
    let response: WebDriverAgentResponse
    let counter = WDAActionCounter()

    func status() async throws -> WebDriverAgentStatus {
        WebDriverAgentStatus(ready: true, message: "ok", sessionId: response.wdaSessionId)
    }

    func requestObservation(_ request: WebDriverAgentObservationRequest) async throws -> WebDriverAgentResponse {
        _ = request
        return response
    }

    func executeAction(_ request: WebDriverAgentActionRequest) async throws -> WebDriverAgentResponse {
        _ = request
        await counter.increment()
        return response
    }

    func actionCount() async -> Int {
        await counter.current()
    }
}

private struct FailingWDAClient: WebDriverAgentClient {
    func status() async throws -> WebDriverAgentStatus {
        throw WebDriverAgentClientError.invalidResponse
    }

    func requestObservation(_ request: WebDriverAgentObservationRequest) async throws -> WebDriverAgentResponse {
        _ = request
        throw WebDriverAgentClientError.invalidResponse
    }

    func executeAction(_ request: WebDriverAgentActionRequest) async throws -> WebDriverAgentResponse {
        _ = request
        throw WebDriverAgentClientError.invalidResponse
    }
}
