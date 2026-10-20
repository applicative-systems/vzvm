import Foundation
import XCTest

/// Decoding only; whether the values make sense is PreflightTests' business.
final class ConfigTests: XCTestCase {
  static let allTests = [
    ("testMinimalConfigDecodes", testMinimalConfigDecodes),
    ("testUnknownKeyIsRejected", testUnknownKeyIsRejected),
    ("testUnknownNestedKeyIsRejected", testUnknownNestedKeyIsRejected),
    ("testMissingRequiredKeyIsNamed", testMissingRequiredKeyIsNamed),
    ("testIdleTimeoutDecodes", testIdleTimeoutDecodes),
  ]

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

  func testMinimalConfigDecodes() throws {
    let config = try decode()
    XCTAssertEqual(config.cpuCount, 2)
    XCTAssertEqual(config.console.mode, "stdio")
    XCTAssertFalse(config.rosetta)
    XCTAssertNil(config.idleTimeoutSeconds)
    XCTAssertTrue(config.vsock.forwards.isEmpty)
  }

  /// A typo in the generating module must fail loudly, not be ignored.
  func testUnknownKeyIsRejected() {
    assertConfigError(try decode(#""idleTimeout": 60"#), mentioning: "'idleTimeout'")
  }

  func testUnknownNestedKeyIsRejected() {
    assertConfigError(
      try decode(#""console": { "mode": "log", "file": "x" }"#), mentioning: "in 'console'")
  }

  func testMissingRequiredKeyIsNamed() {
    let json = #"{ "cpuCount": 2 }"#
    XCTAssertThrowsError(try Config.load(path: write(json))) { error in
      guard case VZVMError.config(let message) = error else {
        return XCTFail("expected a config error, got \(error)")
      }
      XCTAssertTrue(message.contains("'memorySizeMiB'"), message)
    }
  }

  func testIdleTimeoutDecodes() throws {
    XCTAssertEqual(try decode(#""idleTimeoutSeconds": 1800"#).idleTimeoutSeconds, 1800)
  }

  /// Config.load is what turns DecodingErrors into readable messages.
  private func write(_ json: String) throws -> String {
    let path = NSTemporaryDirectory() + "vzvm-config-\(UUID().uuidString).json"
    try Data(json.utf8).write(to: URL(fileURLWithPath: path))
    addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
    return path
  }
}

func assertConfigError<T>(
  _ expression: @autoclosure () throws -> T, mentioning needle: String,
  file: StaticString = #filePath, line: UInt = #line
) {
  assertError(try expression(), .config, mentioning: needle, file: file, line: line)
}

enum ErrorKind { case config, preflight }

/// A VZVMError of that kind whose message names the culprit.
func assertError<T>(
  _ expression: @autoclosure () throws -> T, _ kind: ErrorKind, mentioning needle: String,
  file: StaticString = #filePath, line: UInt = #line
) {
  XCTAssertThrowsError(try expression(), file: file, line: line) { error in
    let message: String
    switch (kind, error) {
    case (.config, VZVMError.config(let m)), (.preflight, VZVMError.preflight(let m)):
      message = m
    default:
      return XCTFail("expected a \(kind) error, got \(error)", file: file, line: line)
    }
    XCTAssertTrue(
      message.contains(needle), "'\(message)' does not mention '\(needle)'", file: file,
      line: line)
  }
}
