import Foundation
import Virtualization

/// Production: Machine, tests: fake
protocol VsockBackend: AnyObject {
  var queue: DispatchQueue { get }
  func connectionOpened()
  func connectionClosed()
  func connect(
    toPort port: UInt32, completionHandler: @escaping (Result<VsockConnection, Error>) -> Void)
}

extension Machine: VsockBackend {}

/// Splices loopback TCP connections into guest vsock, so inbound SSH needs no guest IP.
final class VsockProxy {
  /// Polling: VZ never says when the guest starts listening on a vsock port; only a failed
  /// connect does.
  static let retryInterval = DispatchTimeInterval.milliseconds(1500)
  static let maxRetries = 60

  private let forward: Config.Vsock.Forward
  private let queue: DispatchQueue
  /// The guest behind it comes and goes with on-demand boots.
  private let backend: VsockBackend
  private let scheduler: Scheduler
  private var vmQueue: DispatchQueue { backend.queue }

  private var listenFD: Int32 = -1
  private var acceptSource: DispatchSourceRead?
  /// Bridges keep themselves alive until both directions finish.
  private var bridges: Set<Bridge> = []
  private let lock = NSLock()

  init(forward: Config.Vsock.Forward, backend: VsockBackend, scheduler: Scheduler? = nil) {
    self.forward = forward
    self.backend = backend
    let queue = DispatchQueue(label: "vzvm.proxy.\(forward.vsockPort)")
    self.queue = queue
    self.scheduler = scheduler ?? QueueScheduler(queue: queue)
  }

  func start() throws {
    let (host, port) = try Self.parse(listen: forward.listen)

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
      throw VZVMError.config("invalid listen address '\(forward.listen)'")
    }

    /// 0 or the errno, captured at once: logging, sleeping, even Date() overwrite errno.
    func tryBind() -> Int32 {
      let result = withUnsafePointer(to: &addr) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
          Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
      }
      return result == 0 ? 0 : errno
    }

    // Wait out the previous instance's shutdown. exiting here would crash-loop under launchd.
    var bindError = tryBind()
    if bindError == EADDRINUSE {
      Log.info("waiting for \(forward.listen) (previous instance still shutting down)")
      let deadline = Date(timeIntervalSinceNow: 60)
      while bindError == EADDRINUSE && Date() < deadline {
        usleep(500_000)
        bindError = tryBind()
      }
    }
    guard bindError == 0 else {
      close(fd)
      throw VZVMError.runtime(
        """
        cannot listen on \(forward.listen): \(String(cString: strerror(bindError)))\
        \(bindError == EADDRINUSE ? " (another builder VM is probably already running)" : "")
        """)
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

    Log.info("forwarding \(forward.listen) -> vsock:\(forward.vsockPort)")
  }

  func stop() {
    acceptSource?.cancel()
    acceptSource = nil
    listenFD = -1
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
      Log.warn("accept on \(forward.listen): \(String(cString: strerror(errno)))")
      return
    }

    // Keep latency out of the guest's way. SSH is interactive.
    var yes: Int32 = 1
    setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &yes, socklen_t(MemoryLayout<Int32>.size))

    // Counted from accept, so a connection held while the guest boots keeps it from idling.
    backend.connectionOpened()
    connect(client: client, attempt: 0)
  }

  /// Our listener accepts while the guest is still booting or off, so there is nothing to
  /// splice to yet. Closing the client would make Nix mark the builder as failed. Instead it
  /// is held open, its first bytes (the SSH banner) buffered in the socket, until the guest's
  /// sshd answers: the client sees a slow handshake, not an error.
  private func connect(client: Int32, attempt: Int) {
    let port = forward.vsockPort

    // VZVirtioSocketDevice must be touched on the VM's queue.
    vmQueue.async {
      self.backend.connect(toPort: port) { [weak self] result in
        guard let self else {
          close(client)
          return
        }
        switch result {
        case .success(let connection):
          self.bridge(client: client, connection: connection)
        case .failure(let error):
          self.retry(client: client, attempt: attempt, reason: error.localizedDescription)
        }
      }
    }
  }

  private func retry(client: Int32, attempt: Int, reason: String) {
    let port = forward.vsockPort
    // Otherwise a client that gave up keeps the guest booting, or up, for nobody.
    guard !Self.clientGone(client) else {
      Log.info("client left before vsock:\(port) was ready")
      close(client)
      backend.connectionClosed()
      return
    }
    guard attempt < Self.maxRetries else {
      Log.warn("vsock:\(port) connect failed: \(reason). giving up")
      close(client)
      backend.connectionClosed()
      return
    }
    if attempt == 0 {
      Log.info("vsock:\(port) not ready. holding connection until the guest is up")
    }
    scheduler.schedule(
      after: Self.retryInterval,
      DispatchWorkItem { [weak self] in
        self?.connect(client: client, attempt: attempt + 1)
      })
  }

  /// TCP state rather than a peek:
  /// SSH clients send their banner first. Unread data would hide the FIN behind it.
  private static func clientGone(_ fd: Int32) -> Bool {
    var info = tcp_connection_info()
    var size = socklen_t(MemoryLayout<tcp_connection_info>.size)
    guard getsockopt(fd, IPPROTO_TCP, TCP_CONNECTION_INFO, &info, &size) == 0 else { return true }
    return info.tcpi_state != TCPS_ESTABLISHED
  }

  private func bridge(client: Int32, connection: VsockConnection) {
    let bridge = Bridge(tcpFD: client, connection: connection, vmQueue: vmQueue) {
      [weak self] finished in
      guard let self else { return }
      self.lock.lock()
      self.bridges.remove(finished)
      self.lock.unlock()
      self.backend.connectionClosed()
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
  private let connection: VsockConnection
  private let vsockFD: Int32
  private let queue = DispatchQueue(label: "vzvm.bridge")
  /// Virtualization.framework objects tolerate no other queue.
  private let vmQueue: DispatchQueue
  private let onFinish: (Bridge) -> Void
  private var closed = false
  private var tcpIO: DispatchIO?
  private var vsockIO: DispatchIO?

  init(
    tcpFD: Int32, connection: VsockConnection, vmQueue: DispatchQueue,
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
    // Both only touched on `queue`, where every handler below runs.
    var writesInFlight = 0
    var sourceDone = false
    // Full teardown: a half-close is not translated to virtio, so the guest leaks sshd.
    // Not via sink.barrier: that also waits for the opposite direction's read, which only
    // ends when the other peer closes too, so a one-sided close never tore anything down.
    let closeOnceFlushed = { [weak self] in
      if sourceDone && writesInFlight == 0 { self?.close() }
    }
    source.read(offset: 0, length: Int.max, queue: queue) { [weak self] done, data, error in
      guard let self else { return }
      if let data, !data.isEmpty {
        writesInFlight += 1
        sink.write(offset: 0, data: data, queue: self.queue) { [weak self] written, _, writeError in
          guard let self else { return }
          if writeError != 0 { return self.close() }
          if written {
            writesInFlight -= 1
            closeOnceFlushed()
          }
        }
      }
      if done || error != 0 {
        sourceDone = true
        closeOnceFlushed()
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
