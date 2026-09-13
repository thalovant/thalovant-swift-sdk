import Foundation

public struct HubSessionPolicy: Sendable {
  public let retrySeconds: TimeInterval
  public let retryCeilingSeconds: TimeInterval
  public let probeSeconds: TimeInterval
  public let probeDownSeconds: TimeInterval
  public init(
    retrySeconds: TimeInterval = 10, retryCeilingSeconds: TimeInterval = 120,
    probeSeconds: TimeInterval = 60, probeDownSeconds: TimeInterval = 5
  ) throws {
    guard
      [retrySeconds, retryCeilingSeconds, probeSeconds, probeDownSeconds].allSatisfy({
        $0.isFinite && $0 > 0
      }), retryCeilingSeconds >= retrySeconds
    else { throw ThalovantRuntimeError("Invalid hub session policy") }
    self.retrySeconds = retrySeconds
    self.retryCeilingSeconds = retryCeilingSeconds
    self.probeSeconds = probeSeconds
    self.probeDownSeconds = probeDownSeconds
  }
  public func nextWait(_ current: TimeInterval) -> TimeInterval {
    min(current * 2, retryCeilingSeconds)
  }
}
public func alive(_ client: ThalovantClient?) -> Bool {
  guard let client else { return false }
  return !["closed", "error"].contains(client.connectionInfo().phase)
}
/// One owned connection. Call probe at probeDelay intervals; admitted calls are
/// never replayed because a lost response does not prove an action was rejected.
public final class HubSession: @unchecked Sendable {
  public let policy: HubSessionPolicy
  private let connect: @Sendable () async throws -> ThalovantClient
  private let clock: @Sendable () -> TimeInterval
  private let lock = NSLock()
  private var client: ThalovantClient?
  private var closed = false
  private var busy = false
  private var released: AsyncGate?
  private var warming: Task<Void, Never>?
  private var nextRetry: TimeInterval = 0
  private var wait: TimeInterval
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
  public init(
    connect: @escaping @Sendable () async throws -> ThalovantClient,
    policy: HubSessionPolicy? = nil,
    clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    warm: Bool = true
  ) {
    self.connect = connect
    self.policy = policy ?? (try! HubSessionPolicy())
    self.clock = clock
    self.wait = self.policy.retrySeconds
    if warm { _ = self.warm() }
  }
  public var held: Bool { lock.locked { client != nil } }
  public var retryAt: TimeInterval { lock.locked { nextRetry } }
  public var retryWait: TimeInterval { lock.locked { wait } }
  public func probeDelay() -> TimeInterval { held ? policy.probeSeconds : policy.probeDownSeconds }
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
    await old?.close()
  }
  private func ensure() async throws -> ThalovantClient {
    let held = try lock.locked { () throws -> ThalovantClient? in
      guard !closed else { throw ThalovantConnectionError("Hub session is closed") }
      return client
    }
    if let held { return held }
    var fresh: ThalovantClient?
    do {
      let connected = try await connect()
      fresh = connected
      try Task.checkCancellation()
      try lock.locked {
        guard !closed else { throw ThalovantConnectionError("Hub session is closed") }
        for listener in listeners.values {
          listener.bound = connected.on(listener.name, handler: listener.handler)
        }
        client = connected
        nextRetry = 0
        wait = policy.retrySeconds
      }
      return connected
    } catch {
      lock.locked {
        nextRetry = clock() + wait
        wait = policy.nextWait(wait)
      }
      await fresh?.close()
      throw error
    }
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
  /// Terminal close waits for admitted work even if its caller was cancelled.
  public func close() async {
    lock.locked { closed = true }
    await Task.detached { [self] in
      do {
        try await acquire()
        defer { release() }
        await drop()
        lock.locked { listeners.removeAll() }
      } catch { /* This internally owned task is never cancelled. */  }
    }.value
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
