import Foundation

/// What an ask does when the hub refuses it or cannot answer it.
///
/// The hub sends `hive.policy.denied` the instant it refuses, built with source
/// and destination context only (hivemind-core `_send_policy_denied`), so it
/// carries no request id and names the type it refused instead. The shared
/// `refusal-vectors.json` pins every case here.
enum Refusal {
    /// How long a fire-and-forget utterance counts as possibly still being
    /// refused. Denials come back as fast as the hub admits a message --
    /// milliseconds -- so this is generous on purpose: a wrong "in flight" only
    /// costs an ask the deadline it always had, where a wrong "not in flight"
    /// ends a question the hub never refused. The shared refusal vectors name
    /// it (`untracked_grace_seconds`), so every SDK uses the same window.
    static let untrackedUtteranceGrace: TimeInterval = 10

    /// Whether a `hive.policy.denied` is this ask's to throw.
    ///
    /// A denial carrying a request id is judged by it, like any reply. Without
    /// one it is taken when it names the type this ask sent and this ask is the
    /// only utterance the client has out: with a second ask, a query, or a
    /// fire-and-forget utterance still inside the grace window, either could be
    /// the one refused, and a wrong guess ends a question the hub never refused.
    static func belongsToAsk(
        requestId: String?,
        ownRequestId: String,
        deniedType: String?,
        asksInFlight: Int,
        queriesInFlight: Int,
        sendsInFlight: Int
    ) -> Bool {
        if let requestId, !requestId.isEmpty {
            return requestId == ownRequestId
        }
        return deniedType == ThalovantEvents.recognizerLoopUtterance
            && asksInFlight == 1
            && queriesInFlight == 0
            && sendsInFlight == 0
    }

    /// The typed error an ask throws for the failure event it ended on: a
    /// refusal, a question the hub has nothing for, and a fault need three
    /// different sentences, and a bare runtime error allowed only one.
    static func error(for failure: ThalovantEvent) -> Error {
        switch failure.name {
        case ThalovantEvents.policyDenied:
            return ThalovantPolicyDeniedError.fromEvent(failure)
        case ThalovantEvents.intentUnmatched, ThalovantEvents.intentFailure:
            // What the person said: both names carry the input, and that is
            // what a caller shows. `reason` is not on these events at all, so
            // reading it left `said` empty.
            return ThalovantUnansweredError(said: failure.text.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return ThalovantRuntimeError(failure.text.isEmpty ? "Hub reported \(failure.name)." : failure.text)
        }
    }
}
