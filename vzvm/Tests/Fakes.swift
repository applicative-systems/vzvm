import Foundation
import Virtualization
import XCTest

struct FakeError: Error {}

/// Records what Machine asks of it; the test decides when and how each call completes.
final class FakeGuest: Guest {
  var canRequestStop = true
  var requestStopError: Error?
  var onStop: ((Error?) -> Void)?
  private(set) var connectedPorts: [UInt32] = []

  private(set) var startCompletion: ((Result<Void, Error>) -> Void)?
  private(set) var stopCompletion: ((Error?) -> Void)?
  private(set) var stopRequests = 0
  private(set) var forcedStops = 0

  func start(completionHandler: @escaping (Result<Void, Error>) -> Void) {
    startCompletion = completionHandler
  }

  func requestStop() throws {
    stopRequests += 1
    if let requestStopError { throw requestStopError }
  }

  func stop(completionHandler: @escaping (Error?) -> Void) {
    forcedStops += 1
    stopCompletion = completionHandler
  }

  /// Records the port; the proxy tests cover what happens to a connection.
  func connect(
    toPort port: UInt32, completionHandler: @escaping (Result<VsockConnection, Error>) -> Void
  ) {
    connectedPorts.append(port)
    completionHandler(.failure(FakeError()))
  }
}

/// Virtual time: nothing runs until the test advances it. Thread-safe, since the proxy
/// schedules its retries from its own queues.
final class ManualScheduler: Scheduler {
  private let lock = NSLock()
  private var now = 0
  private var pending: [(due: Int, work: DispatchWorkItem)] = []

  func schedule(after delay: DispatchTimeInterval, _ work: DispatchWorkItem) {
    lock.withLock { pending.append((now + delay.nanoseconds, work)) }
  }

  var pendingCount: Int { lock.withLock { pending.filter { !$0.work.isCancelled }.count } }

  /// Runs everything due by then in order, including work scheduled while advancing.
  func advance(by delay: DispatchTimeInterval) {
    let target = lock.withLock { now + delay.nanoseconds }
    while let work = nextDue(by: target) {
      if !work.isCancelled { work.perform() }
    }
    lock.withLock { now = target }
  }

  /// Unlocked while the work runs: it may schedule more.
  private func nextDue(by target: Int) -> DispatchWorkItem? {
    lock.withLock {
      guard
        let next = pending.indices.filter({ pending[$0].due <= target })
          .min(by: { pending[$0].due < pending[$1].due })
      else { return nil }
      let (due, work) = pending.remove(at: next)
      now = due
      return work
    }
  }
}

extension DispatchTimeInterval {
  var nanoseconds: Int {
    switch self {
    case .seconds(let s): return s * 1_000_000_000
    case .milliseconds(let ms): return ms * 1_000_000
    case .microseconds(let us): return us * 1_000
    case .nanoseconds(let ns): return ns
    case .never: return .max / 2  // leaves room to add the current time
    @unknown default: fatalError("unknown DispatchTimeInterval \(self)")
    }
  }
}

/// A Machine wired to fakes. Every step runs synchronously on the machine's queue, so a
/// test reads as a sequence of events with no waiting.
final class Harness {
  let queue = DispatchQueue(label: "vzvm.test.machine")
  let clock = ManualScheduler()
  private(set) var guests: [FakeGuest] = []
  private(set) var exitCodes: [Int32] = []
  var configureError: Error?
  private(set) var machine: Machine!

  init(idleTimeoutSeconds: Int?) {
    machine = Machine(
      idleTimeoutSeconds: idleTimeoutSeconds,
      queue: queue,
      scheduler: clock,
      makeGuest: { [unowned self] in
        if let configureError { throw configureError }
        let guest = FakeGuest()
        guests.append(guest)
        return guest
      },
      finish: { [unowned self] in exitCodes.append($0) })
  }

  /// The guest of the latest boot. Without one, a detached fake: assertions on it fail
  /// instead of crashing the whole run.
  var guest: FakeGuest { guests.last ?? FakeGuest() }

  /// Machine's public calls hop onto its queue; wait for them to land.
  func settle() { queue.sync {} }

  func launch() {
    machine.launch()
    settle()
  }
  func open() {
    machine.connectionOpened()
    settle()
  }
  func close() {
    machine.connectionClosed()
    settle()
  }
  func terminate() {
    machine.terminate()
    settle()
  }
  func advance(_ seconds: Int) { queue.sync { clock.advance(by: .seconds(seconds)) } }

  /// What the proxy would get, asked on the machine's queue as it must be.
  func connect(toPort port: UInt32) -> Result<VsockConnection, Error>? {
    var result: Result<VsockConnection, Error>?
    queue.sync { machine.connect(toPort: port) { result = $0 } }
    return result
  }

  func started() { complete(guest.startCompletion, "start") { $0(.success(())) } }
  func failedToStart() { complete(guest.startCompletion, "start") { $0(.failure(FakeError())) } }
  func poweredOff() { complete(guest.onStop, "onStop") { $0(nil) } }
  func crashed() { complete(guest.onStop, "onStop") { $0(FakeError()) } }
  func forceStopCompleted(_ error: Error? = nil) {
    complete(guest.stopCompletion, "stop") { $0(error) }
  }

  /// Fails the test rather than crashing the run when Machine never made the call.
  private func complete<Handler>(
    _ handler: Handler?, _ call: String, file: StaticString = #filePath, line: UInt = #line,
    _ body: (Handler) -> Void
  ) {
    guard let handler else {
      return XCTFail("Machine never called \(call)", file: file, line: line)
    }
    queue.sync { body(handler) }
  }

  /// The usual starting point: an on-demand guest booted by one connection, now idle.
  func runningIdle() {
    launch()
    open()
    started()
    close()
  }
}
