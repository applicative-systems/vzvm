import Foundation
import Virtualization

let version = "1.1.0"

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
// The validated configuration serves the first boot; later on-demand boots build their own.
var firstConfiguration: VZVirtualMachineConfiguration? = vmConfiguration
let machine = Machine(
  idleTimeoutSeconds: config.idleTimeoutSeconds,
  queue: vmQueue,
  makeGuest: {
    let configuration = try firstConfiguration ?? VirtualMachineBuilder.build(config)
    firstConfiguration = nil
    return VZGuest(configuration: configuration, queue: vmQueue)
  },
  finish: { Runner.shared.finish($0) })

/// Owns process exit, so signals, guest poweroff and start failures converge on one path.
final class Runner {
  static let shared = Runner()
  private var proxies: [VsockProxy] = []
  private var terminating = false
  private var stopRequested = false
  private let lock = NSLock()

  /// Proxies start off the main queue, so a signal may finish() concurrently.
  func adopt(_ proxy: VsockProxy) {
    lock.lock()
    proxies.append(proxy)
    lock.unlock()
  }

  func finish(_ code: Int32) {
    lock.lock()
    let alreadyFinishing = terminating
    terminating = true
    let current = proxies
    lock.unlock()
    guard !alreadyFinishing else { return }
    for proxy in current { proxy.stop() }
    Terminal.restore()
    exit(code)
  }

  /// SIGTERM/SIGINT: ask the guest to shut down cleanly; a second signal exits at once.
  func requestStop() {
    lock.lock()
    let alreadyStopping = stopRequested
    stopRequested = true
    lock.unlock()
    if alreadyStopping {
      // Second signal: e.g. impatient user
      finish(ExitCode.ok)
    }
    machine.terminate()
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

// Off the main queue: binding may wait out a previous instance for up to 60s, and the
// signal handlers above must still run meanwhile.
DispatchQueue.global().async {
  // Listeners come up before the guest: in on-demand mode a connection is what boots it.
  for forward in config.vsock.forwards {
    let proxy = VsockProxy(forward: forward, backend: machine)
    do {
      try proxy.start()
    } catch {
      Log.error("\(error)")
      // malformed listen address is a config error but only surfaces here.
      if case VZVMError.config = error {
        Runner.shared.finish(ExitCode.config)
      } else {
        Runner.shared.finish(ExitCode.runtime)
      }
    }
    Runner.shared.adopt(proxy)
  }

  machine.launch()
}

dispatchMain()
