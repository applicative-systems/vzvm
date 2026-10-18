import Foundation
import Virtualization
import XCTest

struct FakeError: Error {}

/// Records what Machine asks of it; the test decides when and how each call completes.
final class FakeGuest: Guest {
  var canRequestStop = true
  var requestStopError: Error?
  var socketDevice: VZVirtioSocketDevice? { nil }
  var onStop: ((Error?) -> Void)?

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
}

/// Virtual time: nothing runs until the test advances it.
final class ManualScheduler: Scheduler {
  private var now = 0
  private var pending: [(due: Int, work: DispatchWorkItem)] = []

  func schedule(after seconds: Int, _ work: DispatchWorkItem) {
    pending.append((now + seconds, work))
  }

  /// Runs everything due by then in order, including work scheduled while advancing.
  func advance(by seconds: Int) {
    let target = now + seconds
    while let next = pending.indices.filter({ pending[$0].due <= target })
      .min(by: { pending[$0].due < pending[$1].due })
    {
      let (due, work) = pending.remove(at: next)
      now = due
      if !work.isCancelled { work.perform() }
    }
    now = target
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
  func advance(_ seconds: Int) { queue.sync { clock.advance(by: seconds) } }

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
