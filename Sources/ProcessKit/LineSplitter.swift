import Foundation

/// Splits bytes into lines as they arrive. A line ends at \n, \r\n or a lone \r (the progress
/// lines of curl and FFmpeg), and a \r\n split across two reads still counts once.
struct LineSplitter {
    private var buffer = Data()

    mutating func feed(_ data: Data) -> [String] {
        buffer.append(data)
        var lines: [String] = []
        var start = buffer.startIndex
        var index = start
        while index < buffer.endIndex {
            let byte = buffer[index]
            if byte == 0x0A {
                lines.append(String(decoding: buffer[start..<index], as: UTF8.self))
                start = buffer.index(after: index)
            } else if byte == 0x0D {
                let next = buffer.index(after: index)
                // A \r at the very end may be the first half of \r\n: wait for the next read.
                if next == buffer.endIndex { break }
                lines.append(String(decoding: buffer[start..<index], as: UTF8.self))
                start = buffer[next] == 0x0A ? buffer.index(after: next) : next
                index = start
                continue
            }
            index = buffer.index(after: index)
        }
        buffer.removeSubrange(buffer.startIndex..<start)
        return lines
    }

    /// What's left after the last line ending, when the output ends without one.
    mutating func finish() -> String? {
        var rest = buffer
        buffer.removeAll()
        if rest.last == 0x0D { rest.removeLast() }
        return rest.isEmpty ? nil : String(decoding: rest, as: UTF8.self)
    }
}
