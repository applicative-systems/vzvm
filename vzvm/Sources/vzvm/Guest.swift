import Foundation
import Virtualization

/// One stream into the guest. VZVirtioSocketConnection in production, a socketpair in tests.
protocol VsockConnection: AnyObject {
  /// Owned by the connection: dup() it to hand it to anything that closes.
  var fileDescriptor: Int32 { get }
  func close()
}

extension VZVirtioSocketConnection: VsockConnection {}

/// What Machine needs from a running guest. VZVirtualMachine in production, a fake in tests.
protocol Guest: AnyObject {
  var canRequestStop: Bool { get }
  /// Called on Machine's queue when the guest stops on its own: nil for a clean poweroff.
  var onStop: ((Error?) -> Void)? { get set }

  func start(completionHandler: @escaping (Result<Void, Error>) -> Void)
  /// ACPI power button. Needs a guest that listens, e.g. logind.
  func requestStop() throws
  /// Pulls the plug.
  func stop(completionHandler: @escaping (Error?) -> Void)
  /// Fails while nothing in the guest listens on `port`, e.g. during boot.
  func connect(
    toPort port: UInt32, completionHandler: @escaping (Result<VsockConnection, Error>) -> Void)
}

/// Delayed work for timers and retries. Tests substitute a clock they advance by hand.
protocol Scheduler {
  /// `work` may be cancelled before it is due; it must not run then.
  func schedule(after delay: DispatchTimeInterval, _ work: DispatchWorkItem)
}

struct QueueScheduler: Scheduler {
  let queue: DispatchQueue

  func schedule(after delay: DispatchTimeInterval, _ work: DispatchWorkItem) {
    queue.asyncAfter(deadline: .now() + delay, execute: work)
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

  func start(completionHandler: @escaping (Result<Void, Error>) -> Void) {
    vm.start(completionHandler: completionHandler)
  }

  func requestStop() throws { try vm.requestStop() }

  func stop(completionHandler: @escaping (Error?) -> Void) {
    vm.stop(completionHandler: completionHandler)
  }

  func connect(
    toPort port: UInt32, completionHandler: @escaping (Result<VsockConnection, Error>) -> Void
  ) {
    guard let device = vm.socketDevices.first as? VZVirtioSocketDevice else {
      return completionHandler(.failure(VZVMError.runtime("guest has no vsock device")))
    }
    device.connect(toPort: port) { completionHandler($0.map { $0 }) }
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
