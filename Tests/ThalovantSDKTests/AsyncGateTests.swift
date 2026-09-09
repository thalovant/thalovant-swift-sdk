import Foundation
import XCTest
@testable import ThalovantSDK

final class AsyncGateTests: XCTestCase {
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
