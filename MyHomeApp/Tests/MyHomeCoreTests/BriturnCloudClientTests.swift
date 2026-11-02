import Foundation
import XCTest
@testable import MyHomeCore

final class MemorySessions: BriturnSessionStorage {
    var session: BriturnCloudSession?
    var failSave = false
    func load() throws -> BriturnCloudSession? { session }
    func save(_ session: BriturnCloudSession) throws {
        if failSave { throw BriturnCloudError.storage }
        self.session = session
    }
    func delete() throws { session = nil }
}

actor MockTransport: BriturnHTTPTransport {
    var requests: [URLRequest] = []
    var replies: [(Int, [String: Any])]
    init(_ replies: [(Int, [String: Any])]) { self.replies = replies }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !replies.isEmpty else { throw BriturnCloudError.invalidResponse }
        let (status, body) = replies.removeFirst()
        return (try JSONSerialization.data(withJSONObject: body),
                HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
    func captured() -> [URLRequest] { requests }
}

final class BriturnCloudClientTests: XCTestCase {
    private let config: (Int, [String: Any]) = (200, ["code": 0, "data": ["time": 1_700_000_000]])
    private var success: (Int, [String: Any]) {
        (200, ["code": 0, "token": "TEST_SESSION_ONLY", "data": ["webApi": "https://app-eu.briturn.net"]])
    }

    func testKnownPasswordHashAndSignatureOrder() {
        XCTAssertEqual(BriturnCloudClient.md5("abc").uppercased(), "900150983CD24FB0D6963F7D28E17F72")
        let order = ["appBVer", "appKey", "appVer", "lang", "os", "osSystem", "platform", "sdkVersion", "time", "timeZoneId", "v"]
        let params = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, String($0.offset)) })
        XCTAssertEqual(BriturnCloudClient.signature(parameters: params, appSecure: "TEST_ONLY"),
                       "8ea5771e988fc354891b15829897082d")
    }

    func testSignInSendsVerifiedBodyAndPersistsOnlySession() async throws {
        let transport = MockTransport([config, success])
        let storage = MemorySessions()
        let client = BriturnCloudClient(transport: transport, storage: storage,
                                       now: { Date(timeIntervalSince1970: 1_700_000_005) })
        let account = try await client.signIn(email: "  owner@example.invalid  ", password: "abc", region: .us)
        XCTAssertEqual(account.maskedEmail, "o…@example.invalid")
        XCTAssertEqual(account.region, .eu)
        XCTAssertEqual(storage.session?.token, "TEST_SESSION_ONLY")
        let requests = await transport.captured()
        XCTAssertEqual(requests.map { $0.url!.path }, ["/app/sys/config", "/app/user/login"])
        XCTAssertTrue(requests.allSatisfy { $0.url?.host == "app-us.briturn.net" && $0.httpMethod == "POST" })
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: requests[1].httpBody!) as? [String: String])
        XCTAssertEqual(body, ["codeType": "EMAIL", "username": "owner@example.invalid",
                              "password": "900150983CD24FB0D6963F7D28E17F72"])
        let query = URLComponents(url: requests[1].url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(query.first { $0.name == "time" }?.value, "1700000000")
        XCTAssertEqual(query.first { $0.name == "sdkVersion" }?.value, "1.0")
        XCTAssertFalse(requests[1].url!.absoluteString.contains("owner"))
        let saved = try JSONSerialization.jsonObject(with: JSONEncoder().encode(storage.session!)) as! [String: Any]
        XCTAssertNil(saved["password"])
        XCTAssertFalse(String(data: try JSONEncoder().encode(storage.session!), encoding: .utf8)!.contains("owner@example.invalid"))
        let restored = try await client.savedAccount()
        XCTAssertEqual(restored, account)
        try await client.signOut()
        let removed = try await client.savedAccount()
        XCTAssertNil(removed)
    }

    func testApplicationFailureDoesNotSaveOrExposeServerMessage() async throws {
        let transport = MockTransport([config, (200, ["code": 123, "msg": "DO_NOT_EXPOSE_TEST_SECRET", "token": "TEST_TOKEN"])])
        let storage = MemorySessions()
        let client = BriturnCloudClient(transport: transport, storage: storage)
        do {
            _ = try await client.signIn(email: "a@example.invalid", password: "test", region: .us)
            XCTFail("Expected rejection")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains("DO_NOT_EXPOSE"))
        }
        XCTAssertNil(storage.session)
    }

    func testUntrustedHostIsRejectedBeforeSavingToken() async throws {
        let transport = MockTransport([config, (200, ["code": 0, "token": "TEST_ONLY", "data": ["webApi": "https://attacker.invalid"]])])
        let storage = MemorySessions()
        let client = BriturnCloudClient(transport: transport, storage: storage)
        do {
            _ = try await client.signIn(email: "a@example.invalid", password: "test", region: .us)
            XCTFail("Expected host rejection")
        } catch BriturnCloudError.unsafeServer { }
        XCTAssertNil(storage.session)
        XCTAssertFalse(BriturnCloudClient.isAllowedServer(URL(string: "http://app-us.briturn.net")!))
        XCTAssertFalse(BriturnCloudClient.isAllowedServer(URL(string: "https://app-us.briturn.net@attacker.invalid")!))
        XCTAssertFalse(BriturnCloudClient.isAllowedServer(URL(string: "https://app-us.briturn.net/?token=test")!))
    }

    func testMissingTokenAndHTTPUnauthorizedAreNotSuccess() async throws {
        for reply: (Int, [String: Any]) in [(200, ["code": 0, "data": [:]]), (401, [:])] {
            let storage = MemorySessions()
            let client = BriturnCloudClient(transport: MockTransport([config, reply]), storage: storage)
            do {
                _ = try await client.signIn(email: "a@example.invalid", password: "test", region: .us)
                XCTFail("Expected failure")
            } catch { XCTAssertTrue(error is BriturnCloudError) }
            XCTAssertNil(storage.session)
        }
    }

    func testInvalidInputMakesNoNetworkRequests() async throws {
        for email in ["@", "user@", "@example.invalid", "two@@example.invalid", "a b@example.invalid"] {
            let transport = MockTransport([])
            let client = BriturnCloudClient(transport: transport, storage: MemorySessions())
            do {
                _ = try await client.signIn(email: email, password: "test", region: .us)
                XCTFail("Expected validation failure")
            } catch BriturnCloudError.invalidInput { }
            let requests = await transport.captured()
            XCTAssertTrue(requests.isEmpty)
        }
    }

    func testKeychainSaveFailureIsNotReportedAsSignedIn() async throws {
        let storage = MemorySessions()
        storage.failSave = true
        let client = BriturnCloudClient(transport: MockTransport([config, success]), storage: storage)
        do {
            _ = try await client.signIn(email: "a@example.invalid", password: "test", region: .eu)
            XCTFail("Expected storage failure")
        } catch BriturnCloudError.storage { }
        XCTAssertNil(storage.session)
    }
}
