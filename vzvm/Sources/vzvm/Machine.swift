import Foundation
import Virtualization

final class Machine {
  private enum State { case stopped, starting, running, stopping }

  let queue: DispatchQueue
  private let config: Config
  /// Seconds. Kept integral: a round trip through Double traps near Int.max.
  private let idleTimeoutSeconds: Int?

  private var vm: VZVirtualMachine?
  private var state = State.stopped
  private var nextConfiguration: VZVirtualMachineConfiguration?
  private var connections = 0
  private var idleTimer: DispatchWorkItem?
  private var terminating = false
  private lazy var delegate = Delegate(machine: self)

  init(config: Config, configuration: VZVirtualMachineConfiguration, queue: DispatchQueue) {
    self.config = config
    self.nextConfiguration = configuration
    self.queue = queue
    self.idleTimeoutSeconds = config.idleTimeoutSeconds
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

  var socketDevice: VZVirtioSocketDevice? {
    dispatchPrecondition(condition: .onQueue(queue))
    guard state == .running else { return nil }
    return vm?.socketDevices.first as? VZVirtioSocketDevice
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
    queue.asyncAfter(deadline: .now() + .seconds(idleTimeoutSeconds), execute: timer)
  }

  private func boot() {
    dispatchPrecondition(condition: .onQueue(queue))
    let configuration: VZVirtualMachineConfiguration
    do {
      // stopped VZVirtualMachine not reused; boot with fresh devices
      configuration = try nextConfiguration ?? VirtualMachineBuilder.build(config)
    } catch {
      Log.error("cannot configure guest: \(error)")
      Runner.shared.finish(ExitCode.runtime)
      return
    }
    nextConfiguration = nil

    let vm = VZVirtualMachine(configuration: configuration, queue: queue)
    vm.delegate = delegate
    self.vm = vm
    state = .starting
    vm.start { result in
      switch result {
      case .success:
        guard self.vm === vm, self.state == .starting else { return }
        Log.info("guest started")
        self.state = .running
        // terminate() arrived mid-boot, when VZ cannot stop a starting guest yet.
        // The kernel is still booting and would ignore ACPI; it has served nothing, so cut it off.
        if self.terminating {
          self.state = .stopping
          Log.info("stopping guest that booted during shutdown")
          self.forceStop(vm)
          return
        }
        // The connection that woke us may have given up during boot.
        self.armIdleTimer()
      case .failure(let error):
        Log.error("failed to start guest: \(error.localizedDescription)")
        Runner.shared.finish(ExitCode.runtime)
      }
    }
  }

  func terminate() {
    queue.async {
      self.terminating = true
      self.idleTimer?.cancel()
      switch self.state {
      case .stopped: Runner.shared.finish(ExitCode.ok)
      case .stopping: break  // guestStopped() finishes once it is down
      case .starting: break  // start completion stops it once running
      case .running: self.stopGuest()
      }
    }
  }

  private func stopGuest() {
    dispatchPrecondition(condition: .onQueue(queue))
    // VZ rejects starting -> stopping, for requestStop() and stop().
    guard let vm, state == .running else { return }
    state = .stopping
    Log.info("stopping guest")
    if vm.canRequestStop {
      do {
        try vm.requestStop()
      } catch {
        Log.warn("requestStop failed: \(error.localizedDescription); forcing")
        forceStop(vm)
      }
    } else {
      Log.warn("guest cannot be asked to stop; forcing")
      forceStop(vm)
    }
    pressPowerButtonAgain(vm, after: 2)
    // requestStop requires ACPI/logind in guest
    queue.asyncAfter(deadline: .now() + 30) { [weak self] in
      guard let self, self.vm === vm else { return }
      Log.warn("guest did not stop within 30s; forcing")
      self.forceStop(vm)
    }
  }

  /// booting guest drops ACPI signal: logind is not up yet.
  /// Repeat until it is, harmless once shutdown is under way.
  private func pressPowerButtonAgain(_ vm: VZVirtualMachine, after seconds: Int) {
    queue.asyncAfter(deadline: .now() + .seconds(seconds)) { [weak self] in
      guard let self, self.vm === vm, self.state == .stopping, vm.canRequestStop else { return }
      try? vm.requestStop()
      self.pressPowerButtonAgain(vm, after: seconds)
    }
  }

  private func forceStop(_ vm: VZVirtualMachine) {
    vm.stop { error in
      guard let error else {
        self.guestStopped(vm)
        return
      }
      Log.error("cannot stop guest: \(error.localizedDescription)")
      Runner.shared.finish(ExitCode.runtime)
    }
  }

  fileprivate func guestStopped(_ stopped: VZVirtualMachine) {
    dispatchPrecondition(condition: .onQueue(queue))
    guard vm === stopped else { return }
    vm = nil
    state = .stopped
    idleTimer?.cancel()
    idleTimer = nil
    guard onDemand && !terminating else {
      Runner.shared.finish(ExitCode.ok)
      return
    }
    if connections > 0 {
      Log.info("guest stopped with connections waiting; booting again")
      boot()
    } else {
      Log.info("guest stopped; next connection boots it again")
    }
  }

  private final class Delegate: NSObject, VZVirtualMachineDelegate {
    private unowned let machine: Machine

    init(machine: Machine) { self.machine = machine }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
      Log.info("guest powered off")
      machine.guestStopped(virtualMachine)
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
      Log.error("guest stopped: \(error.localizedDescription)")
      Runner.shared.finish(ExitCode.guestError)
    }

    func virtualMachine(
      _ virtualMachine: VZVirtualMachine,
      networkDevice: VZNetworkDevice,
      attachmentWasDisconnectedWithError error: Error
    ) {
      Log.warn("network detached: \(error.localizedDescription)")
    }
  }
}
