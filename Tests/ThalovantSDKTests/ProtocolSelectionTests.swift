import Foundation
import XCTest

@testable import ThalovantSDK

final class ProtocolSelectionTests: XCTestCase {
    func testDefaultsWssEnabled() {
        let settings = HubProtocolSettings.from(JSONValue.object([:]))
        XCTAssertTrue(settings.wss)
        XCTAssertFalse(settings.http)
        XCTAssertFalse(settings.mqtt)
        XCTAssertEqual(settings.enabledProtocols(), [.wss])
    }

    func testReadsHubSpecProtocols() throws {
        let hub = try ThalovantJSON.decodeObject(Fixtures.hub)
        let settings = HubProtocolSettings.from(hub)
        XCTAssertTrue(settings.wss)
        XCTAssertTrue(settings.http)
        XCTAssertTrue(settings.https)
        XCTAssertFalse(settings.mqtt)
        XCTAssertEqual(settings.enabledProtocols(), [.wss, .https])
    }

    func testEnabledFlagCoercions() {
        let settings = HubProtocolSettings.from(JSONValue.object([
            "protocols": .object([
                "wss": .string("off"),
                "http": .string("yes"),
                "mqtt": .bool(true),
            ])
        ]))
        XCTAssertFalse(settings.wss)
        XCTAssertTrue(settings.http)
        XCTAssertTrue(settings.mqtt)
    }

    func testEndpointsFromHubPrefersExplicitEndpoints() throws {
        let hub = try ThalovantJSON.decodeObject(Fixtures.hub)
        let endpoints = HubDataPlaneEndpoints.fromHub(hub)
        XCTAssertEqual(endpoints.https, "https://hub-1.hubs.thalovant.com")
        XCTAssertEqual(endpoints.wss, "wss://hub-1.hubs.thalovant.com/ws")
        XCTAssertNil(endpoints.mqtt)
    }

    func testEndpointsDerivedFromDomain() {
        let endpoints = HubDataPlaneEndpoints.fromHub([
            "domain": "hub-2.hubs.thalovant.com",
            "spec": .object(["protocols": .object(["http": .object(["enabled": true])])]),
        ])
        XCTAssertEqual(endpoints.wss, "wss://hub-2.hubs.thalovant.com")
        XCTAssertEqual(endpoints.https, "https://hub-2.hubs.thalovant.com")
    }

    func testSelectionPrefersWssByDefault() throws {
        let hub = try ThalovantJSON.decodeObject(Fixtures.hub)
        let selected = selectDataPlaneEndpoint(
            endpoints: HubDataPlaneEndpoints.fromHub(hub),
            protocols: HubProtocolSettings.from(hub)
        )
        XCTAssertEqual(selected?.hubProtocol, .wss)
        XCTAssertEqual(selected?.endpoint, "wss://hub-1.hubs.thalovant.com/ws")
    }

    func testSelectionSkipsDisabledProtocols() {
        let endpoints = HubDataPlaneEndpoints(https: "https://hub.example.com", wss: "wss://hub.example.com")
        let protocols = HubProtocolSettings(wss: false, http: true, mqtt: false)
        let selected = selectDataPlaneEndpoint(endpoints: endpoints, protocols: protocols)
        XCTAssertEqual(selected?.hubProtocol, .https)
    }

    func testSelectionHonorsCustomPreference() {
        let endpoints = HubDataPlaneEndpoints(https: "https://hub.example.com", wss: "wss://hub.example.com")
        let protocols = HubProtocolSettings(wss: true, http: true, mqtt: false)
        let selected = selectDataPlaneEndpoint(
            endpoints: endpoints,
            protocols: protocols,
            preferredProtocols: [.https, .wss]
        )
        XCTAssertEqual(selected?.hubProtocol, .https)
    }

    func testSelectionReturnsNilWithoutUsableEndpoint() {
        let endpoints = HubDataPlaneEndpoints()
        let protocols = HubProtocolSettings(wss: true, http: true, mqtt: true)
        XCTAssertNil(selectDataPlaneEndpoint(endpoints: endpoints, protocols: protocols))
    }

    func testEndpointFromDomainConversions() {
        XCTAssertEqual(endpointFromDomain("hub.example.com", hubProtocol: .wss), "wss://hub.example.com")
        XCTAssertEqual(endpointFromDomain("https://hub.example.com/", hubProtocol: .wss), "wss://hub.example.com")
        XCTAssertEqual(endpointFromDomain("wss://hub.example.com", hubProtocol: .https), "https://hub.example.com")
        XCTAssertEqual(endpointFromDomain("http://hub.example.com", hubProtocol: .https), "https://hub.example.com")
        XCTAssertEqual(endpointFromDomain("hub.example.com", hubProtocol: .mqtt), "")
    }

    func testIdentityEndpointBaseUsesHttpsEndpointFirst() throws {
        let identity = try ThalovantIdentity(json: [
            "access_key": "k", "password": "p", "site_id": "s",
            "default_master": "wss://hub.example.com",
            "default_port": 8443,
            "data_plane_endpoints": .object(["https": "https://hub.example.com/api"]),
        ])
        // The fallback port is applied when the endpoint does not pin one,
        // mirroring the sibling SDKs.
        XCTAssertEqual(identity.endpointBase(), "https://hub.example.com:8443/api")
    }

    func testIdentityEndpointBaseKeepsExplicitPort() throws {
        let identity = try ThalovantIdentity(json: [
            "access_key": "k", "password": "p", "site_id": "s",
            "default_master": "wss://hub.example.com",
            "default_port": 8443,
            "data_plane_endpoints": .object(["https": "https://hub.example.com:9443/api"]),
        ])
        XCTAssertEqual(identity.endpointBase(), "https://hub.example.com:9443/api")
    }

    func testIdentityEndpointBaseFallsBackToMaster() throws {
        let identity = try ThalovantIdentity(json: [
            "access_key": "k", "password": "p", "site_id": "s",
            "default_master": "wss://hub.example.com",
            "default_port": 5679,
            "default_path": "hive",
        ])
        XCTAssertEqual(identity.endpointBase(), "https://hub.example.com:5679/hive")
    }

    func testControlAPIURLNormalization() {
        XCTAssertEqual(
            ThalovantControlPlane.normalizeControlAPIURL("https://api.thalovant.com"),
            "https://api.thalovant.com/"
        )
        XCTAssertEqual(
            ThalovantControlPlane.normalizeControlAPIURL("https://api.thalovant.com/v1"),
            "https://api.thalovant.com/"
        )
        XCTAssertEqual(
            ThalovantControlPlane.normalizeControlAPIURL("https://api.thalovant.com/v1///"),
            "https://api.thalovant.com/"
        )
        XCTAssertEqual(
            ThalovantControlPlane.normalizeControlAPIURL("http://localhost:8000/"),
            "http://localhost:8000/"
        )
    }

    func testCleanSiteId() {
        XCTAssertEqual(cleanSiteId("My Swift  Client"), "My-Swift-Client")
        XCTAssertEqual(cleanSiteId("under__scored"), "under-scored")
        XCTAssertTrue(cleanSiteId("   ").hasPrefix("thalovant-client-"))
    }
}
