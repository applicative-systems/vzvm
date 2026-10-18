import Foundation
import XCTest

/// One end of a socketpair; the test holds the other as the guest's side.
final class FakeConnection: VsockConnection {
  let fileDescriptor: Int32
  private let lock = NSLock()
  private var closed = false

  init(fileDescriptor: Int32) { self.fileDescriptor = fileDescriptor }

  var isClosed: Bool { lock.withLock { closed } }

  func close() {
    let first = lock.withLock {
      defer { closed = true }
      return !closed
    }
    if first { Darwin.close(fileDescriptor) }
  }
}

/// Stands in for Machine: counts connections and, while the guest is up, hands out
/// socketpairs. Called from the proxy's queues, read from the test's.
final class FakeBackend: VsockBackend {
  let queue = DispatchQueue(label: "vzvm.test.backend")
  private let lock = NSLock()
  private var state = (opened: 0, closed: 0, attempts: 0, guestUp: false)
  private var bridged: [(guestEnd: Int32, connection: FakeConnection)] = []

  var opened: Int { lock.withLock { state.opened } }
  var closed: Int { lock.withLock { state.closed } }
  var attempts: Int { lock.withLock { state.attempts } }
  var guestUp: Bool {
    get { lock.withLock { state.guestUp } }
    set { lock.withLock { state.guestUp = newValue } }
  }
  /// The guest's side of each bridged connection, in order.
  var guestEnds: [Int32] { lock.withLock { bridged.map(\.guestEnd) } }
  var connections: [FakeConnection] { lock.withLock { bridged.map(\.connection) } }

  func connectionOpened() { lock.withLock { state.opened += 1 } }
  func connectionClosed() { lock.withLock { state.closed += 1 } }

  func connect(
    toPort port: UInt32, completionHandler: @escaping (Result<VsockConnection, Error>) -> Void
  ) {
    dispatchPrecondition(condition: .onQueue(queue))
    let up = lock.withLock {
      state.attempts += 1
      return state.guestUp
    }
    var fds: [Int32] = [-1, -1]
    guard up, socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
      return completionHandler(.failure(FakeError()))
    }
    let connection = FakeConnection(fileDescriptor: fds[0])
    lock.withLock { bridged.append((fds[1], connection)) }
    completionHandler(.success(connection))
  }
}

final class VsockProxyTests: XCTestCase {
  static let allTests = [
    ("testBridgesBytesBothWays", testBridgesBytesBothWays),
    ("testClientCloseTearsDownBothSides", testClientCloseTearsDownBothSides),
    ("testGuestCloseTearsDownBothSides", testGuestCloseTearsDownBothSides),
    ("testHoldsClientUntilGuestIsUp", testHoldsClientUntilGuestIsUp),
    ("testReleasesClientThatLeftWhileHeld", testReleasesClientThatLeftWhileHeld),
    ("testGivesUpAfterMaxRetries", testGivesUpAfterMaxRetries),
    ("testStopClosesBridges", testStopClosesBridges),
    ("testCountsEveryClientOnce", testCountsEveryClientOnce),
    ("testParsesListenAddress", testParsesListenAddress),
  ]

  private var backend: FakeBackend!
  private var clock: ManualScheduler!
  private var proxy: VsockProxy!
  private var clients: [Int32] = []

  override func setUpWithError() throws {
    backend = FakeBackend()
    clock = ManualScheduler()
    let port = try Self.freePort()
    let json = #"{ "listen": "127.0.0.1:\#(port)", "vsockPort": 22 }"#
    let forward = try JSONDecoder().decode(Config.Vsock.Forward.self, from: Data(json.utf8))
    proxy = VsockProxy(forward: forward, backend: backend, scheduler: clock)
    try proxy.start()
    self.port = port
  }

  override func tearDown() {
    proxy.stop()
    for fd in clients { close(fd) }
    for fd in backend.guestEnds { close(fd) }
  }

  private var port: UInt16 = 0

  // MARK: Bridging

  func testBridgesBytesBothWays() throws {
    backend.guestUp = true
    let client = try dial()
    let guest = try bridgedGuestEnd()
    send(client, "ping")
    XCTAssertEqual(receive(guest, 4), "ping")
    send(guest, "pong")
    XCTAssertEqual(receive(client, 4), "pong")
    XCTAssertEqual(backend.opened, 1)
    XCTAssertEqual(backend.closed, 0)
  }

  /// A half-close is not translated to virtio, so the guest would leak its sshd.
  func testClientCloseTearsDownBothSides() throws {
    backend.guestUp = true
    let client = try dial()
    let guest = try bridgedGuestEnd()
    // The last words still arrive before the teardown, with the guest never having written.
    send(client, "bye")
    close(client)
    clients.removeAll()
    XCTAssertEqual(receive(guest, 3), "bye")
    XCTAssertTrue(atEOF(guest))
    XCTAssertTrue(wait { self.backend.closed == 1 })
    XCTAssertTrue(wait { self.backend.connections[0].isClosed })
    XCTAssertTrue(stays { self.backend.closed == 1 })
  }

  func testGuestCloseTearsDownBothSides() throws {
    backend.guestUp = true
    let client = try dial()
    let guest = try bridgedGuestEnd()
    // shutdown, not close: tearDown closes the descriptor.
    shutdown(guest, SHUT_RDWR)
    XCTAssertTrue(atEOF(client))
    XCTAssertTrue(wait { self.backend.closed == 1 })
    XCTAssertTrue(stays { self.backend.closed == 1 })
  }

  // MARK: Holding clients while the guest boots

  /// What SSH does: its banner goes out before the guest can take it, and must arrive anyway.
  func testHoldsClientUntilGuestIsUp() throws {
    let client = try dial()
    XCTAssertTrue(wait { self.clock.pendingCount == 1 })
    send(client, "SSH-2.0-test\r\n")
    XCTAssertEqual(backend.opened, 1)
    XCTAssertEqual(backend.closed, 0)
    backend.guestUp = true
    clock.advance(by: VsockProxy.retryInterval)
    let guest = try bridgedGuestEnd()
    XCTAssertEqual(receive(guest, 14), "SSH-2.0-test\r\n")
    XCTAssertEqual(backend.attempts, 2)
  }

  /// Sent data plus FIN: a peek would see the banner and miss that the client is gone.
  func testReleasesClientThatLeftWhileHeld() throws {
    let client = try dial()
    XCTAssertTrue(wait { self.clock.pendingCount == 1 })
    send(client, "SSH-2.0-test\r\n")
    close(client)
    clients.removeAll()
    // The FIN has to reach the proxy's end before the retry looks.
    usleep(50_000)
    clock.advance(by: VsockProxy.retryInterval)
    XCTAssertTrue(wait { self.backend.closed == 1 })
    XCTAssertEqual(clock.pendingCount, 0)
    XCTAssertEqual(backend.attempts, 2)
  }

  func testGivesUpAfterMaxRetries() throws {
    let client = try dial()
    for retry in 1...VsockProxy.maxRetries {
      guard wait({ self.clock.pendingCount == 1 }) else {
        return XCTFail("retry \(retry) was never scheduled")
      }
      clock.advance(by: VsockProxy.retryInterval)
    }
    XCTAssertTrue(atEOF(client))
    XCTAssertTrue(wait { self.backend.closed == 1 })
    XCTAssertEqual(clock.pendingCount, 0)
    XCTAssertEqual(backend.attempts, VsockProxy.maxRetries + 1)
  }

  // MARK: Counting

  func testStopClosesBridges() throws {
    backend.guestUp = true
    let client = try dial()
    _ = try bridgedGuestEnd()
    proxy.stop()
    XCTAssertTrue(atEOF(client))
    XCTAssertTrue(wait { self.backend.closed == 1 })
  }

  /// Every accept must be balanced by exactly one close, or the guest never idles.
  func testCountsEveryClientOnce() throws {
    backend.guestUp = true
    for n in 1...5 {
      _ = try dial()
      XCTAssertTrue(wait { self.backend.guestEnds.count == n })
    }
    for fd in clients { close(fd) }
    clients.removeAll()
    XCTAssertTrue(wait { self.backend.closed == 5 })
    XCTAssertTrue(stays { self.backend.closed == 5 })
    XCTAssertEqual(backend.opened, 5)
  }

  func testParsesListenAddress() throws {
    XCTAssertTrue(try VsockProxy.parse(listen: "127.0.0.1:31022") == ("127.0.0.1", 31022))
    XCTAssertTrue(try VsockProxy.parse(listen: ":22") == ("127.0.0.1", 22))
    for invalid in ["127.0.0.1", "127.0.0.1:0", "127.0.0.1:65536", "127.0.0.1:ssh"] {
      XCTAssertThrowsError(try VsockProxy.parse(listen: invalid), invalid)
    }
  }

  // MARK: Helpers

  private static func freePort() throws -> UInt16 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    var size = socklen_t(MemoryLayout<sockaddr_in>.size)
    let ok = withUnsafeMutablePointer(to: &addr) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, size) == 0 && getsockname(fd, $0, &size) == 0
      }
    }
    guard ok else { throw FakeError() }
    return UInt16(bigEndian: addr.sin_port)
  }

  private func dial() throws -> Int32 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let connected = withUnsafePointer(to: &addr) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
      }
    }
    guard connected else {
      close(fd)
      throw FakeError()
    }
    // Reads time out instead of hanging the run when the proxy misbehaves.
    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    clients.append(fd)
    return fd
  }

  /// The guest's end of the latest bridge, once the proxy has made one.
  private func bridgedGuestEnd(file: StaticString = #filePath, line: UInt = #line) throws
    -> Int32
  {
    guard wait({ !self.backend.guestEnds.isEmpty }) else {
      XCTFail("proxy never bridged the client", file: file, line: line)
      throw FakeError()
    }
    let fd = backend.guestEnds.last!
    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    return fd
  }

  private func send(_ fd: Int32, _ text: String) {
    let bytes = Array(text.utf8)
    XCTAssertEqual(Darwin.send(fd, bytes, bytes.count, 0), bytes.count)
  }

  /// Exactly `count` bytes, or whatever arrived before EOF or the timeout.
  private func receive(_ fd: Int32, _ count: Int) -> String {
    var buffer = [UInt8](repeating: 0, count: count)
    var received = 0
    while received < count {
      let n = buffer.withUnsafeMutableBytes {
        recv(fd, $0.baseAddress! + received, count - received, 0)
      }
      guard n > 0 else { break }
      received += n
    }
    return String(decoding: buffer[..<received], as: UTF8.self)
  }

  /// True once the peer has closed; false if it is still open after the timeout.
  private func atEOF(_ fd: Int32) -> Bool {
    var byte: UInt8 = 0
    return recv(fd, &byte, 1, 0) == 0
  }

  private func wait(timeout: TimeInterval = 2, _ condition: () -> Bool) -> Bool {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while !condition() {
      guard Date() < deadline else { return false }
      usleep(5_000)
    }
    return true
  }

  /// Guards against late double counting.
  private func stays(for duration: TimeInterval = 0.2, _ condition: () -> Bool) -> Bool {
    let deadline = Date(timeIntervalSinceNow: duration)
    while Date() < deadline {
      guard condition() else { return false }
      usleep(5_000)
    }
    return true
  }
}
