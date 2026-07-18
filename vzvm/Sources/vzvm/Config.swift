import Foundation

struct Config: Decodable {
  var cpuCount: Int
  var memorySizeMiB: UInt64

  var kernel: String
  var initrd: String
  var cmdline: String

  /// Order is significant: disks map to /dev/vda, /dev/vdb, ...
  var disks: [Disk] = []
  var shares: [Share] = []
  /// Expose Rosetta to the guest. The mount tag is always "rosetta".
  var rosetta: Bool = false
  var vsock: Vsock = Vsock()
  var console: Console = Console()

  enum CodingKeys: String, CodingKey, CaseIterable {
    case cpuCount, memorySizeMiB, kernel, initrd, cmdline
    case disks, shares, rosetta, vsock, console
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try decoder.rejectUnknownKeys(CodingKeys.self)
    cpuCount = try container.decode(Int.self, forKey: .cpuCount)
    memorySizeMiB = try container.decode(UInt64.self, forKey: .memorySizeMiB)
    kernel = try container.decode(String.self, forKey: .kernel)
    initrd = try container.decode(String.self, forKey: .initrd)
    cmdline = try container.decode(String.self, forKey: .cmdline)
    disks = try container.decodeIfPresent([Disk].self, forKey: .disks) ?? []
    shares = try container.decodeIfPresent([Share].self, forKey: .shares) ?? []
    rosetta = try container.decodeIfPresent(Bool.self, forKey: .rosetta) ?? false
    vsock = try container.decodeIfPresent(Vsock.self, forKey: .vsock) ?? Vsock()
    console = try container.decodeIfPresent(Console.self, forKey: .console) ?? Console()
  }

  struct Disk: Decodable {
    var path: String
    var readOnly: Bool = false

    enum CodingKeys: String, CodingKey, CaseIterable { case path, readOnly }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      try decoder.rejectUnknownKeys(CodingKeys.self)
      path = try container.decode(String.self, forKey: .path)
      readOnly = try container.decodeIfPresent(Bool.self, forKey: .readOnly) ?? false
    }
  }

  struct Share: Decodable {
    var tag: String
    var path: String

    enum CodingKeys: String, CodingKey, CaseIterable { case tag, path }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      try decoder.rejectUnknownKeys(CodingKeys.self)
      tag = try container.decode(String.self, forKey: .tag)
      path = try container.decode(String.self, forKey: .path)
    }
  }

  struct Vsock: Decodable {
    var forwards: [Forward] = []

    init() {}

    enum CodingKeys: String, CodingKey, CaseIterable { case forwards }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      try decoder.rejectUnknownKeys(CodingKeys.self)
      forwards = try container.decodeIfPresent([Forward].self, forKey: .forwards) ?? []
    }

    struct Forward: Decodable {
      /// "127.0.0.1:31022"
      var listen: String
      var vsockPort: UInt32

      enum CodingKeys: String, CodingKey, CaseIterable { case listen, vsockPort }

      init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try decoder.rejectUnknownKeys(CodingKeys.self)
        listen = try container.decode(String.self, forKey: .listen)
        vsockPort = try container.decode(UInt32.self, forKey: .vsockPort)
      }
    }
  }

  struct Console: Decodable {
    /// "stdio" | "file" | "log" (unified macOS log)
    var mode: String = "stdio"
    var path: String?

    init() {}

    enum CodingKeys: String, CodingKey, CaseIterable { case mode, path }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      try decoder.rejectUnknownKeys(CodingKeys.self)
      mode = try container.decodeIfPresent(String.self, forKey: .mode) ?? "stdio"
      path = try container.decodeIfPresent(String.self, forKey: .path)
    }
  }

  static func load(path: String) throws -> Config {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    do {
      return try JSONDecoder().decode(Config.self, from: data)
    } catch let error as DecodingError {
      throw VZVMError.config(describe(error))
    }
  }

  private static func describe(_ error: DecodingError) -> String {
    func path(_ context: DecodingError.Context) -> String {
      context.codingPath.map(\.stringValue).joined(separator: ".")
    }
    switch error {
    case .keyNotFound(let key, let ctx):
      let parent = path(ctx)
      return "missing required key '\(key.stringValue)'\(parent.isEmpty ? "" : " in '\(parent)'")"
    case .typeMismatch(let type, let ctx):
      return "'\(path(ctx))' has wrong type, expected \(type)"
    case .valueNotFound(let type, let ctx):
      return "'\(path(ctx))' is null, expected \(type)"
    case .dataCorrupted(let ctx):
      let at = path(ctx)
      return "\(at.isEmpty ? "" : "'\(at)': ")\(ctx.debugDescription)"
    @unknown default:
      return "\(error)"
    }
  }
}

extension Decoder {
  /// be loud about typos etc.
  func rejectUnknownKeys<K>(_ schema: K.Type) throws where K: CodingKey & CaseIterable {
    let known = Set(K.allCases.map(\.stringValue))
    let present = try container(keyedBy: AnyCodingKey.self).allKeys.map(\.stringValue)
    let unknown = present.filter { !known.contains($0) }
    guard unknown.isEmpty else {
      let here = codingPath.map(\.stringValue).joined(separator: ".")
      throw VZVMError.config(
        "unknown key\(unknown.count > 1 ? "s" : "") "
          + unknown.sorted().map { "'\($0)'" }.joined(separator: ", ")
          + (here.isEmpty ? "" : " in '\(here)'"))
    }
  }
}

private struct AnyCodingKey: CodingKey {
  var stringValue: String
  var intValue: Int?
  init?(stringValue: String) { self.stringValue = stringValue }
  init?(intValue: Int) {
    self.intValue = intValue
    stringValue = String(intValue)
  }
}

enum VZVMError: Error, CustomStringConvertible {
  case config(String)
  case preflight(String)
  case runtime(String)

  var description: String {
    switch self {
    case .config(let m): return "config: \(m)"
    case .preflight(let m): return "preflight: \(m)"
    case .runtime(let m): return m
    }
  }
}

enum ExitCode {
  static let ok: Int32 = 0
  static let usage: Int32 = 64
  static let config: Int32 = 78
  static let preflight: Int32 = 69
  static let runtime: Int32 = 70
  static let guestError: Int32 = 71
}
