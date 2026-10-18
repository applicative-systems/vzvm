import Foundation
import Virtualization
import XCTest

/// Against real files in a scratch directory. Rosetta and nested virtualization depend on
/// the host and stay off.
final class PreflightTests: XCTestCase {
  static let allTests = [
    ("testValidConfigPasses", testValidConfigPasses),
    ("testCPUCountMustBePositive", testCPUCountMustBePositive),
    ("testMemoryMustBeInRange", testMemoryMustBeInRange),
    ("testIdleTimeoutIsBounded", testIdleTimeoutIsBounded),
    ("testIdleTimeoutNeedsForward", testIdleTimeoutNeedsForward),
    ("testMissingKernelIsNamed", testMissingKernelIsNamed),
    ("testGzippedKernelIsExplained", testGzippedKernelIsExplained),
    ("testNonKernelIsRejected", testNonKernelIsRejected),
    ("testMissingInitrdIsNamed", testMissingInitrdIsNamed),
    ("testMissingDiskIsNamed", testMissingDiskIsNamed),
    ("testQcow2DiskIsRejected", testQcow2DiskIsRejected),
    ("testShareMustBeDirectory", testShareMustBeDirectory),
  ]

  private var dir: String!

  override func setUpWithError() throws {
    dir = NSTemporaryDirectory() + "vzvm-preflight-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    // Just enough of an arm64 Image header: the magic "ARM\x64" at 0x38.
    var image = Data(count: 0x40)
    image.replaceSubrange(0x38..<0x3C, with: [0x41, 0x52, 0x4D, 0x64])
    try write("Image", image)
    try write("initrd", Data("initrd".utf8))
    // Raw, under the `.qcow2` name nix-darwin's `ephemeral` expects: must pass.
    try write("nixos.qcow2", Data(count: 4096))
    try FileManager.default.createDirectory(
      atPath: path("keys"), withIntermediateDirectories: false)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(atPath: dir)
  }

  func testValidConfigPasses() {
    XCTAssertNoThrow(try preflight())
  }

  func testCPUCountMustBePositive() {
    assertError(try preflight(["cpuCount": 0]), .config, mentioning: "cpuCount")
  }

  func testMemoryMustBeInRange() {
    let maxMiB = VZVirtualMachineConfiguration.maximumAllowedMemorySize / (1024 * 1024)
    assertError(try preflight(["memorySizeMiB": maxMiB + 1]), .config, mentioning: "memorySizeMiB")
  }

  /// Int.max used to trap on its way through Double.
  func testIdleTimeoutIsBounded() {
    let max = Config.maxIdleTimeoutSeconds
    XCTAssertNoThrow(try preflight(["idleTimeoutSeconds": 1]))
    XCTAssertNoThrow(try preflight(["idleTimeoutSeconds": max]))
    for invalid in [0, -1, max + 1, Int.max] {
      assertError(try preflight(["idleTimeoutSeconds": invalid]), .config, mentioning: "between")
    }
  }

  /// Only a forwarded connection boots an on-demand guest.
  func testIdleTimeoutNeedsForward() {
    assertError(
      try preflight(["idleTimeoutSeconds": 60, "vsock": ["forwards": []]]), .config,
      mentioning: "vsock forward")
  }

  func testMissingKernelIsNamed() {
    assertError(try preflight(["kernel": path("missing")]), .preflight, mentioning: "missing")
  }

  /// Virtualization.framework fails opaquely on a compressed kernel.
  func testGzippedKernelIsExplained() throws {
    try write("Image.gz", Data([0x1F, 0x8B, 0x08, 0x00] + [UInt8](repeating: 0, count: 0x40)))
    assertError(
      try preflight(["kernel": path("Image.gz")]), .preflight, mentioning: "gzip-compressed")
  }

  func testNonKernelIsRejected() throws {
    try write("bzImage", Data("not a kernel".utf8))
    assertError(
      try preflight(["kernel": path("bzImage")]), .preflight,
      mentioning: "not an uncompressed arm64 kernel Image")
  }

  func testMissingInitrdIsNamed() {
    assertError(try preflight(["initrd": path("missing")]), .preflight, mentioning: "initrd")
  }

  func testMissingDiskIsNamed() {
    assertError(
      try preflight(["disks": [["path": path("missing.img")]]]), .preflight,
      mentioning: "missing.img")
  }

  /// A leftover from the QEMU builder under the same name, which a raw-disk VM would misread.
  func testQcow2DiskIsRejected() throws {
    try write("nixos.qcow2", Data([0x51, 0x46, 0x49, 0xFB] + [UInt8](repeating: 0, count: 4092)))
    assertError(try preflight(), .preflight, mentioning: "QEMU qcow2 image")
  }

  func testShareMustBeDirectory() {
    assertError(
      try preflight(["shares": [["tag": "keys", "path": path("initrd")]]]), .preflight,
      mentioning: "tag keys")
    assertError(
      try preflight(["shares": [["tag": "keys", "path": path("missing")]]]), .preflight,
      mentioning: "tag keys")
  }

  // MARK: Helpers

  private func path(_ name: String) -> String { dir + "/" + name }

  private func write(_ name: String, _ data: Data) throws {
    try data.write(to: URL(fileURLWithPath: path(name)))
  }

  /// A config that passes preflight, with `overrides` replacing top-level keys.
  private func preflight(_ overrides: [String: Any] = [:]) throws {
    var json: [String: Any] = [
      "cpuCount": 2,
      "memorySizeMiB": 2048,
      "kernel": path("Image"),
      "initrd": path("initrd"),
      "cmdline": "console=hvc0",
      "disks": [["path": path("nixos.qcow2")]],
      "shares": [["tag": "keys", "path": path("keys")]],
      "vsock": ["forwards": [["listen": "127.0.0.1:31022", "vsockPort": 22]]],
    ]
    json.merge(overrides) { $1 }
    let data = try JSONSerialization.data(withJSONObject: json)
    try VirtualMachineBuilder.preflight(JSONDecoder().decode(Config.self, from: data))
  }
}
