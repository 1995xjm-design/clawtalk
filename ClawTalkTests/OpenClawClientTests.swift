import Testing
@testable import ClawTalk

@Suite("OpenClaw Client")
struct OpenClawClientTests {
        @Test("Allows plain HTTP URLs (self-hosted gateway)")
    func allowsHTTP() throws {
        // 自用场景：明文 HTTP 放行（ATS 已放开 + token 鉴权）
        let url = try #require(URL(string: "http://insecure.example.com"))
        try OpenClawClient.validateConnectionSecurity(url)
    }

    @Test("Rejects empty gateway URL")
    func rejectsEmptyURL() async {
        let client = OpenClawClient()
        let messages = [Message(role: .user, content: "test")]

        var receivedError: Error?
        do {
            for try await _ in client.streamChat(
                messages: messages,
                gatewayURL: "",
                token: "test"
            ) {}
        } catch {
            receivedError = error
        }

        #expect(receivedError != nil)
    }

        @Test("Allows plain HTTP for OpenResponses API")
    func allowsHTTPOpenResponses() throws {
        let url = try #require(URL(string: "http://insecure.example.com"))
        try OpenClawClient.validateConnectionSecurity(url)
    }

    @Test("Error descriptions are user-friendly")
    func errorDescriptions() {
        let errors: [OpenClawError] = [
            .invalidURL,
            .invalidResponse,
            .httpError(401),
            .emptyResponse,
            .insecureConnection,
            .responseError("Something went wrong")
        ]

        for error in errors {
            #expect(error.errorDescription != nil)
            #expect(!error.errorDescription!.isEmpty)
        }
    }

    @Test("responseError preserves message")
    func responseErrorMessage() {
        let error = OpenClawError.responseError("Rate limit exceeded")
        #expect(error.errorDescription == "Rate limit exceeded")
    }
}
