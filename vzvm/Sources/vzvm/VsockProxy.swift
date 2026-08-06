import Foundation
import Virtualization

/// Splices loopback TCP or unix-socket connections into guest vsock, so inbound SSH (or the
/// Nix daemon protocol) needs no guest IP.
final class VsockProxy {
  private let forward: Config.Vsock.Forward
  private let queue: DispatchQueue
  private let vmQueue: DispatchQueue
  private weak var device: VZVirtioSocketDevice?

  private var listenFD: Int32 = -1
  private var socketPath: String?
  private var acceptSource: DispatchSourceRead?
  /// Bridges keep themselves alive until both directions finish.
  private var bridges: Set<Bridge> = []
  private let lock = NSLock()

  init(forward: Config.Vsock.Forward, device: VZVirtioSocketDevice, vmQueue: DispatchQueue) {
    self.forward = forward
    self.device = device
    self.vmQueue = vmQueue
    self.queue = DispatchQueue(label: "vzvm.proxy.\(forward.vsockPort)")
  }

  func start() throws {
    let fd: Int32
    switch forward.kind {
    case .tcp(let address): fd = try bindTCP(address)
    case .unix(let path): fd = try bindUnix(path)
    }

    // Nix opens connections in bursts. an overflowing backlog fails them instantly.
    guard listen(fd, Int32(SOMAXCONN)) == 0 else {
      let reason = String(cString: strerror(errno))
      close(fd)
      throw VZVMError.runtime("listen(): \(reason)")
    }

    listenFD = fd
    let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
    source.setEventHandler { [weak self] in self?.acceptOne() }
    source.setCancelHandler { close(fd) }
    acceptSource = source
    source.resume()

    Log.info("forwarding \(forward.label) -> vsock:\(forward.vsockPort)")
  }

  private func bindTCP(_ address: String) throws -> Int32 {
    let (host, port) = try Self.parse(listen: address)

    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else {
      throw VZVMError.runtime("socket(): \(String(cString: strerror(errno)))")
    }

    var yes: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else {
      close(fd)
      throw VZVMError.config("invalid listen address '\(address)'")
    }

    func tryBind() -> Int32 {
      withUnsafePointer(to: &addr) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
          Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
      }
    }

    // Wait out the previous instance's shutdown. exiting here would crash-loop under launchd.
    var bound = tryBind()
    if bound != 0 && errno == EADDRINUSE {
      Log.info("waiting for \(address) (previous instance still shutting down)")
      let deadline = Date(timeIntervalSinceNow: 60)
      while bound != 0 && errno == EADDRINUSE && Date() < deadline {
        usleep(500_000)
        bound = tryBind()
      }
    }
    guard bound == 0 else {
      let reason = String(cString: strerror(errno))
      close(fd)
      throw VZVMError.runtime(
        """
        cannot listen on \(address): \(reason)\
        \(errno == EADDRINUSE ? " (another builder VM is probably already running)" : "")
        """)
    }
    return fd
  }

  private func bindUnix(_ path: String) throws -> Int32 {
    // sun_path is 104 bytes including the terminating NUL on Darwin.
    guard path.utf8.count <= 103 else {
      throw VZVMError.config("listenSocket path '\(path)' exceeds 103 bytes")
    }
    // The parent may live on tmpfs (/var/run) and not exist after a reboot.
    try? FileManager.default.createDirectory(
      atPath: (path as NSString).deletingLastPathComponent,
      withIntermediateDirectories: true)

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
      throw VZVMError.runtime("socket(): \(String(cString: strerror(errno)))")
    }

    var addr = Self.unixAddr(path)
    func tryBind() -> Int32 {
      withUnsafePointer(to: &addr) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
          Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
      }
    }

    // A socket file left by a crashed instance would EADDRINUSE forever; a live predecessor
    // deserves the same shutdown grace as the TCP path. connect() tells the two apart.
    var bound = tryBind()
    if bound != 0 && errno == EADDRINUSE {
      var waiting = false
      let deadline = Date(timeIntervalSinceNow: 60)
      while bound != 0 && errno == EADDRINUSE && Date() < deadline {
        if Self.isLive(path: path) {
          if !waiting {
            waiting = true
            Log.info("waiting for \(path) (previous instance still shutting down)")
          }
          usleep(500_000)
        } else {
          unlink(path)
        }
        bound = tryBind()
      }
    }
    guard bound == 0 else {
      let reason = String(cString: strerror(errno))
      close(fd)
      throw VZVMError.runtime(
        """
        cannot listen on \(path): \(reason)\
        \(errno == EADDRINUSE ? " (another builder VM is probably already running)" : "")
        """)
    }

    // Connecting requires write permission, so restrict to the owner. No umask juggling:
    // even before this chmod the default 0755 socket denies connect() to everyone else.
    chmod(path, 0o600)
    socketPath = path
    return fd
  }

  /// Is something accepting on the socket path, or is it a stale leftover?
  private static func isLive(path: String) -> Bool {
    let probe = socket(AF_UNIX, SOCK_STREAM, 0)
    guard probe >= 0 else { return true }  // cannot tell; err on waiting
    defer { close(probe) }
    var addr = unixAddr(path)
    let connected = withUnsafePointer(to: &addr) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
        Darwin.connect(probe, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    return connected == 0
  }

  private static func unixAddr(_ path: String) -> sockaddr_un {
    var addr = sockaddr_un()
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
      for (index, byte) in bytes.enumerated() { buffer[index] = byte }
    }
    return addr
  }

  func stop() {
    acceptSource?.cancel()
    acceptSource = nil
    listenFD = -1
    // Crashes skip this; the stale-socket probe in bindUnix covers those.
    if let socketPath { unlink(socketPath) }
    lock.lock()
    let current = bridges
    bridges.removeAll()
    lock.unlock()
    for bridge in current { bridge.close() }
  }

  private func acceptOne() {
    let client = accept(listenFD, nil, nil)
    guard client >= 0 else {
      // EMFILE here is how a descriptor leak announces itself. never fail silently.
      Log.warn("accept on \(forward.label): \(String(cString: strerror(errno)))")
      return
    }

    if case .tcp = forward.kind {
      // Keep latency out of the guest's way. SSH is interactive. (ENOPROTOOPT on AF_UNIX.)
      var yes: Int32 = 1
      setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &yes, socklen_t(MemoryLayout<Int32>.size))
    }

    connect(client: client, attempt: 0)
  }

  /// Holds the client and retries while the guest boots. one refusal makes Nix drop the builder.
  private func connect(client: Int32, attempt: Int) {
    guard let device else {
      Log.warn("vsock device gone. dropping connection on \(forward.label)")
      close(client)
      return
    }
    let port = forward.vsockPort

    // VZVirtioSocketDevice must be touched on the VM's queue.
    vmQueue.async {
      device.connect(toPort: port) { [weak self] result in
        guard let self else {
          close(client)
          return
        }
        switch result {
        case .success(let connection):
          self.bridge(client: client, connection: connection)
        case .failure(let error):
          guard attempt < 60 else {
            Log.warn("vsock:\(port) connect failed: \(error.localizedDescription). giving up")
            close(client)
            return
          }
          if attempt == 0 {
            Log.info("vsock:\(port) not ready. holding connection until the guest is up")
          }
          self.queue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.connect(client: client, attempt: attempt + 1)
          }
        }
      }
    }
  }

  private func bridge(client: Int32, connection: VZVirtioSocketConnection) {
    let bridge = Bridge(tcpFD: client, connection: connection, vmQueue: vmQueue) {
      [weak self] finished in
      guard let self else { return }
      self.lock.lock()
      self.bridges.remove(finished)
      self.lock.unlock()
    }
    lock.lock()
    bridges.insert(bridge)
    lock.unlock()
    bridge.start()
  }

  static func parse(listen: String) throws -> (host: String, port: UInt16) {
    guard let separator = listen.lastIndex(of: ":") else {
      throw VZVMError.config("listen address '\(listen)' must be host:port")
    }
    let host = String(listen[listen.startIndex..<separator])
    guard let port = UInt16(listen[listen.index(after: separator)...]), port > 0 else {
      throw VZVMError.config("listen address '\(listen)' has an invalid port")
    }
    return (host.isEmpty ? "127.0.0.1" : host, port)
  }
}

/// Splices a TCP socket and a vsock connection together in both directions.
private final class Bridge: Hashable {
  private let tcpFD: Int32
  /// Retained: the connection owns its file descriptor and closes it on `close()`.
  private let connection: VZVirtioSocketConnection
  private let vsockFD: Int32
  private let queue = DispatchQueue(label: "vzvm.bridge")
  /// Virtualization.framework objects tolerate no other queue.
  private let vmQueue: DispatchQueue
  private let onFinish: (Bridge) -> Void
  private var closed = false
  private var tcpIO: DispatchIO?
  private var vsockIO: DispatchIO?

  init(
    tcpFD: Int32, connection: VZVirtioSocketConnection, vmQueue: DispatchQueue,
    onFinish: @escaping (Bridge) -> Void
  ) {
    self.tcpFD = tcpFD
    self.connection = connection
    self.vmQueue = vmQueue
    // dup() so DispatchIO cannot double-close the descriptor the connection owns.
    self.vsockFD = dup(connection.fileDescriptor)
    self.onFinish = onFinish
  }

  func start() {
    guard vsockFD >= 0 else {
      close()
      return
    }
    let tcp = DispatchIO(type: .stream, fileDescriptor: tcpFD, queue: queue) { _ in
      Darwin.close(self.tcpFD)
    }
    let vsock = DispatchIO(type: .stream, fileDescriptor: vsockFD, queue: queue) { _ in
      Darwin.close(self.vsockFD)
    }
    // Forward bytes as soon as they arrive rather than waiting to fill a buffer.
    tcp.setLimit(lowWater: 1)
    vsock.setLimit(lowWater: 1)
    tcpIO = tcp
    vsockIO = vsock
    pump(from: tcp, to: vsock, sinkFD: vsockFD)
    pump(from: vsock, to: tcp, sinkFD: tcpFD)
  }

  private func pump(from source: DispatchIO, to sink: DispatchIO, sinkFD: Int32) {
    source.read(offset: 0, length: Int.max, queue: queue) { [weak self] done, data, error in
      guard let self else { return }
      if let data, !data.isEmpty {
        sink.write(offset: 0, data: data, queue: self.queue) { [weak self] _, _, writeError in
          if writeError != 0 { self?.close() }
        }
      }
      if done || error != 0 {
        // Full teardown: a half-close is not translated to virtio, so the guest leaks sshd.
        sink.barrier { [weak self] in self?.close() }
      }
    }
  }

  func close() {
    queue.async {
      guard !self.closed else { return }
      self.closed = true
      self.tcpIO?.close(flags: .stop)
      self.vsockIO?.close(flags: .stop)
      self.vmQueue.async { self.connection.close() }
      self.onFinish(self)
    }
  }

  static func == (lhs: Bridge, rhs: Bridge) -> Bool { lhs === rhs }
  func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}
