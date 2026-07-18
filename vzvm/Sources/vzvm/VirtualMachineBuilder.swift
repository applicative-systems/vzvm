import Foundation
import Virtualization

/// Fixed, not configurable: guest's `virtualisation.rosetta.mountTag` must agree.
let rosettaMountTag = "rosetta"

enum VirtualMachineBuilder {

  /// Retained for process lifetime; releasing would close the guest's console pipe.
  private(set) static var guestConsole: GuestConsole?

  /// Pre-flight checks, so failures read as one clear line instead of a `VZErrorDomain` code.
  static func preflight(_ config: Config) throws {
    guard config.cpuCount >= 1 else {
      throw VZVMError.config("cpuCount must be >= 1")
    }
    let minMiB = VZVirtualMachineConfiguration.minimumAllowedMemorySize / (1024 * 1024)
    let maxMiB = VZVirtualMachineConfiguration.maximumAllowedMemorySize / (1024 * 1024)
    guard config.memorySizeMiB >= minMiB && config.memorySizeMiB <= maxMiB else {
      throw VZVMError.config(
        "memorySizeMiB \(config.memorySizeMiB) outside supported range \(minMiB)..\(maxMiB)")
    }

    try checkKernel(config.kernel)

    guard FileManager.default.fileExists(atPath: config.initrd) else {
      throw VZVMError.preflight("initrd not found: \(config.initrd)")
    }

    for disk in config.disks {
      guard FileManager.default.fileExists(atPath: disk.path) else {
        throw VZVMError.preflight("disk image not found: \(disk.path)")
      }
      if try hasMagic(disk.path, offset: 0, bytes: [0x51, 0x46, 0x49, 0xFB]) {
        // Our raw disk must carry the `.qcow2` name nix-darwin's `ephemeral` deletes.
        throw VZVMError.preflight(
          """
          \(disk.path) is a QEMU qcow2 image, not a raw disk. It is most likely \
          left over from darwin.linux-builder (QEMU). Delete it and it will be \
          recreated as a raw disk.
          """)
      }
    }

    for share in config.shares {
      var isDir: ObjCBool = false
      guard FileManager.default.fileExists(atPath: share.path, isDirectory: &isDir), isDir.boolValue
      else {
        throw VZVMError.preflight("shared directory not found: \(share.path) (tag \(share.tag))")
      }
    }

    if config.rosetta {
      try checkRosetta()
    }
  }

  /// The boot loader needs an uncompressed arm64 `Image`; a gzipped one fails opaquely.
  private static func checkKernel(_ path: String) throws {
    guard FileManager.default.fileExists(atPath: path) else {
      throw VZVMError.preflight("kernel not found: \(path)")
    }
    // arm64 Linux Image header: magic "ARM\x64" at offset 0x38.
    guard try hasMagic(path, offset: 0x38, bytes: [0x41, 0x52, 0x4D, 0x64]) else {
      if try hasMagic(path, offset: 0, bytes: [0x1F, 0x8B]) {
        throw VZVMError.preflight(
          """
          \(path) is gzip-compressed. Virtualization.framework needs an \
          uncompressed arm64 kernel Image.
          """)
      }
      throw VZVMError.preflight("\(path) is not an uncompressed arm64 kernel Image")
    }
  }

  private static func checkRosetta() throws {
    switch VZLinuxRosettaDirectoryShare.availability {
    case .installed:
      return
    case .notInstalled:
      // Refuse to start rather than silently stop advertising x86_64-linux.
      throw VZVMError.preflight(
        """
        Rosetta is not installed. Install it with:
            softwareupdate --install-rosetta --agree-to-license
        """)
    case .notSupported:
      throw VZVMError.preflight("Rosetta is not supported on this host")
    @unknown default:
      throw VZVMError.preflight("Rosetta availability unknown")
    }
  }

  private static func hasMagic(_ path: String, offset: UInt64, bytes: [UInt8]) throws -> Bool {
    let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
    defer { try? handle.close() }
    try handle.seek(toOffset: offset)
    return try handle.read(upToCount: bytes.count) == Data(bytes)
  }

  static func build(_ config: Config) throws -> VZVirtualMachineConfiguration {
    let vmc = VZVirtualMachineConfiguration()
    vmc.cpuCount = config.cpuCount
    vmc.memorySize = config.memorySizeMiB * 1024 * 1024

    let boot = VZLinuxBootLoader(kernelURL: URL(fileURLWithPath: config.kernel))
    boot.initialRamdiskURL = URL(fileURLWithPath: config.initrd)
    boot.commandLine = config.cmdline
    vmc.bootLoader = boot

    vmc.storageDevices = try config.disks.map { disk in
      let attachment = try VZDiskImageStorageDeviceAttachment(
        url: URL(fileURLWithPath: disk.path),
        readOnly: disk.readOnly,
        cachingMode: .automatic,
        synchronizationMode: disk.readOnly ? .none : .fsync)
      return VZVirtioBlockDeviceConfiguration(attachment: attachment)
    }

    var sharingDevices: [VZDirectorySharingDeviceConfiguration] = config.shares.map { share in
      let device = VZVirtioFileSystemDeviceConfiguration(tag: share.tag)
      device.share = VZSingleDirectoryShare(
        directory: VZSharedDirectory(url: URL(fileURLWithPath: share.path), readOnly: false))
      return device
    }

    if config.rosetta {
      let device = VZVirtioFileSystemDeviceConfiguration(tag: rosettaMountTag)
      let share = try VZLinuxRosettaDirectoryShare()
      // The translation cache daemon is macOS 14+; on 13 Rosetta just re-translates more.
      if #available(macOS 14.0, *) {
        try share.setCachingOptions(.defaultUnixSocket)
      }
      device.share = share
      sharingDevices.append(device)
    }
    vmc.directorySharingDevices = sharingDevices

    // NAT is the one attachment that needs no special entitlement.
    let network = VZVirtioNetworkDeviceConfiguration()
    network.attachment = VZNATNetworkDeviceAttachment()
    vmc.networkDevices = [network]

    if !config.vsock.forwards.isEmpty {
      vmc.socketDevices = [VZVirtioSocketDeviceConfiguration()]
    }

    vmc.serialPorts = [try consoleDevice(config.console)]

    vmc.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
    vmc.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]

    try vmc.validate()
    return vmc
  }

  private static func consoleDevice(
    _ console: Config.Console
  ) throws -> VZSerialPortConfiguration {
    let attachment: VZSerialPortAttachment
    switch console.mode {
    case "stdio":
      attachment = VZFileHandleSerialPortAttachment(
        fileHandleForReading: FileHandle.standardInput,
        fileHandleForWriting: FileHandle.standardOutput)
    case "file":
      guard let path = console.path else {
        throw VZVMError.config("console.mode 'file' requires console.path")
      }
      if !FileManager.default.fileExists(atPath: path) {
        FileManager.default.createFile(atPath: path, contents: nil)
      }
      guard let handle = FileHandle(forWritingAtPath: path) else {
        throw VZVMError.config("cannot open console log for writing: \(path)")
      }
      handle.seekToEndOfFile()
      attachment = VZFileHandleSerialPortAttachment(
        fileHandleForReading: nil, fileHandleForWriting: handle)
    case "log":
      let console = GuestConsole()
      guestConsole = console
      attachment = VZFileHandleSerialPortAttachment(
        fileHandleForReading: nil, fileHandleForWriting: console.fileHandleForWriting)
    default:
      throw VZVMError.config("unsupported console.mode '\(console.mode)'")
    }
    let port = VZVirtioConsoleDeviceSerialPortConfiguration()
    port.attachment = attachment
    return port
  }
}
