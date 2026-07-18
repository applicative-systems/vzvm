import Foundation
import os

/// Diagnostics go to the unified log, where a Mac looks for service logs, and to stderr,
/// which is all there is when vzvm runs outside launchd.
enum Log {
  static let subsystem = "systems.applicative.vzvm"

  private static let own = Logger(subsystem: subsystem, category: "vzvm")
  private static let guestLog = Logger(subsystem: subsystem, category: "guest")
  private static let lock = NSLock()

  static func info(_ message: String) {
    // `notice` instead `info`: unified log keeps info-level messages in memory only,
    // so `log show` cannot find them afterward.
    own.notice("\(message, privacy: .public)")
    echo("[vzvm] \(message)")
  }

  static func warn(_ message: String) {
    own.warning("\(message, privacy: .public)")
    echo("[vzvm] warning: \(message)")
  }

  static func error(_ message: String) {
    own.error("\(message, privacy: .public)")
    echo("[vzvm] error: \(message)")
  }

  static func guest(_ line: String) {
    guestLog.notice("\(line, privacy: .public)")
  }

  private static func echo(_ line: String) {
    guard let data = (line + "\n").data(using: .utf8) else { return }
    lock.lock()
    defer { lock.unlock() }
    FileHandle.standardError.write(data)
  }
}
