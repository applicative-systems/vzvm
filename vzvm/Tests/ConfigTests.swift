import Foundation
import XCTest

final class ConfigTests: XCTestCase {
  static let allTests = [
    ("testMinimalConfigDecodes", testMinimalConfigDecodes),
    ("testUnknownKeyIsRejected", testUnknownKeyIsRejected),
    ("testIdleTimeoutDecodes", testIdleTimeoutDecodes),
    ("testIdleTimeoutMustBePositive", testIdleTimeoutMustBePositive),
    ("testIdleTimeoutIsBounded", testIdleTimeoutIsBounded),
    ("testIdleTimeoutNeedsForward", testIdleTimeoutNeedsForward),
  ]

  private let forward =
    #""vsock": { "forwards": [{ "listen": "127.0.0.1:31022", "vsockPort": 22 }] }"#

  private func decode(_ extra: String...) throws -> Config {
    let fields =
      [
        #""cpuCount": 2"#,
        #""memorySizeMiB": 2048"#,
        #""kernel": "/k""#,
        #""initrd": "/i""#,
        #""cmdline": "console=hvc0""#,
      ] + extra
    let json = "{" + fields.joined(separator: ",") + "}"
    return try JSONDecoder().decode(Config.self, from: Data(json.utf8))
  }

  private func assertConfigError(
    _ expression: @autoclosure () throws -> Config, mentioning needle: String,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertThrowsError(try expression(), file: file, line: line) { error in
      guard case VZVMError.config(let message) = error else {
        return XCTFail("expected a config error, got \(error)", file: file, line: line)
      }
      XCTAssertTrue(
        message.contains(needle), "'\(message)' does not mention '\(needle)'", file: file,
        line: line)
    }
  }

  func testMinimalConfigDecodes() throws {
    let config = try decode()
    XCTAssertEqual(config.cpuCount, 2)
    XCTAssertNil(config.idleTimeoutSeconds)
    XCTAssertTrue(config.vsock.forwards.isEmpty)
  }

  func testUnknownKeyIsRejected() {
    assertConfigError(try decode(#""idleTimeout": 60"#), mentioning: "idleTimeout")
  }

  func testIdleTimeoutDecodes() throws {
    XCTAssertEqual(try decode(forward, #""idleTimeoutSeconds": 1800"#).idleTimeoutSeconds, 1800)
  }

  func testIdleTimeoutMustBePositive() {
    assertConfigError(try decode(forward, #""idleTimeoutSeconds": 0"#), mentioning: "between")
  }

  /// Int.max used to trap on its way through Double.
  func testIdleTimeoutIsBounded() throws {
    let max = Config.maxIdleTimeoutSeconds
    XCTAssertEqual(try decode(forward, #""idleTimeoutSeconds": \#(max)"#).idleTimeoutSeconds, max)
    assertConfigError(
      try decode(forward, #""idleTimeoutSeconds": \#(max + 1)"#), mentioning: "between")
    assertConfigError(
      try decode(forward, #""idleTimeoutSeconds": \#(Int.max)"#), mentioning: "between")
  }

  /// Only a forwarded connection boots an on-demand guest.
  func testIdleTimeoutNeedsForward() {
    assertConfigError(try decode(#""idleTimeoutSeconds": 60"#), mentioning: "vsock.forwards")
  }
}
