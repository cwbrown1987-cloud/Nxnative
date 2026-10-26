// prod.keys: "name = hex" lines. Values stay in memory: the type is not CustomStringConvertible and nothing
// here prints, logs or stores them. Only key names are ever shown.
import Foundation

struct Keys {
    private let map: [String: [UInt8]]

    init(contentsOf url: URL) throws {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw ConverterError("cannot read \(url.path)")
        }
        var map: [String: [UInt8]] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let name = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            if let bytes = unhex(line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)) {
                map[name] = bytes
            }
        }
        if map.isEmpty { throw ConverterError("\(url.path) holds no keys") }
        self.map = map
    }

    var count: Int { map.count }

    /// A key of the given size, or nil when it is missing or the wrong size.
    func key(_ name: String, size: Int = 16) -> [UInt8]? {
        guard let k = map[name], k.count == size else { return nil }
        return k
    }

    /// The highest master key revision present (master_key_XX), for the summary line.
    var newestMasterKey: Int? {
        map.keys.compactMap { $0.hasPrefix("master_key_") ? Int($0.dropFirst(11), radix: 16) : nil }.max()
    }
}

private func unhex(_ s: String) -> [UInt8]? {
    let c = Array(s.utf8)
    guard !c.isEmpty, c.count % 2 == 0 else { return nil }
    var out: [UInt8] = []
    out.reserveCapacity(c.count / 2)
    for i in stride(from: 0, to: c.count, by: 2) {
        guard let b = UInt8(String(bytes: c[i..<i + 2], encoding: .ascii) ?? "", radix: 16) else { return nil }
        out.append(b)
    }
    return out
}

struct ConverterError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}
