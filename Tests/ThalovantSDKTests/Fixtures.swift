import Foundation

/// Fixture JSON copied from the API pydantic schemas
/// (thalovant-api/app/schemas/*.py). Field names are snake_case exactly as
/// the API serializes them.
enum Fixtures {
    /// `OperationResource` from app/schemas/operations.py (all 16 fields).
    static let operation = """
    {
      "id": "0b849a6c-3d3f-49a5-9f10-8f4dbb2f3d10",
      "kind": "hub.release",
      "aggregate_type": "hub",
      "aggregate_id": "b3b1f5a0-91b8-4a71-a2e5-53422dd0f841",
      "status": "timed_out",
      "details": {"attempt": 3, "region": "ca-central-1", "dry_run": false},
      "git_commit_sha": "0f4f9c8f2a1b3c4d5e6f7a8b9c0d1e2f3a4b5c6d",
      "error_code": "reconcile_timeout",
      "error_message": "The hub did not reach Ready within the deadline.",
      "created_at": "2026-08-12T15:04:05Z",
      "updated_at": "2026-08-12T15:24:05Z",
      "committed_at": "2026-08-12T15:05:00Z",
      "applied_at": "2026-08-12T15:06:00Z",
      "ready_at": null,
      "terminal_at": "2026-08-12T15:24:05Z",
      "links": {"self": "/v1/operations/operation-1", "aggregate": null}
    }
    """

    /// Minimal `OperationResource` where optional fields are null.
    static let operationPending = """
    {
      "id": "8e7f2d61-0f5e-4f8b-9a3c-2b1d0c9e8f7a",
      "kind": "client.create",
      "aggregate_type": "client",
      "aggregate_id": null,
      "status": "requested",
      "details": {},
      "git_commit_sha": null,
      "error_code": null,
      "error_message": null,
      "created_at": "2026-08-13T09:00:00Z",
      "updated_at": "2026-08-13T09:00:00Z",
      "committed_at": null,
      "applied_at": null,
      "ready_at": null,
      "terminal_at": null,
      "links": {"self": "/v1/operations/operation-1"}
    }
    """

    /// `MemoryItemResource` from app/schemas/memory.py.
    static let memoryItem = """
    {
      "id": "9f2b5a44-3c1e-4f6d-8a7b-0c9d8e7f6a5b",
      "owner_id": "11111111-2222-3333-4444-555555555555",
      "created_by_id": "11111111-2222-3333-4444-555555555555",
      "hub_id": null,
      "scope": "workspace",
      "kind": "preference",
      "title": "Timezone",
      "content": "Prefer America/Toronto for scheduling.",
      "tags": ["timezone", "scheduling"],
      "source": "manual",
      "metadata": {"origin": "daily-desk", "pinned": true},
      "consent_scope": "daily_desk_memory",
      "consent_version": null,
      "retention_policy": "user_controlled",
      "expires_at": null,
      "deleted_at": null,
      "created_at": "2026-08-01T10:00:00Z",
      "updated_at": "2026-08-02T11:30:00Z"
    }
    """

    /// `MemoryListResponse` from app/schemas/memory.py.
    static let memoryList = """
    {
      "data": [\(memoryItem)],
      "meta": {"count": 1, "next": null, "prev": null, "extra": {"total": 1}},
      "links": {"self": "/v1/memory?limit=50", "next": null}
    }
    """

    /// `MemorySummaryResponse` from app/schemas/memory.py.
    static let memorySummary = """
    {
      "total": 12,
      "by_scope": {"personal": 4, "workspace": 8},
      "by_kind": {"note": 6, "preference": 5, "fact": 1},
      "expired": 1,
      "deleted": 2
    }
    """

    /// `ClientIdentifyResource` from app/schemas/clients.py — the
    /// `initial_identify` document returned by `POST /v1/clients`.
    static let clientIdentify = """
    {
      "password": "identity-password",
      "access_key": "identity-access-key",
      "crypto_key": "0123456789abcdefextra",
      "site_id": "swift-demo-client",
      "default_port": 443,
      "default_master": "https://hub-1.hubs.thalovant.com",
      "mqtt": {
        "endpoint": "mqtts://mqtt.hub-1.hubs.thalovant.com:8883",
        "username": "mqtt-user",
        "password": "mqtt-pass",
        "topic_prefix": "hivemind/hub-1",
        "tls": true
      }
    }
    """

    /// A hub resource carrying protocol settings and data-plane endpoints.
    static let hub = """
    {
      "id": "b3b1f5a0-91b8-4a71-a2e5-53422dd0f841",
      "slug": "hub-1",
      "title": "Hub One",
      "domain": "hub-1.hubs.thalovant.com",
      "spec": {
        "protocols": {
          "wss": {"enabled": true},
          "http": {"enabled": true},
          "mqtt": {"enabled": false}
        }
      },
      "data_plane_endpoints": {
        "https": "https://hub-1.hubs.thalovant.com",
        "wss": "wss://hub-1.hubs.thalovant.com/ws"
      }
    }
    """
}
