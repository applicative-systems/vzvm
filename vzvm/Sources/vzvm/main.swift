import Foundation
import Virtualization

let version = "1.0.0"

let usage = """
  vzvm \(version)

  usage: vzvm <config.json>

  Boots a Linux VM on Apple's Virtualization.framework.

  Every setting lives in the JSON configuration file; there are no options.
  """

func fail(_ message: String, code: Int32) -> Never {
  Log.error(message)
  exit(code)
}

// One positional config path is the whole interface; anything else is a usage error.
let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 1, let configPath = arguments.first, !configPath.hasPrefix("-") else {
  print(usage)
  exit(ExitCode.usage)
}

let config: Config
do {
  config = try Config.load(path: configPath)
} catch let error as VZVMError {
  fail("\(error)", code: ExitCode.config)
} catch {
  fail("cannot read \(configPath): \(error.localizedDescription)", code: ExitCode.config)
}

let vmConfiguration: VZVirtualMachineConfiguration
do {
  try VirtualMachineBuilder.preflight(config)
  vmConfiguration = try VirtualMachineBuilder.build(config)
} catch let error as VZVMError {
  switch error {
  case .config: fail("\(error)", code: ExitCode.config)
  case .preflight: fail("\(error)", code: ExitCode.preflight)
  case .runtime: fail("\(error)", code: ExitCode.runtime)
  }
} catch {
  // VZVirtualMachineConfiguration.validate() throws NSErrors.
  fail("invalid VM configuration: \(error.localizedDescription)", code: ExitCode.config)
}

let vmQueue = DispatchQueue(label: "vzvm.vm")
let virtualMachine = VZVirtualMachine(configuration: vmConfiguration, queue: vmQueue)

/// Exits when the guest powers off, so that launchd `KeepAlive` semantics behave.
final class Delegate: NSObject, VZVirtualMachineDelegate {
  func guestDidStop(_ virtualMachine: VZVirtualMachine) {
    Log.info("guest powered off")
    Runner.shared.finish(ExitCode.ok)
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

/// Owns shutdown, so signals, guest poweroff and start failures converge on one path.
final class Runner {
  static let shared = Runner()
  private var proxies: [VsockProxy] = []
  private var terminating = false
  private let lock = NSLock()

  func adopt(_ proxy: VsockProxy) { proxies.append(proxy) }

  func finish(_ code: Int32) {
    lock.lock()
    let alreadyFinishing = terminating
    terminating = true
    lock.unlock()
    guard !alreadyFinishing else { return }
    for proxy in proxies { proxy.stop() }
    Terminal.restore()
    exit(code)
  }

  /// SIGTERM/SIGINT: ask the guest to shut down cleanly, then force it if it will not.
  func requestStop() {
    lock.lock()
    let alreadyFinishing = terminating
    lock.unlock()
    if alreadyFinishing {
      // Second signal: e.g. impatient user
      finish(ExitCode.ok)
    }
    Log.info("stopping guest")
    vmQueue.async {
      guard virtualMachine.canRequestStop else {
        Log.warn("guest cannot be asked to stop; forcing")
        self.forceStop()
        return
      }
      do {
        try virtualMachine.requestStop()
      } catch {
        Log.warn("requestStop failed: \(error.localizedDescription); forcing")
        self.forceStop()
      }
    }
    // requestStop needs working ACPI/logind in the guest; do not hang forever if it lacks it.
    DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
      Log.warn("guest did not stop within 30s; forcing")
      self.forceStop()
    }
  }

  private func forceStop() {
    vmQueue.async {
      virtualMachine.stop { _ in Runner.shared.finish(ExitCode.ok) }
    }
  }
}

/// Restores the tty on exit when the console is an interactive stdio session.
enum Terminal {
  private static var saved: termios?

  static func makeRaw() {
    guard isatty(STDIN_FILENO) == 1 else { return }
    var current = termios()
    guard tcgetattr(STDIN_FILENO, &current) == 0 else { return }
    saved = current
    var raw = current
    cfmakeraw(&raw)
    tcsetattr(STDIN_FILENO, TCSANOW, &raw)
  }

  static func restore() {
    guard var previous = saved else { return }
    tcsetattr(STDIN_FILENO, TCSANOW, &previous)
    saved = nil
  }
}

let delegate = Delegate()

// Peers vanish mid-write; that must surface as EPIPE, not SIGPIPE killing the VM (exit 141).
signal(SIGPIPE, SIG_IGN)

// Install handlers before the VM can produce events. Retained for process lifetime.
var signalSources: [DispatchSourceSignal] = []
for signalNumber in [SIGTERM, SIGINT] {
  signal(signalNumber, SIG_IGN)
  let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
  source.setEventHandler { Runner.shared.requestStop() }
  source.resume()
  signalSources.append(source)
}

if config.console.mode == "stdio" {
  Terminal.makeRaw()
}

vmQueue.async {
  virtualMachine.delegate = delegate

  if !config.vsock.forwards.isEmpty {
    guard let device = virtualMachine.socketDevices.first as? VZVirtioSocketDevice else {
      Log.error("no vsock device present")
      Runner.shared.finish(ExitCode.runtime)
      return
    }
    for forward in config.vsock.forwards {
      let proxy = VsockProxy(forward: forward, device: device, vmQueue: vmQueue)
      do {
        try proxy.start()
      } catch {
        Log.error("\(error)")
        // A malformed listen address is a config error, though it only surfaces here.
        if case VZVMError.config = error {
          Runner.shared.finish(ExitCode.config)
        } else {
          Runner.shared.finish(ExitCode.runtime)
        }
        return
      }
      Runner.shared.adopt(proxy)
    }
  }

  virtualMachine.start { result in
    switch result {
    case .success:
      Log.info("guest started")
    case .failure(let error):
      Log.error("failed to start guest: \(error.localizedDescription)")
      Runner.shared.finish(ExitCode.runtime)
    }
  }
}

dispatchMain()
