import Foundation
import XCTest
@testable import ThalovantSDK
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Answers every request with one response: the status, the Content-Type and
/// the body bytes a vector names, exactly.
private final class ProblemResponder: URLProtocol {
    struct Response {
        let status: Int
        let contentType: String
        let body: Data
    }

    private static let lock = NSLock()
    private static var response = Response(status: 500, contentType: "text/plain", body: Data())

    static func serve(_ next: Response) { lock.locked { response = next } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let served = Self.lock.locked { Self.response }
        let answer = HTTPURLResponse(
            url: request.url ?? URL(string: "https://api.example.com/")!,
            statusCode: served.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": served.contentType, "Content-Length": String(served.body.count)]
        )!
        client?.urlProtocol(self, didReceive: answer, cacheStoragePolicy: .notAllowed)
        if !served.body.isEmpty {
            client?.urlProtocol(self, didLoad: served.body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// What a control-plane error carries, against the vectors every SDK shares.
///
/// `contracts/conformance/api-error-vectors.json` in the Python SDK, vendored
/// here and pinned by the parity contract. The API answers a refusal with a
/// Problem+JSON body whose structured fields say what to do next -- the images
/// a caller may pin instead, the plan's numbers -- and a message cut at 200
/// characters is not where anybody can read them. Each case is served through
/// URLSession to the public client and read back from `getHub`, so the
/// response parsing that runs is the one a caller gets.
final class ApiErrorVectorTests: XCTestCase {

    private func cases() throws -> [JSONObject] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "api-error-vectors", withExtension: "json"))
        let vectors = try JSONDecoder().decode(JSONObject.self, from: Data(contentsOf: url))
        return try XCTUnwrap(vectors["cases"]?.arrayValue).compactMap(\.objectValue)
    }

    /// Serves `response` and returns what `getHub` threw for it.
    private func refusal(_ response: JSONObject, _ name: String) async throws -> ThalovantApiError {
        ProblemResponder.serve(.init(
            status: try XCTUnwrap(response["status"]?.intValue, name),
            contentType: try XCTUnwrap(response["content_type"]?.stringValue, name),
            body: Data(try XCTUnwrap(response["body"]?.stringValue, name).utf8)
        ))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProblemResponder.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let api = ThalovantControlPlane(
            apiURL: "https://api.example.com",
            accessToken: "synthetic-token",
            session: session
        )
        do {
            _ = try await api.getHub("hub-1")
        } catch let error as ThalovantApiError {
            return error
        }
        throw ThalovantRuntimeError("\(name): getHub answered instead of failing")
    }

    /// Every form the error takes when it is shown or logged.
    private func printedForms(_ error: ThalovantApiError) -> [(String, String)] {
        let erased: any Error = error
        return [
            ("message", error.message),
            ("description", error.description),
            ("errorDescription", error.errorDescription ?? ""),
            ("localizedDescription", erased.localizedDescription),
            ("String(describing:)", String(describing: erased)),
            ("String(reflecting:)", String(reflecting: erased)),
            ("interpolation", "\(erased)"),
        ]
    }

    func testAnApiErrorCarriesWhatItsVectorNames() async throws {
        let cases = try cases()
        XCTAssertEqual(cases.count, 15)
        for row in cases {
            let name = try XCTUnwrap(row["name"]?.stringValue)
            let error = try await refusal(try XCTUnwrap(row["response"]?.objectValue, name), name)
            let produced = JSONValue.object([
                "status": error.statusCode.map { .integer($0) } ?? .null,
                "code": error.errorCode.map { .string($0) } ?? .null,
                "detail": error.detail.map { .string($0) } ?? .null,
                "problem": error.problem.map { .object($0) } ?? .null,
            ])
            // Recorded before the assert: the record is what this SDK produced,
            // not a restatement of what the vector says it should have.
            ConformanceRecord.record("api-error-vectors.json", name, produced)
            XCTAssertEqual(produced, row["expect"], name)
            for echoed in row["message_excludes"]?.arrayValue?.compactMap(\.stringValue) ?? [] {
                // The body really did echo it, so its absence below means something.
                XCTAssertTrue(error.body?.contains(echoed) == true, "\(name): the vector no longer echoes \(echoed)")
                for (form, text) in printedForms(error) {
                    XCTAssertFalse(text.contains(echoed), "\(name): \(form) repeats \(echoed)")
                }
            }
        }
    }

    func testTheMessageMayBeShortenedButTheDetailNeverIs() async throws {
        let row = try XCTUnwrap(cases().first { $0["expect"]?["code"]?.stringValue == "platform_image_required" })
        let error = try await refusal(try XCTUnwrap(row["response"]?.objectValue), "image refusal")
        // The display line is what it always was: one bounded line, with the code.
        XCTAssertTrue(error.message.hasPrefix(
            "Thalovant API request failed with HTTP 403: platform_image_required: Only an administrator"), error.message)
        XCTAssertTrue(error.message.hasSuffix("…"), error.message)
        XCTAssertEqual(error.description, error.message)
        XCTAssertEqual(error.errorDescription, error.message)
        // The sentence the API wrote is whole, and every list it sent is there.
        let detail = try XCTUnwrap(error.detail)
        XCTAssertEqual(detail, row["expect"]?["detail"]?.stringValue)
        XCTAssertGreaterThan(detail.count, 256)
        XCTAssertFalse(error.message.contains(detail))
        XCTAssertTrue(detail.hasSuffix("core may be any tag or digest of ghcr.io/thalovant/ovos-core."))
        let problem = try XCTUnwrap(error.problem)
        XCTAssertEqual(problem["allowed_images"]?["core"], .array([
            .string("ghcr.io/thalovant/ovos-core:2026.09.2"),
            .string("ghcr.io/thalovant/ovos-core:2026.09.3-alpha.1"),
        ]))
        XCTAssertEqual(problem["allowed_images"]?["bus"]?.arrayValue?.count, 3)
        XCTAssertEqual(problem["allowed_repositories"], .object(["core": .string("ghcr.io/thalovant/ovos-core")]))
        XCTAssertEqual(problem["refused_images"]?["bus"], .string("docker.io/example/ovos-messagebus:custom"))
        XCTAssertEqual(problem["status"], .integer(403))
    }

    func testAPlanLimitKeepsItsNumbersAsWholeNumbers() async throws {
        let row = try XCTUnwrap(cases().first { $0["expect"]?["code"]?.stringValue == "plan_limit" })
        let error = try await refusal(try XCTUnwrap(row["response"]?.objectValue), "plan limit")
        XCTAssertEqual(error.errorCode, "plan_limit")
        XCTAssertEqual(error.problem?["resource"], .string("client"))
        XCTAssertEqual(error.problem?["limit"], .integer(1))
        XCTAssertEqual(error.problem?["used"]?.intValue, 1)
    }

    func testAnErrorBuiltTheOldWayStillReadsTheOldWay() {
        let local = ThalovantApiError(message: "Missing Thalovant API access token.")
        XCTAssertNil(local.statusCode)
        XCTAssertNil(local.body)
        XCTAssertNil(local.errorCode)
        XCTAssertNil(local.detail)
        XCTAssertNil(local.problem)
        XCTAssertEqual(local.description, "Missing Thalovant API access token.")
        XCTAssertEqual(local.errorDescription, "Missing Thalovant API access token.")

        let conflict = ThalovantApiError(message: "conflict", statusCode: 412)
        XCTAssertEqual(conflict.statusCode, 412)
        XCTAssertNil(conflict.errorCode)
        XCTAssertNil(conflict.detail)
        XCTAssertNil(conflict.problem)

        // A body passed the old way still gives its code, and now its sentence
        // and the whole object too.
        let coded = ThalovantApiError(
            message: "HTTP 409", statusCode: 409, body: #"{"code": "conflict", "detail": "Stale revision."}"#)
        XCTAssertEqual(coded.errorCode, "conflict")
        XCTAssertEqual(coded.detail, "Stale revision.")
        XCTAssertEqual(coded.problem, ["code": .string("conflict"), "detail": .string("Stale revision.")])

        let plain = ThalovantApiError(message: "HTTP 500", statusCode: 500, body: "boom")
        XCTAssertEqual(plain.body, "boom")
        XCTAssertNil(plain.errorCode)
        XCTAssertNil(plain.detail)
        XCTAssertNil(plain.problem)
    }

    func testAProblemAloneGivesItsCodeAndDetailAndAnExplicitOneWins() {
        let problem: JSONObject = [
            "detail": .string("Free plan allows up to 1 connection."),
            "code": .string("plan_limit"),
            "limit": .integer(1),
        ]
        let derived = ThalovantApiError(message: "refused", statusCode: 403, problem: problem)
        XCTAssertEqual(derived.errorCode, "plan_limit")
        XCTAssertEqual(derived.detail, "Free plan allows up to 1 connection.")
        XCTAssertEqual(derived.problem, problem)
        XCTAssertNil(derived.body)

        let explicit = ThalovantApiError(
            message: "refused",
            statusCode: 403,
            body: #"{"code": "from_body", "detail": "From the body."}"#,
            errorCode: "other",
            detail: "said differently",
            problem: problem
        )
        XCTAssertEqual(explicit.errorCode, "other")
        XCTAssertEqual(explicit.detail, "said differently")
        XCTAssertEqual(explicit.problem, problem, "a problem passed in wins over the body")
        XCTAssertEqual(explicit.message, "refused")
    }

    func testTheVectorsCoverEveryShapeTheRulesName() throws {
        // A copy that quietly lost its non-JSON or its nested case would still pass.
        let rows = try cases()
        let expects = rows.compactMap { $0["expect"]?.objectValue }
        XCTAssertTrue(expects.contains { $0["problem"] == .null })
        XCTAssertTrue(expects.contains { $0["code"]?.stringValue != nil && $0["detail"] == .null })
        XCTAssertTrue(expects.contains { $0["detail"]?.stringValue != nil && $0["code"] == .null })
        XCTAssertTrue(expects.contains { $0["problem"]?["detail"]?.objectValue != nil })
        XCTAssertTrue(expects.contains { $0["problem"]?["detail"]?.arrayValue != nil })
        XCTAssertTrue(expects.contains { ($0["detail"]?.stringValue?.count ?? 0) > 256 },
                      "no detail longer than any SDK's message limit")
        XCTAssertTrue(expects.contains { $0["detail"]?.stringValue?.contains("\n") == true })
        XCTAssertTrue(rows.contains { !($0["message_excludes"]?.arrayValue ?? []).isEmpty })
    }
}
