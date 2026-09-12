import Foundation
import XCTest
@testable import ThalovantSDK

final class HubSkillsTests: XCTestCase {
    private var api: ThalovantControlPlane!
    private let accepted = #"{"operation_id":"op-1","state":"installing","skill":"s/1"}"#
    override func setUp() {
        super.setUp(); StubURLProtocol.reset()
        api = ThalovantControlPlane(apiURL: "https://api.example.com", accessToken: "token", session: StubURLProtocol.makeSession())
    }
    func testRoutesAndHistoryPreserveSharedRuntimeAndResumeWithoutReplay() async throws {
        StubURLProtocol.enqueue(.init(body: #"{"data":[]}"#))
        StubURLProtocol.enqueue(.init(body: #"{"data":[{"kind":"event","actor_email":null}]}"#))
        StubURLProtocol.enqueue(.init(status: 202, body: accepted)); StubURLProtocol.enqueue(.init(body: #"{"status":"ready"}"#))
        StubURLProtocol.enqueue(.init(status: 202, body: accepted)); StubURLProtocol.enqueue(.init(status: 202, body: accepted))
        _ = try await api.listHubSkills("h/1")
        let history = try await api.listHubSkillHistory("h/1", limit: 200)
        XCTAssertNotNil(history["data"])
        let result = try await api.installHubSkill("h/1", skill: "s/1", version: "1.2.0")
        let done = try await api.waitForHubSkillOperation(result)
        XCTAssertEqual(done["state"]?.stringValue, "installed"); XCTAssertEqual(result["state"]?.stringValue, "installing")
        _ = try await api.updateHubSkill("h/1", skill: "s/1", version: "1.2.0"); _ = try await api.removeHubSkill("h/1", skill: "s/1")
        let requests = StubURLProtocol.requests
        XCTAssertEqual(requests.map { $0.method }, ["GET", "GET", "POST", "GET", "PATCH", "DELETE"])
        XCTAssertTrue(requests[0].url.absoluteString.hasSuffix("/v1/hubs/h%2F1/skills"))
        XCTAssertEqual(requests[1].url.query, "limit=200")
        XCTAssertTrue(requests[4].url.absoluteString.hasSuffix("/v1/hubs/h%2F1/skills/s%2F1"))
        XCTAssertEqual(try requests[2].bodyObject()?["version"]?.stringValue, "1.2.0")
    }
    func testPollingFailuresRetainIdWithoutReplaying() async throws {
        for status in ["failed", "timed_out", "applied", "http-error"] {
            StubURLProtocol.reset()
            StubURLProtocol.enqueue(.init(status: 202, body: accepted))
            StubURLProtocol.enqueue(.init(status: status == "http-error" ? 503 : 200, body: status == "http-error" ? #"{"detail":"private-data"}"# : "{\"status\":\"\(status)\"}"))
            do { _ = try await api.installHubSkill("h", skill: "s", options: HubSkillWaitOptions(wait: true, timeout: 0.05)); XCTFail("expected failure") }
            catch { XCTAssertTrue(String(describing: error).contains("op-1")); XCTAssertFalse(String(describing: error).contains("private-data")) }
            XCTAssertEqual(StubURLProtocol.requests.count, 2)
        }
    }
    func testInvalidLimitsAndDurationsDoNotSend() async {
        for limit in [0, 201] {
            do { _ = try await api.listHubSkillHistory("h", limit: limit); XCTFail("expected rejection") } catch {}
        }
        for timeout in [0.0, -1.0, Double.nan, Double.infinity] {
            do { _ = try await api.installHubSkill("h", skill: "s", options: HubSkillWaitOptions(timeout: timeout)); XCTFail("expected rejection") } catch {}
        }
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }
}
