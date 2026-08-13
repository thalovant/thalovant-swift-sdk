import Foundation
import XCTest

@testable import ThalovantSDK

/// `VERSION` at the repository root is the canonical release version: the
/// auto-release workflow reads it to plan tags and the release workflow
/// verifies the tag against it. This guard (the same idea as the Rust SDK's
/// `user_agents_match_crate_version` test) keeps the user-agent constant from
/// drifting away from it.
final class VersionTests: XCTestCase {
    func testUserAgentMatchesVersionFile() throws {
        let versionFile = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/ThalovantSDKTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repository root
            .appendingPathComponent("VERSION")
        let version = try String(contentsOf: versionFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(version.isEmpty, "VERSION at the repository root must not be empty")
        XCTAssertEqual(defaultThalovantUserAgent, "ThalovantSwiftSDK/\(version)")
    }
}
