import Foundation

/// Forwards the guest's serial console into the macOS unified log, one line per message.
final class GuestConsole {
  let fileHandleForWriting: FileHandle

  private let readEnd: FileHandle
  private var pending = Data()
  private let lock = NSLock()

  /// Guards against a guest that emits enormous unterminated output.
  private static let maxLineBytes = 8 * 1024

  init() {
    let pipe = Pipe()
    fileHandleForWriting = pipe.fileHandleForWriting
    readEnd = pipe.fileHandleForReading

    // Never block or do slow work here: the guest's console writes stall once the pipe
    // buffer fills, which would hold up the guest itself.
    readEnd.readabilityHandler = { [weak self] handle in
      let chunk = handle.availableData
      guard !chunk.isEmpty else {
        handle.readabilityHandler = nil
        return
      }
      self?.consume(chunk)
    }
  }

  private func consume(_ chunk: Data) {
    lock.lock()
    pending.append(chunk)
    var lines: [Data] = []
    while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
      lines.append(pending[pending.startIndex..<newline])
      pending = pending[pending.index(after: newline)...]
    }
    if pending.count > Self.maxLineBytes {
      lines.append(pending)
      pending = Data()
    }
    lock.unlock()

    for line in lines {
      let text = Self.presentable(line)
      if !text.isEmpty { Log.guest(text) }
    }
  }

  /// Console output is full of colour and cursor sequences. make log unreadable.
  static func presentable(_ raw: Data) -> String {
    var text = String(decoding: raw, as: UTF8.self)
    text = text.replacingOccurrences(
      of: "\u{1B}(?:\\[[0-9;?]*[ -/]*[@-~]|\\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\)|[@-Z\\\\-_])",
      with: "",
      options: .regularExpression)
    let printable = text.unicodeScalars.filter {
      $0 == "\t" || ($0.value >= 0x20 && $0.value != 0x7F)
    }
    return String(String.UnicodeScalarView(printable)).trimmingCharacters(in: .whitespaces)
  }
}
