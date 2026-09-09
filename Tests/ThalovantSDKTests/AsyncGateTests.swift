import Foundation
import XCTest
@testable import ThalovantSDK
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class AsyncGateTests: XCTestCase {
    private func waitForQueuedEntries(_ count: Int, writer: NoiseSocketWriter) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while await writer.queuedEntryCount != count {
            guard ProcessInfo.processInfo.systemUptime < deadline else { XCTFail("Writer barrier did not settle"); return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    func testCancelledQueuedWriteSkipsSealingAndDoesNotPoisonSuccessor() async throws {
        let writer = NoiseSocketWriter(), blocked = AsyncGate(), entered = AsyncGate()
        let first = Task {
            try await writer.send(frames: { [.string("first")] }, write: { _ in
                entered.open(); try await blocked.wait(timeout: nil, timeoutError: nil)
            })
        }
        try await entered.wait(timeout: 3, timeoutError: noiseError("First send did not start"))
        let cancelled = Task {
            try await writer.send(frames: { XCTFail("Cancelled queued write consumed a nonce"); return [] }, write: { _ in XCTFail("Cancelled write sent a frame") })
        }
        try await waitForQueuedEntries(2, writer: writer)
        let sent = AsyncGate()
        let survivor = Task { try await writer.send(frames: { [.string("survivor")] }, write: { _ in sent.open() }) }
        try await waitForQueuedEntries(3, writer: writer)
        cancelled.cancel()
        do { try await cancelled.value; XCTFail("Expected queued cancellation") } catch is NoiseQueuedSendCancelled {}
        XCTAssertFalse(sent.isOpen)
        blocked.open(); try await first.value; try await survivor.value
        XCTAssertTrue(sent.isOpen)
    }

    func testCancelledActiveWriteKeepsPhysicalOwnershipAndAllowsSuccessor() async throws {
        let writer = NoiseSocketWriter(), entered = AsyncGate(), blocked = AsyncGate(), failed = AsyncGate()
        let active = Task { try await writer.send(frames: { [.string("sealed")] }, write: { _ in
            entered.open(); try await blocked.wait(timeout: nil, timeoutError: nil)
        }, onPhysicalFailure: { _ in failed.open() }) }
        try await entered.wait(timeout: 3, timeoutError: noiseError("Send did not start"))
        let sent = AsyncGate()
        let successor = Task { try await writer.send(frames: { [.string("successor")] }, write: { _ in sent.open() }) }
        try await waitForQueuedEntries(2, writer: writer)
        active.cancel()
        do { try await active.value; XCTFail("Expected active cancellation") } catch is CancellationError {}
        XCTAssertFalse(failed.isOpen); XCTAssertFalse(sent.isOpen)
        blocked.open(); try await successor.value
        XCTAssertTrue(sent.isOpen); XCTAssertFalse(failed.isOpen)
    }

    func testPhysicalWriteTimeoutRetainsTailUntilNoncooperativeCleanupCompletes() async throws {
        let writer = NoiseSocketWriter(physicalWriteTimeout: 0.05)
        let entered = AsyncGate(), release = AsyncGate(), retired = AsyncGate(), failed = AsyncGate()
        defer { release.open() }
        let active = Task { try await writer.send(frames: { [.string("sealed")] }, write: { _ in
            entered.open()
            do { try await AsyncGate().wait(timeout: nil, timeoutError: nil) }
            catch {
                await Task.detached { try? await release.wait(timeout: nil, timeoutError: nil) }.value
                retired.open(); throw error
            }
        }, onPhysicalFailure: { _ in failed.open() }) }
        try await entered.wait(timeout: 3, timeoutError: noiseError("Send did not start"))
        let successor = Task { try await writer.send(frames: { XCTFail("Expired cipher state was reused"); return [] }, write: { _ in }) }
        try await waitForQueuedEntries(2, writer: writer)
        do { try await active.value; XCTFail("Expected physical deadline") } catch is ThalovantTimeoutError {}
        XCTAssertTrue(failed.isOpen); XCTAssertFalse(retired.isOpen)
        let owned = await writer.queuedEntryCount; XCTAssertEqual(owned, 2)
        release.open()
        do { try await successor.value; XCTFail("Expected physical predecessor failure") } catch is ThalovantTimeoutError {}
        XCTAssertTrue(retired.isOpen)
    }

    func testPhysicalWriteFailureStillPoisonsGenerationAfterCallerCancellation() async throws {
        let writer = NoiseSocketWriter(), entered = AsyncGate(), release = AsyncGate(), failed = AsyncGate()
        defer { release.open() }
        let active = Task { try await writer.send(frames: { [.string("sealed")] }, write: { _ in
            entered.open(); try await release.wait(timeout: nil, timeoutError: nil)
            throw noiseError("Actual physical write failure")
        }, onPhysicalFailure: { _ in failed.open() }) }
        try await entered.wait(timeout: 3, timeoutError: noiseError("Send did not start"))
        let successor = Task { try await writer.send(frames: { XCTFail("Failed cipher state was reused"); return [] }, write: { _ in }) }
        try await waitForQueuedEntries(2, writer: writer)
        active.cancel()
        do { try await active.value; XCTFail("Expected active cancellation") } catch is CancellationError {}
        XCTAssertFalse(failed.isOpen)
        release.open()
        do { try await successor.value; XCTFail("Expected physical failure") }
        catch { XCTAssertEqual(error.localizedDescription, "Actual physical write failure") }
        XCTAssertTrue(failed.isOpen)
    }

    func testUntimedGateWaitStillRespondsToCancellation() async throws {
        let gate = AsyncGate()
        let waiter = Task { try await gate.wait(timeout: nil, timeoutError: nil) }
        waiter.cancel()
        do { try await waiter.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        XCTAssertEqual(gate.waiterCount, 0)
        gate.open()
        try await gate.wait(timeout: nil, timeoutError: nil)
    }

    private func waitForRegistrations(_ count: Int, on gate: AsyncGate) async throws {
        let deadline = Date().addingTimeInterval(3)
        while gate.waiterCount != count && Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(gate.waiterCount, count)
    }

    func testOpenResumesEveryConcurrentWaiter() async throws {
        let gate = AsyncGate()
        let tasks = (0..<8).map { _ in Task { try await gate.wait(timeout: 5, timeoutError: noiseError("deadline")) } }
        try await waitForRegistrations(8, on: gate)
        gate.open()
        for task in tasks { try await task.value }
        XCTAssertTrue(gate.isOpen)
        XCTAssertEqual(gate.waiterCount, 0)
    }

    func testFailureResumesEveryConcurrentWaiter() async throws {
        let gate = AsyncGate()
        let tasks = (0..<8).map { _ in Task { try await gate.wait(timeout: 5, timeoutError: noiseError("deadline")) } }
        try await waitForRegistrations(8, on: gate)
        gate.fail(noiseError("shared attempt failed"))
        for task in tasks {
            do { try await task.value; XCTFail("failed attempt was admitted") }
            catch { XCTAssertEqual(error.localizedDescription, "shared attempt failed") }
        }
        XCTAssertFalse(gate.isOpen)
        XCTAssertEqual(gate.waiterCount, 0)
    }

    func testCancellingOneWaiterKeepsOtherWaiters() async throws {
        let gate = AsyncGate()
        let cancelled = Task { try await gate.wait(timeout: 5, timeoutError: noiseError("deadline")) }
        let survivor = Task { try await gate.wait(timeout: 5, timeoutError: noiseError("deadline")) }
        try await waitForRegistrations(2, on: gate)
        cancelled.cancel()
        do { try await cancelled.value; XCTFail("cancelled waiter was admitted") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(gate.waiterCount, 1)
        gate.open()
        try await survivor.value
    }

    func testWaiterTimeoutDoesNotPoisonSharedGate() async throws {
        let gate = AsyncGate()
        let survivor = Task { try await gate.wait(timeout: 5, timeoutError: noiseError("deadline")) }
        try await waitForRegistrations(1, on: gate)
        do { try await gate.wait(timeout: 0.02, timeoutError: noiseError("short deadline")); XCTFail("deadline was ignored") }
        catch { XCTAssertEqual(error.localizedDescription, "short deadline") }
        XCTAssertEqual(gate.waiterCount, 1)
        gate.open()
        try await survivor.value
        try await gate.wait(timeout: 0, timeoutError: noiseError("already opened"))
    }

    func testCancellationBeforeRegistrationDoesNotLeaveAContinuation() async throws {
        let gate = AsyncGate()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await gate.wait(timeout: 5, timeoutError: noiseError("deadline"))
        }
        do { try await task.value; XCTFail("cancelled waiter was registered") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(gate.waiterCount, 0)
        gate.open()
        try await gate.wait(timeout: 0, timeoutError: nil)
    }

    func testOptionalTimeoutLeavesGateAvailableForLaterOpen() async throws {
        let gate = AsyncGate()
        try await gate.wait(timeout: 0.001, timeoutError: nil)
        XCTAssertFalse(gate.isOpen)
        XCTAssertEqual(gate.waiterCount, 0)
        gate.open()
        try await gate.wait(timeout: 0, timeoutError: noiseError("already opened"))
    }
}
