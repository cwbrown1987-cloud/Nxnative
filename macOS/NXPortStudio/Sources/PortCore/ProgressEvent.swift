import Foundation

/// The schema emitted by nxnative's --progress json mode; non-JSON stderr stays in the log.
public struct ProgressEvent: Decodable, Sendable {
    public var ev: String
    public var k: Int?
    public var n: Int?
    public var name: String?
    public var step: String?
    public var done: Double?
    public var total: Double?
    public var frac: Double?
    public var eta: Double?
    public var elapsed: Double?
    public var msg: String?
    public var summary: String?
    public var ok: Bool?
    public var unit: String?
    public var note: String?
    public var est: Bool?
    public var stageName: String? { name }
    public var stepName: String? { step }
    public var fraction: Double? { frac.map { min(max($0, 0), 1) } }
    public var message: String? { msg ?? summary }
    public static func decode(line: String) -> ProgressEvent? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}
