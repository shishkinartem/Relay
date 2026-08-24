import Foundation

/// A one-shot resume, for a race between real work and a deadline.
///
/// Whichever of the two finishes first opens the gate; the second finds it
/// already open and does nothing. `attach` handles the case where the gate was
/// opened before the waiter reached it, which is the ordinary outcome when the
/// work is fast.
public final class DeadlineGate: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Void, Never>?
  private var opened = false

  public init() {}

  public func attach(_ continuation: CheckedContinuation<Void, Never>) {
    lock.lock()
    if opened {
      lock.unlock()
      continuation.resume()
      return
    }
    self.continuation = continuation
    lock.unlock()
  }

  public func open() {
    lock.lock()
    guard !opened else {
      lock.unlock()
      return
    }
    opened = true
    let waiting = continuation
    continuation = nil
    lock.unlock()
    waiting?.resume()
  }
}

/// Bounded waits for work that has no cancellation contract.
public enum Deadline {
  /// Runs `work`, returning once it finishes or `seconds` have passed.
  ///
  /// The work runs **detached**, because abandoning it has to really abandon
  /// it. Racing it against a sleeper inside a `withTaskGroup` does not: a task
  /// group awaits every child before it returns, and `cancelAll()` only sets a
  /// flag that a completion-handler-bridged call never reads — so the helper
  /// waits out the whole of the hang it was written to escape. That version
  /// shipped, and this test suite is what would have caught it.
  ///
  /// The abandoned work is not cancelled. The caller here is capture teardown,
  /// where the system call being waited on has no cancellation contract and
  /// letting it land late into an object that has already torn down is safer
  /// than interrupting it mid-flight.
  public static func run(
    seconds: Double, _ work: @escaping @Sendable () async -> Void
  ) async {
    let gate = DeadlineGate()
    Task.detached {
      await work()
      gate.open()
    }
    let timer = Task.detached {
      try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
      gate.open()
    }
    await withCheckedContinuation { gate.attach($0) }
    timer.cancel()
  }
}
