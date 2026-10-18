import Foundation
import Virtualization

/// What Machine needs from a running guest. VZVirtualMachine in production, a fake in tests.
protocol Guest: AnyObject {
  var canRequestStop: Bool { get }
  var socketDevice: VZVirtioSocketDevice? { get }
  /// Called on Machine's queue when the guest stops on its own: nil for a clean poweroff.
  var onStop: ((Error?) -> Void)? { get set }

  func start(completionHandler: @escaping (Result<Void, Error>) -> Void)
  /// ACPI power button. Needs a guest that listens, e.g. logind.
  func requestStop() throws
  /// Pulls the plug.
  func stop(completionHandler: @escaping (Error?) -> Void)
}

/// Delayed work for Machine's timers. Tests substitute a clock they advance by hand.
protocol Scheduler {
  /// `work` may be cancelled before it is due; it must not run then.
  func schedule(after seconds: Int, _ work: DispatchWorkItem)
}

struct QueueScheduler: Scheduler {
  let queue: DispatchQueue

  func schedule(after seconds: Int, _ work: DispatchWorkItem) {
    queue.asyncAfter(deadline: .now() + .seconds(seconds), execute: work)
  }
}

final class VZGuest: NSObject, Guest, VZVirtualMachineDelegate {
  private let vm: VZVirtualMachine
  var onStop: ((Error?) -> Void)?

  init(configuration: VZVirtualMachineConfiguration, queue: DispatchQueue) {
    vm = VZVirtualMachine(configuration: configuration, queue: queue)
    super.init()
    // Weak reference: Machine keeps this object, and with it the VM, alive.
    vm.delegate = self
  }

  var canRequestStop: Bool { vm.canRequestStop }
  var socketDevice: VZVirtioSocketDevice? { vm.socketDevices.first as? VZVirtioSocketDevice }

  func start(completionHandler: @escaping (Result<Void, Error>) -> Void) {
    vm.start(completionHandler: completionHandler)
  }

  func requestStop() throws { try vm.requestStop() }

  func stop(completionHandler: @escaping (Error?) -> Void) {
    vm.stop(completionHandler: completionHandler)
  }

  func guestDidStop(_ virtualMachine: VZVirtualMachine) { onStop?(nil) }

  func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
    onStop?(error)
  }

  func virtualMachine(
    _ virtualMachine: VZVirtualMachine,
    networkDevice: VZNetworkDevice,
    attachmentWasDisconnectedWithError error: Error
  ) {
    Log.warn("network detached: \(error.localizedDescription)")
  }
}
