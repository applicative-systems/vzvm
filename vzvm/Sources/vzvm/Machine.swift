import Foundation
import Virtualization

final class Machine {
  private enum State { case stopped, starting, running, stopping }

  /// Requested stops that the guest has not honoured by then are forced.
  static let stopGraceSeconds = 30
  /// Interval at which the ACPI power button is pressed again while stopping.
  static let powerButtonIntervalSeconds = 2

  let queue: DispatchQueue
  /// Seconds. Kept integral: a round trip through Double traps near Int.max.
  private let idleTimeoutSeconds: Int?
  private let scheduler: Scheduler
  /// Builds a fresh guest per boot: a stopped VZVirtualMachine cannot be started again.
  private let makeGuest: () throws -> Guest
  /// Ends the process with an exit code; vzvm has nothing left to do afterwards.
  private let finish: (Int32) -> Void

  private var guest: Guest?
  private var state = State.stopped
  private var connections = 0
  private var idleTimer: DispatchWorkItem?
  private var terminating = false

  init(
    idleTimeoutSeconds: Int?,
    queue: DispatchQueue,
    scheduler: Scheduler? = nil,
    makeGuest: @escaping () throws -> Guest,
    finish: @escaping (Int32) -> Void
  ) {
    self.idleTimeoutSeconds = idleTimeoutSeconds
    self.queue = queue
    self.scheduler = scheduler ?? QueueScheduler(queue: queue)
    self.makeGuest = makeGuest
    self.finish = finish
  }

  private var onDemand: Bool { idleTimeoutSeconds != nil }

  func launch() {
    queue.async {
      if let idleTimeoutSeconds = self.idleTimeoutSeconds {
        Log.info(
          "on demand: guest boots on first connection, stops after \(idleTimeoutSeconds)s idle")
      } else {
        self.boot()
      }
    }
  }

  func connect(
    toPort port: UInt32, completionHandler: @escaping (Result<VsockConnection, Error>) -> Void
  ) {
    dispatchPrecondition(condition: .onQueue(queue))
    guard state == .running, let guest else {
      return completionHandler(.failure(VZVMError.runtime("guest is not running")))
    }
    guest.connect(toPort: port, completionHandler: completionHandler)
  }

  func connectionOpened() {
    queue.async {
      self.connections += 1
      self.idleTimer?.cancel()
      self.idleTimer = nil
      if self.onDemand && self.state == .stopped && !self.terminating {
        Log.info("incoming connection; booting guest")
        self.boot()
      }
    }
  }

  func connectionClosed() {
    queue.async {
      self.connections -= 1
      if self.connections == 0 { self.armIdleTimer() }
    }
  }

  private func armIdleTimer() {
    guard let idleTimeoutSeconds, state == .running, connections == 0 else { return }
    idleTimer?.cancel()
    let timer = DispatchWorkItem { [weak self] in
      guard let self, self.connections == 0, self.state == .running else { return }
      Log.info("no connections for \(idleTimeoutSeconds)s; stopping guest")
      self.stopGuest()
    }
    idleTimer = timer
    scheduler.schedule(after: .seconds(idleTimeoutSeconds), timer)
  }

  private func boot() {
    dispatchPrecondition(condition: .onQueue(queue))
    let guest: Guest
    do {
      guest = try makeGuest()
    } catch {
      Log.error("cannot configure guest: \(error)")
      finish(ExitCode.runtime)
      return
    }
    guest.onStop = { [weak self, unowned guest] error in
      guard let self else { return }
      if let error {
        Log.error("guest stopped: \(error.localizedDescription)")
        self.finish(ExitCode.guestError)
      } else {
        Log.info("guest powered off")
        self.guestStopped(guest)
      }
    }
    self.guest = guest
    state = .starting
    guest.start { result in
      switch result {
      case .success:
        guard self.guest === guest, self.state == .starting else { return }
        Log.info("guest started")
        self.state = .running
        // terminate() arrived mid-boot, when VZ cannot stop a starting guest yet.
        // The kernel is still booting and would ignore ACPI; it has served nothing, so cut it off.
        if self.terminating {
          self.state = .stopping
          Log.info("stopping guest that booted during shutdown")
          self.forceStop(guest)
          return
        }
        // The connection that woke us may have given up during boot.
        self.armIdleTimer()
      case .failure(let error):
        Log.error("failed to start guest: \(error.localizedDescription)")
        self.finish(ExitCode.runtime)
      }
    }
  }

  func terminate() {
    queue.async {
      self.terminating = true
      self.idleTimer?.cancel()
      switch self.state {
      case .stopped: self.finish(ExitCode.ok)
      case .stopping: break  // guestStopped() finishes once it is down
      case .starting: break  // start completion stops it once running
      case .running: self.stopGuest()
      }
    }
  }

  private func stopGuest() {
    dispatchPrecondition(condition: .onQueue(queue))
    // VZ rejects starting -> stopping, for requestStop() and stop().
    guard let guest, state == .running else { return }
    state = .stopping
    Log.info("stopping guest")
    if guest.canRequestStop {
      do {
        try guest.requestStop()
      } catch {
        Log.warn("requestStop failed: \(error.localizedDescription); forcing")
        forceStop(guest)
      }
    } else {
      Log.warn("guest cannot be asked to stop; forcing")
      forceStop(guest)
    }
    pressPowerButtonAgain(guest)
    // requestStop requires ACPI/logind in guest
    scheduler.schedule(
      after: .seconds(Self.stopGraceSeconds),
      DispatchWorkItem { [weak self] in
        guard let self, self.guest === guest else { return }
        Log.warn("guest did not stop within \(Self.stopGraceSeconds)s; forcing")
        self.forceStop(guest)
      })
  }

  /// booting guest drops ACPI signal: logind is not up yet.
  /// Repeat until it is, harmless once shutdown is under way.
  private func pressPowerButtonAgain(_ guest: Guest) {
    scheduler.schedule(
      after: .seconds(Self.powerButtonIntervalSeconds),
      DispatchWorkItem { [weak self] in
        guard let self, self.guest === guest, self.state == .stopping, guest.canRequestStop
        else { return }
        try? guest.requestStop()
        self.pressPowerButtonAgain(guest)
      })
  }

  private func forceStop(_ guest: Guest) {
    guest.stop { error in
      guard let error else {
        self.guestStopped(guest)
        return
      }
      Log.error("cannot stop guest: \(error.localizedDescription)")
      self.finish(ExitCode.runtime)
    }
  }

  private func guestStopped(_ stopped: Guest) {
    dispatchPrecondition(condition: .onQueue(queue))
    guard guest === stopped else { return }
    guest = nil
    state = .stopped
    idleTimer?.cancel()
    idleTimer = nil
    guard onDemand && !terminating else {
      finish(ExitCode.ok)
      return
    }
    if connections > 0 {
      Log.info("guest stopped with connections waiting; booting again")
      boot()
    } else {
      Log.info("guest stopped; next connection boots it again")
    }
  }
}
