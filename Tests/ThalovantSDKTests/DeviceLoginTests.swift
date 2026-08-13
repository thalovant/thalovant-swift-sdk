import Foundation
import XCTest

@testable import ThalovantSDK

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Thread-safe recorder for values captured by `@Sendable` closures.
private final class DeviceFlowRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _grants: [DeviceAuthorizationGrant] = []
    private var _sleeps: [TimeInterval] = []
    private var _now: TimeInterval = 0

    var grants: [DeviceAuthorizationGrant] {
        lock.lock()
        defer { lock.unlock() }
        return _grants
    }

    var sleeps: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return _sleeps
    }

    var now: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return _now
    }

    func record(_ grant: DeviceAuthorizationGrant) {
        lock.lock()
        _grants.append(grant)
        lock.unlock()
    }

    func recordSleep(_ seconds: TimeInterval) {
        lock.lock()
        _sleeps.append(seconds)
        lock.unlock()
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        _sleeps.append(seconds)
        _now += seconds
        lock.unlock()
    }
}

final class DeviceLoginTests: XCTestCase {
    private var api: ThalovantControlPlane!

    /// `DeviceAuthorizationResource` from app/schemas/auth.py. `interval` is 0
    /// so the happy-path test never really sleeps.
    private static let deviceGrant = """
    {
      "device_code": "device-code-1",
      "user_code": "WDJB-MJHT",
      "verification_uri": "https://dash.thalovant.com/activate",
      "verification_uri_complete": "https://dash.thalovant.com/activate?user_code=WDJB-MJHT",
      "expires_in": 900,
      "interval": 0
    }
    """

    /// `DeviceTokenResource`: the durable scoped API token.
    private static let deviceToken = """
    {
      "access_token": "device-token",
      "token_type": "bearer",
      "scopes": ["hubs:read", "clients:write"],
      "expires_at": "2027-08-13T00:00:00Z",
      "token_id": "token-1"
    }
    """

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        api = ThalovantControlPlane(
            apiURL: "https://api.example.com/v1",
            session: StubURLProtocol.makeSession()
        )
    }

    func testLoginWithBrowserPollsUntilTokenAndStoresIt() async throws {
        StubURLProtocol.enqueue(.init(body: Self.deviceGrant))
        StubURLProtocol.enqueue(.init(status: 400, body: #"{"error": "authorization_pending"}"#))
        StubURLProtocol.enqueue(.init(status: 400, body: #"{"error": "authorization_pending"}"#))
        StubURLProtocol.enqueue(.init(body: Self.deviceToken))

        let recorder = DeviceFlowRecorder()
        let result = try await api.loginWithBrowser(options: DeviceLoginOptions(
            scopes: ["hubs:read"],
            clientName: "swift-tests",
            openBrowser: false,
            prompt: { recorder.record($0) }
        ))

        // The token is stored exactly like login().
        XCTAssertEqual(api.accessToken, "device-token")
        XCTAssertEqual(result.accessToken, "device-token")
        XCTAssertEqual(result.tokenType, "bearer")
        XCTAssertEqual(result.scopes, ["hubs:read", "clients:write"])
        XCTAssertEqual(result.expiresAt, "2027-08-13T00:00:00Z")
        XCTAssertEqual(result.tokenId, "token-1")
        XCTAssertEqual(result.raw["access_token"]?.stringValue, "device-token")

        // The prompt received the parsed grant.
        let grants = recorder.grants
        XCTAssertEqual(grants.count, 1)
        let grant = try XCTUnwrap(grants.first)
        XCTAssertEqual(grant.deviceCode, "device-code-1")
        XCTAssertEqual(grant.userCode, "WDJB-MJHT")
        XCTAssertEqual(grant.verificationUri, "https://dash.thalovant.com/activate")
        XCTAssertEqual(grant.verificationUriComplete, "https://dash.thalovant.com/activate?user_code=WDJB-MJHT")
        XCTAssertEqual(grant.expiresIn, 900)
        XCTAssertEqual(grant.interval, 0)

        // 1 authorize + 3 polls, all unauthenticated POSTs with snake_case bodies.
        let requests = StubURLProtocol.requests
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(requests[0].method, "POST")
        XCTAssertEqual(requests[0].url.absoluteString, "https://api.example.com/v1/auth/device/authorize")
        XCTAssertNil(requests[0].header("Authorization"))
        let authorizeBody = try XCTUnwrap(requests[0].bodyObject())
        XCTAssertEqual(authorizeBody["scopes"], .array([.string("hubs:read")]))
        XCTAssertEqual(authorizeBody["client_name"]?.stringValue, "swift-tests")
        for poll in requests.dropFirst() {
            XCTAssertEqual(poll.method, "POST")
            XCTAssertEqual(poll.url.absoluteString, "https://api.example.com/v1/auth/device/token")
            XCTAssertNil(poll.header("Authorization"))
            XCTAssertEqual(poll.bodyObject()?["device_code"]?.stringValue, "device-code-1")
        }
    }

    func testLoginWithBrowserDefaultsSendEmptyAuthorizeBody() async throws {
        StubURLProtocol.enqueue(.init(body: Self.deviceGrant))
        StubURLProtocol.enqueue(.init(body: Self.deviceToken))

        _ = try await api.loginWithBrowser(options: DeviceLoginOptions(
            openBrowser: false,
            prompt: { _ in }
        ))

        let authorize = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(authorize.bodyObject(), [:])
    }

    func testPollSlowDownGrowsInterval() async throws {
        StubURLProtocol.enqueue(.init(status: 400, body: #"{"error": "authorization_pending"}"#))
        StubURLProtocol.enqueue(.init(status: 400, body: #"{"error": "slow_down"}"#))
        StubURLProtocol.enqueue(.init(status: 400, body: #"{"error": "authorization_pending"}"#))
        StubURLProtocol.enqueue(.init(body: Self.deviceToken))

        let recorder = DeviceFlowRecorder()
        let token = try await api.pollDeviceToken(
            deviceCode: "device-code-1",
            interval: 5,
            timeout: 900,
            sleep: { recorder.recordSleep($0) },
            clock: { 0 }
        )

        XCTAssertEqual(token["access_token"]?.stringValue, "device-token")
        XCTAssertEqual(recorder.sleeps, [5, 10, 10])
    }

    func testLoginWithBrowserThrowsOnAccessDenied() async {
        StubURLProtocol.enqueue(.init(body: Self.deviceGrant))
        StubURLProtocol.enqueue(.init(status: 400, body: #"{"error": "access_denied"}"#))
        do {
            _ = try await api.loginWithBrowser(options: DeviceLoginOptions(openBrowser: false, prompt: { _ in }))
            XCTFail("expected ThalovantDeviceLoginError.denied")
        } catch let error as ThalovantDeviceLoginError {
            XCTAssertEqual(error, .denied)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertNil(api.accessToken)
    }

    func testLoginWithBrowserThrowsOnExpiredToken() async {
        StubURLProtocol.enqueue(.init(body: Self.deviceGrant))
        StubURLProtocol.enqueue(.init(status: 400, body: #"{"error": "expired_token"}"#))
        do {
            _ = try await api.loginWithBrowser(options: DeviceLoginOptions(openBrowser: false, prompt: { _ in }))
            XCTFail("expected ThalovantDeviceLoginError.expired")
        } catch let error as ThalovantDeviceLoginError {
            XCTAssertEqual(error, .expired)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertNil(api.accessToken)
    }

    func testPollTimesOut() async {
        for _ in 0..<3 {
            StubURLProtocol.enqueue(.init(status: 400, body: #"{"error": "authorization_pending"}"#))
        }
        let recorder = DeviceFlowRecorder()
        do {
            _ = try await api.pollDeviceToken(
                deviceCode: "device-code-1",
                interval: 5,
                timeout: 10,
                sleep: { recorder.advance($0) },
                clock: { recorder.now }
            )
            XCTFail("expected ThalovantTimeoutError")
        } catch is ThalovantTimeoutError {
            // The final sleep is clamped to the remaining budget, so the loop
            // wakes exactly at the deadline.
            XCTAssertEqual(recorder.sleeps, [5, 5])
            XCTAssertEqual(recorder.now, 10)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(StubURLProtocol.requests.count, 3)
    }

    func testPollSurfacesUnexpectedErrors() async {
        StubURLProtocol.enqueue(.init(status: 503, body: #"{"detail": "maintenance"}"#))
        do {
            _ = try await api.pollDeviceToken(deviceCode: "device-code-1", interval: 0, timeout: 900)
            XCTFail("expected ThalovantApiError")
        } catch let error as ThalovantApiError {
            XCTAssertEqual(error.statusCode, 503)
            XCTAssertEqual(error.body, #"{"detail": "maintenance"}"#)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testLoginWithBrowserRejectsIncompleteGrant() async {
        StubURLProtocol.enqueue(.init(body: #"{"device_code": "device-code-1"}"#))
        do {
            _ = try await api.loginWithBrowser(options: DeviceLoginOptions(openBrowser: false, prompt: { _ in }))
            XCTFail("expected ThalovantApiError")
        } catch let error as ThalovantApiError {
            XCTAssertTrue(error.message.contains("incomplete"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(StubURLProtocol.requests.count, 1, "must not poll without a complete grant")
    }
}
