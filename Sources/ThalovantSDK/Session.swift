import Foundation

/// How a session waits, in seconds: the retry ladder, the probe cadence, how
/// long refusals count as "not admitted yet", and how long a new link must
/// stay up before it counts.
///
/// The defaults are measured on the appliance. The hub link drops a few times
/// a day and its refusals clear in about a minute, so the ladder starts at ten
/// seconds and stops at two minutes; the probe comes round every minute while
/// a session is held and every five seconds while none is.
public struct HubSessionPolicy: Sendable {
  /// After a failed connect, the wait before the next unattended attempt.
  public let retrySeconds: TimeInterval
  /// The ladder doubles towards this and stays there.
  public let retryCeilingSeconds: TimeInterval
  /// How often a held session is looked at.
  public let probeSeconds: TimeInterval
  /// How often the probe comes round while no session is held.
  public let probeDownSeconds: TimeInterval
  /// How long `HubSession.run()` keeps trying through refusals before it
  /// throws `ThalovantHubRefusedError`. A connection just created is refused
  /// until its hub has admitted it -- about ninety seconds -- so a refusal is
  /// only final once it has lasted this long.
  public let refusalGraceSeconds: TimeInterval
  /// How long a new link must stay up before `HubSession.connect()` and
  /// `run()` count it. A hub that does not know a client's static key says so
  /// only by closing right after the handshake. Zero does not wait.
  public let settleSeconds: TimeInterval
  public init(
    retrySeconds: TimeInterval = 10, retryCeilingSeconds: TimeInterval = 120,
    probeSeconds: TimeInterval = 60, probeDownSeconds: TimeInterval = 5,
    refusalGraceSeconds: TimeInterval = 600, settleSeconds: TimeInterval = 0.75
  ) throws {
    guard
      [retrySeconds, retryCeilingSeconds, probeSeconds, probeDownSeconds, refusalGraceSeconds]
        .allSatisfy({ $0.isFinite && $0 > 0 }), retryCeilingSeconds >= retrySeconds,
      settleSeconds.isFinite, settleSeconds >= 0
    else { throw ThalovantRuntimeError("Invalid hub session policy") }
    self.retrySeconds = retrySeconds
    self.retryCeilingSeconds = retryCeilingSeconds
    self.probeSeconds = probeSeconds
    self.probeDownSeconds = probeDownSeconds
    self.refusalGraceSeconds = refusalGraceSeconds
    self.settleSeconds = settleSeconds
  }
  public func nextWait(_ current: TimeInterval) -> TimeInterval {
    min(current * 2, retryCeilingSeconds)
  }
}
public func alive(_ client: ThalovantClient?) -> Bool {
  guard let client else { return false }
  return !["closed", "error"].contains(client.connectionInfo().phase)
}
/// One owned connection. Call probe at probeDelay intervals, or let `run()`
/// keep the link; admitted calls are never replayed because a lost response
/// does not prove an action was rejected.
///
/// `run()` stays connected until `close()`: after a failed attempt it waits
/// `retrySeconds`, doubling up to `retryCeilingSeconds`, and notices a dropped
/// link as it drops. A new link must stay up `settleSeconds`; one the hub
/// closes inside that window without a status, or with 1000 or 1008, was
/// refused. Refusals are retried like any failure -- a new connection is
/// refused until its hub admits it -- until they have lasted
/// `refusalGraceSeconds`, and then `run()` throws `ThalovantHubRefusedError`.
/// Subscriptions made with `on` follow every client the session builds.
public final class HubSession: @unchecked Sendable {
  public let policy: HubSessionPolicy
  private let makeClient: @Sendable () async throws -> ThalovantClient
  private let clock: @Sendable () -> TimeInterval
  private let debugLog: (@Sendable (String) -> Void)?
  private let lock = NSLock()
  private var client: ThalovantClient?
  private var closed = false
  private var busy = false
  private var released: AsyncGate?
  private var warming: Task<Void, Never>?
  private var nextRetry: TimeInterval = 0
  private var wait: TimeInterval
  private var up = false
  private var refusedSince: TimeInterval?
  private var watchers = [UUID: AsyncStream<Bool>.Continuation]()
  private let closedGate = AsyncGate()
  private final class Listener {
    let name: String
    let handler: (ThalovantEvent) -> Void
    var bound: ThalovantSubscription?
    init(_ name: String, _ handler: @escaping (ThalovantEvent) -> Void) {
      self.name = name
      self.handler = handler
    }
  }
  private var listeners = [UUID: Listener]()
  /// `connect` builds a client and connects it, and cleans up a client it
  /// could not connect. `debugLog` receives one line for every attempt, drop
  /// and recovery `run()` makes, meant for a debug log: what deserves more is
  /// for the application to say.
  public init(
    connect: @escaping @Sendable () async throws -> ThalovantClient,
    policy: HubSessionPolicy? = nil,
    clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    warm: Bool = true,
    debugLog: (@Sendable (String) -> Void)? = nil
  ) {
    self.makeClient = connect
    self.policy = policy ?? (try! HubSessionPolicy())
    self.clock = clock
    self.debugLog = debugLog
    self.wait = self.policy.retrySeconds
    if warm { _ = self.warm() }
  }
  /// A session whose clients connect with `identity`. It does not dial until
  /// asked -- `connect()`, `run()` or a call -- unless `warm` is set.
  public convenience init(
    identity: ThalovantIdentity,
    userAgent: String = defaultThalovantUserAgent,
    noiseStore: (any ThalovantNoiseStore)? = nil,
    connectTimeout: TimeInterval = 6,
    policy: HubSessionPolicy? = nil,
    warm: Bool = false,
    debugLog: (@Sendable (String) -> Void)? = nil
  ) {
    self.init(
      connect: {
        let client = try ThalovantClient(identity: identity, userAgent: userAgent, noiseStore: noiseStore)
        do {
          try await client.connect(timeout: connectTimeout)
        } catch {
          let refused = (client.transport as? HiveMindWSSTransport)?.refusedUpgradeStatus
          await client.close()
          if let refused, !(error is CancellationError) {
            throw ThalovantHubRefusedError("The hub refused this connection's credentials (HTTP \(refused)).")
          }
          throw error
        }
        return client
      }, policy: policy, warm: warm, debugLog: debugLog)
  }
  public var held: Bool { lock.locked { client != nil } }
  /// Whether a client is held and its link is up.
  public var connected: Bool { lock.locked { client }.map { alive($0) } ?? false }
  public var retryAt: TimeInterval { lock.locked { nextRetry } }
  public var retryWait: TimeInterval { lock.locked { wait } }
  public func probeDelay() -> TimeInterval { held ? policy.probeSeconds : policy.probeDownSeconds }
  /// `true` each time the link comes up and `false` each time it goes down,
  /// until the session closes. `connected` is the state now.
  public func stateChanges() -> AsyncStream<Bool> {
    AsyncStream { continuation in
      let id = UUID()
      let open = lock.locked { () -> Bool in
        guard !closed else { return false }
        watchers[id] = continuation
        return true
      }
      guard open else {
        continuation.finish()
        return
      }
      continuation.onTermination = { [weak self] _ in
        guard let self else { return }
        self.lock.locked { _ = self.watchers.removeValue(forKey: id) }
      }
    }
  }
  public func on(_ eventName: String, handler: @escaping (ThalovantEvent) -> Void) throws
    -> ThalovantSubscription
  {
    try lock.locked {
      guard !closed else { throw ThalovantConnectionError("Hub session is closed") }
      let listener = Listener(eventName, handler)
      listener.bound = client?.on(eventName, handler: handler)
      let id = UUID()
      listeners[id] = listener
      return ThalovantSubscription { [weak self] in
        self?.lock.locked {
          listener.bound?.close()
          self?.listeners.removeValue(forKey: id)
        }
      }
    }
  }
  private var isClosed: Bool { lock.locked { closed } }
  private func acquire() async throws {
    while true {
      try Task.checkCancellation()
      let previous = lock.locked { () -> AsyncGate? in
        if !busy {
          busy = true
          released = AsyncGate()
          return nil
        }
        return released
      }
      guard let previous else { return }
      try await previous.wait(timeout: nil, timeoutError: nil)
    }
  }
  private func release() {
    let gate = lock.locked { () -> AsyncGate? in
      busy = false
      let gate = released
      released = nil
      return gate
    }
    gate?.open()
  }
  private func setState(_ isUp: Bool) {
    // Yielded under the lock so two transitions can never reach a watcher out
    // of order; a yield only schedules the consumer.
    lock.locked {
      guard up != isUp else { return }
      up = isUp
      for watcher in watchers.values { watcher.yield(isUp) }
    }
  }
  private func drop() async {
    let old = lock.locked { () -> ThalovantClient? in
      let old = client
      client = nil
      for listener in listeners.values {
        listener.bound?.close()
        listener.bound = nil
      }
      return old
    }
    setState(false)
    await old?.close()
  }
  /// Lets go of a client that never became the session's, or stopped being it.
  private func retire(_ stale: ThalovantClient) async {
    lock.locked {
      guard client === stale else { return }
      client = nil
      for listener in listeners.values {
        listener.bound?.close()
        listener.bound = nil
      }
    }
    await stale.close()
  }
  private func ensure(settle: Bool = false) async throws -> ThalovantClient {
    let held = try lock.locked { () throws -> ThalovantClient? in
      guard !closed else { throw ThalovantConnectionError("Hub session is closed") }
      return client
    }
    if let held { return held }
    var fresh: ThalovantClient?
    do {
      let connected = try await makeClient()
      fresh = connected
      try Task.checkCancellation()
      // Bound before the settle, so nothing the hub sends in its first
      // moments is missed; a link that fails the settle is retired whole.
      try lock.locked {
        guard !closed else { throw ThalovantConnectionError("Hub session is closed") }
        for listener in listeners.values {
          listener.bound = connected.on(listener.name, handler: listener.handler)
        }
        client = connected
      }
      if settle { try await self.settle(connected) }
      lock.locked {
        nextRetry = 0
        wait = policy.retrySeconds
        refusedSince = nil
      }
      setState(true)
      return connected
    } catch {
      lock.locked {
        nextRetry = clock() + wait
        wait = policy.nextWait(wait)
      }
      if let fresh { await retire(fresh) }
      throw error
    }
  }
  /// Waits `settleSeconds` for a new link to end, and says why when it does.
  private func settle(_ connected: ThalovantClient) async throws {
    guard policy.settleSeconds > 0, let lifetime = connected.transport.lifetime else { return }
    try await lifetime.ended.wait(timeout: policy.settleSeconds, timeoutError: nil)
    guard lifetime.ended.isOpen else { return }
    if lifetime.refused {
      throw ThalovantHubRefusedError(
        "The hub closed the link right after the handshake: it does not accept these credentials, or not yet."
      )
    }
    throw ThalovantConnectionError("The hub closed the link right after the handshake.")
  }
  @discardableResult public func warm() -> Task<Void, Never>? {
    lock.locked {
      if closed || clock() < nextRetry { return nil }
      if let warming { return warming }
      let task = Task { [self] in
        defer { lock.locked { warming = nil } }
        do {
          try await acquire()
          defer { release() }
          _ = try await ensure()
        } catch { /* Backoff is exposed; foreground calls surface failures. */  }
      }
      warming = task
      return task
    }
  }
  public func probe() async {
    let acquired = lock.locked { () -> Bool in
      if closed || busy { return false }
      busy = true
      released = AsyncGate()
      return true
    }
    guard acquired else { return }
    let old = lock.locked { client }
    if old != nil && !alive(old) { await drop() }
    release()
    if !held { _ = warm() }
  }
  /// Makes one attempt now: returns with a live link, or throws why there is
  /// none. A link already up is kept. A new one must stay up `settleSeconds`:
  /// `ThalovantHubRefusedError` when the hub closed it the way it turns
  /// credentials away, `ThalovantConnectionError` (or `ThalovantTimeoutError`)
  /// for everything else.
  public func connect() async throws {
    try await acquire()
    defer { release() }
    let old = try lock.locked { () throws -> ThalovantClient? in
      guard !closed else { throw ThalovantConnectionError("Hub session is closed") }
      return client
    }
    if let old {
      if alive(old) { return }
      await drop()
    }
    debugLog?("hub link: connecting")
    _ = try await ensure(settle: true)
    debugLog?("hub link: up")
  }
  /// Stays connected until `close()`, by policy; see the type's description.
  ///
  /// Returns when the session closes; throws `ThalovantHubRefusedError` once
  /// refusals have lasted `refusalGraceSeconds`, `CancellationError` when its
  /// task is cancelled, and anything a connect throws that is neither a
  /// connection failure nor a timeout -- an identity that cannot work will not
  /// start working by being retried. A link `connect()` already opened is the
  /// one `run()` keeps; it does not dial again.
  public func run() async throws {
    while true {
      try Task.checkCancellation()
      guard !isClosed else { return }
      if let live = lock.locked({ client }), alive(live) {
        await waitWhileUp(live)
        guard !isClosed else { return }
        try Task.checkCancellation()
        if !alive(live) {
          debugLog?("hub link: dropped")
          try await acquire()
          if lock.locked({ client === live }) { await drop() }
          release()
        }
        continue
      }
      do {
        try await connect()
        continue
      } catch is CancellationError {
        throw CancellationError()
      } catch let refusal as ThalovantHubRefusedError {
        let now = clock()
        let since = lock.locked { () -> TimeInterval in
          if refusedSince == nil { refusedSince = now }
          return refusedSince ?? now
        }
        debugLog?("hub link: refused (\(refusal.message))")
        if now - since >= policy.refusalGraceSeconds { throw refusal }
      } catch let failure
        where failure is any ThalovantConnectionFailure || failure is any ThalovantTimeoutFailure
      {
        lock.locked { refusedSince = nil }
        debugLog?("hub link: attempt failed (\(failure.localizedDescription))")
      }
      guard !isClosed else { return }
      let pause = max(0, retryAt - clock())
      debugLog?("hub link: next attempt in \(wholeSeconds(pause.rounded()))s")
      try? await closedGate.wait(timeout: pause, timeoutError: nil)
    }
  }
  /// Until the link ends, the probe interval passes, or the session closes.
  private func waitWhileUp(_ live: ThalovantClient) async {
    let ended = live.transport.lifetime?.ended
    let closedGate = self.closedGate
    let probe = policy.probeSeconds
    await withTaskGroup(of: Void.self) { group in
      if let ended {
        group.addTask { try? await ended.wait(timeout: probe, timeoutError: nil) }
      }
      group.addTask { try? await closedGate.wait(timeout: probe, timeoutError: nil) }
      _ = await group.next()
      group.cancelAll()
    }
  }
  private func call<T>(_ operation: (ThalovantClient) async throws -> T) async throws -> T {
    try await acquire()
    defer { release() }
    let old = lock.locked { client }
    if old != nil && !alive(old) { await drop() }
    let connected = try await ensure()
    do { return try await operation(connected) } catch {
      if !(error is ThalovantRuntimeError) && !(error is ThalovantPolicyDeniedError) {
        await drop()
      }
      throw error
    }
  }
  public func ask(
    _ text: String, timeout: TimeInterval = 12, lang: String = "en-us", context: JSONObject = [:],
    sessionId: String? = nil, requestId: String? = nil, replySettle: TimeInterval? = nil,
    emptyReplyWait: TimeInterval? = nil
  ) async throws -> ThalovantReply {
    try await call {
      try await $0.ask(
        text, timeout: timeout, lang: lang, context: context, sessionId: sessionId,
        requestId: requestId, replySettle: replySettle, emptyReplyWait: emptyReplyWait)
    }
  }
  public func emit(_ eventType: String, data: JSONObject = [:], context: JSONObject = [:])
    async throws
  { try await call { try await $0.emit(eventType, data: data, context: context) } }
  /// Answers a message the hub sent, back along the route it came.
  ///
  /// The hub is waiting on it, often while an `ask` holds the session -- a
  /// skill asking the device something mid-turn -- so a reply goes out on the
  /// live client at once rather than queueing behind that ask, which would
  /// hold it until the turn ends. Frames stay ordered: the transport seals
  /// and writes them one at a time. With no live client it connects first,
  /// like any call.
  public func reply(
    to event: ThalovantEvent, type: String, data: JSONObject = [:], context: JSONObject = [:]
  ) async throws {
    if let live = lock.locked({ client }), alive(live) {
      try await live.reply(to: event, type: type, data: data, context: context)
      return
    }
    try await call { try await $0.reply(to: event, type: type, data: data, context: context) }
  }
  /// Terminal close waits for admitted work even if its caller was cancelled.
  public func close() async {
    lock.locked { closed = true }
    closedGate.open()
    await Task.detached { [self] in
      do {
        try await acquire()
        defer { release() }
        await drop()
        lock.locked { listeners.removeAll() }
      } catch { /* This internally owned task is never cancelled. */  }
    }.value
    let ending = lock.locked { () -> [AsyncStream<Bool>.Continuation] in
      let all = Array(watchers.values)
      watchers.removeAll()
      return all
    }
    for watcher in ending { watcher.finish() }
  }
}
public func hubHostname(_ master: String?) -> String {
  let text = master?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  guard !text.isEmpty else { return "" }
  return URLComponents(string: text.contains("://") ? text : "wss://\(text)")?.host ?? ""
}
public struct OriginAttempt: Sendable {
  public let host: String
  public let connectTimeout: TimeInterval
  public let handshakeSeconds: TimeInterval?
  public let address: String?
  public init(
    host: String, connectTimeout: TimeInterval, handshakeSeconds: TimeInterval? = nil,
    address: String? = nil
  ) {
    self.host = host
    self.connectTimeout = connectTimeout
    self.handshakeSeconds = handshakeSeconds
    self.address = address
  }
}
/// The builder binds the address on its own transport, preserving host/TLS/SNI,
/// and owns cleanup before throwing. No process-global resolver overrides.
public final class OriginPreference: @unchecked Sendable {
  public let address: String
  public let handshakeSeconds: TimeInterval
  public let cooldownSeconds: TimeInterval
  private let clock: @Sendable () -> TimeInterval
  private let lock = NSLock()
  private var quietUntil: TimeInterval = 0
  public init(
    address: String, handshakeSeconds: TimeInterval = 1.5, cooldownSeconds: TimeInterval = 300,
    clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
  ) throws {
    guard
      handshakeSeconds.isFinite && handshakeSeconds > 0 && cooldownSeconds.isFinite
        && cooldownSeconds > 0
    else { throw ThalovantRuntimeError("Origin budgets must be positive and finite") }
    self.address = address
    self.handshakeSeconds = handshakeSeconds
    self.cooldownSeconds = cooldownSeconds
    self.clock = clock
  }
  public var coolingDown: Bool { lock.locked { clock() < quietUntil } }
  public func connect<T>(_ options: OriginAttempt, build: (OriginAttempt) async throws -> T)
    async throws -> T
  {
    try Task.checkCancellation()
    if !address.isEmpty && !options.host.isEmpty && !coolingDown {
      do {
        let client = try await build(
          OriginAttempt(
            host: options.host, connectTimeout: options.connectTimeout,
            handshakeSeconds: handshakeSeconds, address: address))
        lock.locked { quietUntil = 0 }
        return client
      } catch is CancellationError { throw CancellationError() } catch {
        try Task.checkCancellation()
        lock.locked { quietUntil = clock() + cooldownSeconds }
      }
    }
    return try await build(
      OriginAttempt(
        host: options.host, connectTimeout: options.connectTimeout,
        handshakeSeconds: options.handshakeSeconds))
  }
}
