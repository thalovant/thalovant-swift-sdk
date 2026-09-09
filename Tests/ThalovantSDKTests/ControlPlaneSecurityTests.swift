import Foundation
import XCTest
@testable import ThalovantSDK
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Explicit loopback HTTP fixture for proving redirect destinations are never contacted.
private final class ControlHTTPServer: @unchecked Sendable {
    private let lock = NSLock(), group = DispatchGroup()
    private let descriptor: Int32
    private var count = 0
    let port: UInt16
    var requestCount: Int { lock.locked { count } }
    init(status: Int, location: String? = nil) throws {
        #if canImport(Darwin)
        descriptor = socket(AF_INET, SOCK_STREAM, 0)
        #else
        descriptor = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard descriptor >= 0 else { throw ThalovantRuntimeError("Fixture socket creation failed") }
        let listener = descriptor
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 && listen(descriptor, 8) == 0 else { close(descriptor); throw ThalovantRuntimeError("Fixture bind failed") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
        }
        guard named == 0 else { close(descriptor); throw ThalovantRuntimeError("Fixture address lookup failed") }
        port = UInt16(bigEndian: address.sin_port)
        let redirect = location.map { "Location: \($0)\r\n" } ?? ""
        let reply = Array("HTTP/1.1 \(status) Fixture\r\n\(redirect)Content-Length: 0\r\nConnection: close\r\n\r\n".utf8)
        group.enter()
        DispatchQueue(label: "thalovant.test.control-http").async { [self] in
            defer { group.leave() }
            while true {
                let client = accept(descriptor, nil, nil)
                if client < 0 { return }
                lock.locked { count += 1 }
                var request = [UInt8](repeating: 0, count: 4096)
                _ = recv(client, &request, request.count, 0)
                _ = reply.withUnsafeBytes { send(client, $0.baseAddress, reply.count, 0) }
                _ = shutdown(client, Int32(SHUT_RDWR)); close(client)
            }
        }
    }
    func stop() {
        _ = shutdown(descriptor, Int32(SHUT_RDWR)); close(descriptor)
        _ = group.wait(timeout: .now() + 5)
    }
}

private final class PermissiveRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(request) }
}

final class ControlPlaneSecurityTests: XCTestCase {
    func testDeviceBrowserLauncherRejectsNonWebSchemesOptionsUserinfoAndControls() {
        var launches = 0
        for input in ["file:///tmp/program", "javascript:alert(1)", "calc.exe", "--help", "https://user:PRIVATE-CREDENTIAL@example.test", "https://@example.test", "https://example.test/\n--help"] {
            openBrowserBestEffort(input) { _ in launches += 1 }
        }
        XCTAssertEqual(launches, 0)
        openBrowserBestEffort("https://example.test/verify?code=a&next=b") { url in launches += 1; XCTAssertEqual(url.scheme, "https") }
        XCTAssertEqual(launches, 1)
    }
    func testLoginRedirectsNeverReachDestinationEvenWithPermissiveSessionDelegate() async throws {
        for status in [307, 308] {
            let destination = try ControlHTTPServer(status: 200)
            defer { destination.stop() }
            let source = try ControlHTTPServer(status: status, location: "http://127.0.0.1:\(destination.port)/capture")
            defer { source.stop() }
            let supplied = URLSession(configuration: .ephemeral, delegate: PermissiveRedirectDelegate(), delegateQueue: nil)
            defer { supplied.invalidateAndCancel() }
            let api = ThalovantControlPlane(apiURL: "http://127.0.0.1:\(source.port)", session: supplied)
            do { _ = try await api.login(email: "fixture@example.test", password: "PRIVATE-CREDENTIAL"); XCTFail("Expected redirect rejection") }
            catch let error as ThalovantApiError {
                XCTAssertEqual(error.statusCode, status)
                XCTAssertFalse(error.message.contains("PRIVATE-CREDENTIAL"))
            }
            XCTAssertEqual(source.requestCount, 1); XCTAssertEqual(destination.requestCount, 0)
        }
    }
    func testInjectedSessionHeadersAndCookiesRequireHttps() throws {
        for header in ["Authorization", "Proxy-Authorization", "Cookie"] {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpAdditionalHeaders = [header: "PRIVATE-CREDENTIAL"]
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let api = ThalovantControlPlane(apiURL: "http://api.example.test", session: session)
            XCTAssertThrowsError(try api.buildRequest("GET", "/v1/public/hubs", auth: false)) { error in
                XCTAssertFalse(error.localizedDescription.contains("PRIVATE-CREDENTIAL"))
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.domain: "api.example.test", .path: "/", .name: "session", .value: "PRIVATE-CREDENTIAL"]))
        configuration.httpCookieStorage?.setCookie(cookie)
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        XCTAssertThrowsError(try ThalovantControlPlane(apiURL: "http://api.example.test", session: session).buildRequest("GET", "/v1/public/hubs", auth: false))
    }
    func testCredentialHttpAndUserinfoAreRejectedBeforeRequestCreation() throws {
        for endpoint in ["http://api.example.test", "http://localhost.example.test", "http://127.1", "https://user:PRIVATE-CREDENTIAL@api.example.test"] {
            let api = ThalovantControlPlane(apiURL: endpoint, accessToken: "PRIVATE-CREDENTIAL")
            for auth in [true, false] {
                XCTAssertThrowsError(try api.buildRequest("POST", "/v1/auth/token", body: ["password": .string("PRIVATE-CREDENTIAL")], auth: auth)) { error in
                    XCTAssertFalse(error.localizedDescription.contains("PRIVATE-CREDENTIAL"))
                }
            }
        }
        for host in ["localhost", "127.0.0.1", "[::1]"] {
            let api = ThalovantControlPlane(apiURL: "http://\(host):1234")
            XCTAssertNoThrow(try api.buildRequest("POST", "/v1/auth/token", body: ["password": .string("fixture")], auth: false))
        }
        let anonymous = ThalovantControlPlane(apiURL: "http://api.example.test")
        XCTAssertNoThrow(try anonymous.buildRequest("GET", "/v1/public/hubs", auth: false))
    }
}
