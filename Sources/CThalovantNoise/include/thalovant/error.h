/* Error codes shared by every Thalovant embedded C module. */
#ifndef THALOVANT_ERROR_H
#define THALOVANT_ERROR_H

typedef enum {
    THALOVANT_OK = 0,
    /* Bad arguments or malformed input. */
    THALOVANT_ERR_INVALID = -1,
    /* A caller-provided buffer or token pool is too small. */
    THALOVANT_ERR_NOMEM = -2,
    /* JSON syntax error. */
    THALOVANT_ERR_JSON = -3,
    /* A required field is missing. */
    THALOVANT_ERR_MISSING = -4,
    /* AES-GCM authentication tag mismatch. */
    THALOVANT_ERR_AUTH = -5,
    /* Valid but unsupported input (e.g. compressed binary frames). */
    THALOVANT_ERR_UNSUPPORTED = -6,
    /*
     * The hub answered hive.policy.denied: this connection may not publish
     * the message type it sent (see thalovant_intent_event.denied_type).
     */
    THALOVANT_ERR_POLICY_DENIED = -7,
    /*
     * The hub answered a query with {"ok": false, "error": ...}: the query
     * failed and told us nothing (thalovant_intent_event.error carries the
     * hub's own words). Unlike THALOVANT_ERR_POLICY_DENIED, which is the
     * connection's allow-list refusing to publish the type at all, this is
     * the runtime declining to answer a query it did receive.
     */
    THALOVANT_ERR_HUB_REFUSED = -8,
} thalovant_err;

/* Human-readable name for an error code (never NULL). */
const char *thalovant_err_str(int err);

#endif /* THALOVANT_ERROR_H */
