// Checks a game folder against prod.keys without extracting anything: for each NCA in each NSP / XCI
// (or NSZ / XCZ) it decrypts the header with header_key, works out which keys the content needs from its
// key generation and rights ID, decrypts the title key (from the NSP's ticket) or the key area, and then
// decrypts the first bytes of an encrypted section to check that they read as a file system. A few KB per NCA.
import Foundation

struct CheckLine: Hashable {
    let ok: Bool
    let text: String
}

struct FileReport: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let role: String
    let ok: Bool
    let lines: [CheckLine]
}

struct Validation {
    let ok: Bool
    /// "231 keys, master keys up to 15"
    let keysSummary: String
    let summary: [CheckLine]
    let files: [FileReport]
}

private struct Entry {
    let name: String
    let offset: UInt64
    let size: UInt64
}

private let gameExtensions: Set<String> = ["nsp", "xci", "nsz", "xcz"]

enum GameFiles {
    static func list(in dir: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return items.filter { gameExtensions.contains($0.pathExtension.lowercased()) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func validate(dir: URL, keysURL: URL) -> Validation {
        func fail(_ s: [CheckLine], _ k: String = "") -> Validation { Validation(ok: false, keysSummary: k, summary: s, files: []) }
        let keys: Keys
        do { keys = try Keys(contentsOf: keysURL) } catch { return fail([CheckLine(ok: false, text: "\(error)")]) }
        let mk = keys.newestMasterKey.map { String(format: ", master keys up to %02x", $0) } ?? ""
        let keysSummary = "\(keys.count) keys\(mk)"
        var summary = [CheckLine(ok: true, text: "prod.keys read: \(keysSummary)")]
        guard let headerKey = keys.key("header_key", size: 32) else {
            summary.append(CheckLine(ok: false, text: "prod.keys has no header_key (32 bytes): no NCA can be read"))
            return fail(summary, keysSummary)
        }
        let files = list(in: dir)
        if files.isEmpty {
            summary.append(CheckLine(ok: false, text: "no .nsp, .xci, .nsz or .xcz files in \(dir.path)"))
            return fail(summary, keysSummary)
        }
        var reports: [FileReport] = []
        var titles: [UInt64] = []
        for f in files {
            let (r, tid) = checkFile(f, keys: keys, headerKey: headerKey)
            if let tid { titles.append(tid) }
            reports.append(r)
        }
        // one game per folder, with a base game, as the script requires
        var ok = reports.allSatisfy(\.ok)
        let apps = Set(titles.map(appOf))
        switch apps.count {
        case 0:
            summary.append(CheckLine(ok: false, text: "no title ID could be read from any file")); ok = false
        case 1:
            let app = apps.first!
            let hasBase = titles.contains(app)
            summary.append(CheckLine(ok: hasBase, text: String(format: "game %016llX", app) + (hasBase ? "" : ": no base game in the folder")))
            ok = ok && hasBase
        default:
            let list = apps.sorted().map { String(format: "%016llX", $0) }.joined(separator: ", ")
            summary.append(CheckLine(ok: false, text: "more than one game in the folder (\(list)); keep one game per folder")); ok = false
        }
        let bad = reports.filter { !$0.ok }.count
        summary.append(CheckLine(ok: bad == 0, text: bad == 0 ? "\(reports.count) file(s) decrypt with these keys" : "\(bad) of \(reports.count) file(s) failed"))
        return Validation(ok: ok, keysSummary: keysSummary, summary: summary, files: reports)
    }

    static func appOf(_ tid: UInt64) -> UInt64 {
        switch tid & 0xFFF {
        case 0: return tid
        case 0x800: return tid & ~0xFFF
        default: return (tid & ~0xFFF) - 0x1000
        }
    }

    private static func role(_ tid: UInt64, name: String) -> String {
        switch tid & 0xFFF {
        case 0: return "Base game"
        case 0x800: return versionTag(name).map { "Update v\($0)" } ?? "Update"
        default: return "DLC"
        }
    }

    private static func versionTag(_ name: String) -> UInt64? {
        guard let r = name.range(of: "[v"), let e = name[r.upperBound...].firstIndex(of: "]") else { return nil }
        return UInt64(name[r.upperBound..<e])
    }

    private static func tagTitle(_ name: String) -> UInt64? {
        let s = Array(name)
        for i in 0..<max(0, s.count - 17) where s[i] == "[" && s[i + 17] == "]" {
            if let v = UInt64(String(s[(i + 1)...(i + 16)]), radix: 16) { return v }
        }
        return nil
    }

    private static func checkFile(_ url: URL, keys: Keys, headerKey: [UInt8]) -> (FileReport, UInt64?) {
        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        let compressed = ext == "nsz" || ext == "xcz"
        var lines: [CheckLine] = []
        do {
            guard let h = FileHandle(forReadingAtPath: url.path) else { throw ConverterError("cannot open") }
            defer { try? h.close() }
            if (try? h.seekToEnd()) ?? 0 == 0 { throw ConverterError("empty file (an incomplete download?)") }
            let entries = (ext == "xci" || ext == "xcz") ? try xciSecure(h) : try pfs0(h, base: 0)
            let tickets: [[UInt8]] = entries.filter { $0.name.hasSuffix(".tik") }.compactMap { try? read(h, $0.offset, Int(min($0.size, 0x400))) }
            var tid: UInt64? = tickets.lazy.compactMap { ticketRights($0) }.first.map { r in r[0..<8].reduce(0) { $0 << 8 | UInt64($1) } }
            var allOK = true, ncas = 0
            for e in entries where e.name.hasSuffix(".nca") || e.name.hasSuffix(".ncz") {
                ncas += 1
                do {
                    let n = try checkNCA(h, e, keys: keys, headerKey: headerKey, tickets: tickets, compressed: compressed || e.name.hasSuffix(".ncz"))
                    if tid == nil && n.contentType == 1 { tid = n.programID }   // the Meta NCA names the content's title
                    lines.append(CheckLine(ok: true, text: "\(short(e.name)): \(n.note)"))
                } catch {
                    allOK = false
                    lines.append(CheckLine(ok: false, text: "\(short(e.name)): \(error)"))
                }
            }
            if ncas == 0 { throw ConverterError("no NCA inside") }
            let t = tid ?? tagTitle(name)
            return (FileReport(name: name, role: t.map { role($0, name: name) } ?? "Unknown title", ok: allOK, lines: lines), t)
        } catch {
            lines.append(CheckLine(ok: false, text: "\(error)"))
            return (FileReport(name: name, role: "Unreadable", ok: false, lines: lines), nil)
        }
    }

    private static func short(_ n: String) -> String {
        n.count > 14 ? "\(n.prefix(6))…\(n.suffix(8))" : n
    }

    private static func read(_ h: FileHandle, _ off: UInt64, _ len: Int) throws -> [UInt8] {
        try h.seek(toOffset: off)
        guard let d = try h.read(upToCount: len), d.count == len else { throw ConverterError(String(format: "short read at %#llx", off)) }
        return [UInt8](d)
    }

    private static func u32(_ b: [UInt8], _ o: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(b[o + $1]) << (8 * $1) } }
    private static func u64(_ b: [UInt8], _ o: Int) -> UInt64 { (0..<8).reduce(0) { $0 | UInt64(b[o + $1]) << (8 * $1) } }

    /// A PFS0 (NSP) or HFS0 (XCI partition) at `base`: the files inside, with absolute offsets.
    private static func partition(_ h: FileHandle, base: UInt64, magic: String, entrySize: Int) throws -> [Entry] {
        let head = try read(h, base, 16)
        guard String(bytes: head[0..<4], encoding: .ascii) == magic else {
            throw ConverterError(magic == "PFS0" ? "not an NSP (no PFS0 header)" : "no HFS0 partition header")
        }
        let n = Int(u32(head, 4)), st = Int(u32(head, 8))
        guard n <= 10_000 else { throw ConverterError("\(magic) header is damaged") }
        let t = try read(h, base + 16, n * entrySize + st)
        let strs = Array(t[(n * entrySize)...])
        let data = base + 16 + UInt64(n * entrySize + st)
        return (0..<n).map { i in
            let e = Array(t[(i * entrySize)..<(i * entrySize + 0x18)])
            let no = Int(u32(e, 0x10))
            let end = strs[no...].firstIndex(of: 0) ?? strs.count
            return Entry(name: String(decoding: strs[no..<end], as: UTF8.self), offset: data + u64(e, 0), size: u64(e, 8))
        }
    }

    private static func pfs0(_ h: FileHandle, base: UInt64) throws -> [Entry] { try partition(h, base: base, magic: "PFS0", entrySize: 0x18) }

    private static func xciSecure(_ h: FileHandle) throws -> [Entry] {
        let head = try read(h, 0x100, 0x40)
        guard String(bytes: head[0..<4], encoding: .ascii) == "HEAD" else { throw ConverterError("not an XCI (no HEAD magic)") }
        let root = try partition(h, base: u64(head, 0x30), magic: "HFS0", entrySize: 0x40)
        guard let secure = root.first(where: { $0.name == "secure" }) else { throw ConverterError("the XCI has no secure partition") }
        return try partition(h, base: secure.offset, magic: "HFS0", entrySize: 0x40)
    }

    private static func ticketBase(_ t: [UInt8]) -> Int? {
        guard t.count >= 4 else { return nil }
        let sig = u32(t, 0)
        let (size, pad): (Int, Int)
        switch sig {
        case 0x10000, 0x10003: (size, pad) = (0x200, 0x3C)
        case 0x10001, 0x10004: (size, pad) = (0x100, 0x3C)
        case 0x10002, 0x10005: (size, pad) = (0x3C, 0x40)
        default: return nil
        }
        return 4 + size + pad
    }

    /// The rights ID of a ticket, nil for an unreadable one.
    private static func ticketRights(_ t: [UInt8]) -> [UInt8]? {
        guard let b = ticketBase(t), t.count >= b + 0x170 else { return nil }
        return Array(t[(b + 0x160)..<(b + 0x170)])
    }

    private struct NCAInfo {
        let contentType: UInt8
        let programID: UInt64
        let note: String
    }

    private static let contentNames = ["Program", "Meta", "Control", "Manual", "Data", "PublicData"]

    private static func checkNCA(_ h: FileHandle, _ e: Entry, keys: Keys, headerKey: [UInt8], tickets: [[UInt8]], compressed: Bool) throws -> NCAInfo {
        let hd = AES.xtsDecrypt(try read(h, e.offset, 0xC00), key: headerKey, sectorSize: 0x200)
        guard String(bytes: hd[0x200..<0x203], encoding: .ascii) == "NCA" else {
            throw ConverterError("header does not decrypt: header_key is wrong for this file")
        }
        let ct = hd[0x205]
        let ctype = Int(ct) < contentNames.count ? contentNames[Int(ct)] : "?"
        let programID = u64(hd, 0x210)
        let kg = max(hd[0x206], hd[0x220]) == 0 ? 0 : Int(max(hd[0x206], hd[0x220])) - 1
        let kgs = String(format: "%02x", kg)
        let rights = Array(hd[0x230..<0x240])
        let titleKeyed = rights.contains { $0 != 0 }

        let bodyKey: [UInt8]
        if titleKeyed {
            guard let t = tickets.first(where: { ticketRights($0) == rights }), let base = ticketBase(t) else {
                throw ConverterError("no ticket for this content in the file (and nxnative reads title keys only from tickets)")
            }
            guard t[base + 0x141] == 0 else { throw ConverterError("personalized ticket: needs a console-specific key, convert it to a common ticket first") }
            guard let kek = keys.key("titlekek_\(kgs)") else { throw ConverterError("prod.keys lacks titlekek_\(kgs) (key generation \(kgs): newer keys needed)") }
            bodyKey = AES.ecb(Array(t[(base + 0x40)..<(base + 0x50)]), key: kek, encrypt: false)
        } else {
            let areas = ["application", "ocean", "system"]
            guard Int(hd[0x207]) < areas.count else { throw ConverterError("unknown key area index") }
            let name = "key_area_key_\(areas[Int(hd[0x207])])_\(kgs)"
            guard let kak = keys.key(name) else { throw ConverterError("prod.keys lacks \(name) (key generation \(kgs): newer keys needed)") }
            bodyKey = AES.ecb(Array(hd[0x320..<0x330]), key: kak, encrypt: false)
        }
        let note = "\(ctype) NCA, key generation \(kgs), \(titleKeyed ? "title key" : "key area")"
        if compressed {
            return NCAInfo(contentType: ct, programID: programID, note: "\(note); header and keys OK (compressed: data checked during conversion)")
        }
        // the data: the first CTR-encrypted section with a PFS0 or RomFS (IVFC) layout must decrypt to its magic
        for i in 0..<4 {
            let start = UInt64(u32(hd, 0x240 + i * 0x10)) * 0x200, end = UInt64(u32(hd, 0x244 + i * 0x10)) * 0x200
            guard end > start else { continue }
            let fs = Array(hd[(0x400 + i * 0x200)..<(0x600 + i * 0x200)])
            guard fs[4] == 3 else { continue }
            let sparse = fs[0x148..<0x178].contains { $0 != 0 }
            let rel: UInt64, want: [UInt8]
            if fs[3] == 2 { rel = u64(fs, 0x40); want = Array("PFS0".utf8) }
            else if fs[3] == 3, String(bytes: fs[8..<12], encoding: .ascii) == "IVFC" { rel = u64(fs, 0x18 + 5 * 0x18); want = [0x50, 0, 0, 0, 0, 0, 0, 0] }
            else { continue }
            let off = start + rel, aligned = off & ~0xF
            var iv = [UInt8](repeating: 0, count: 16)
            for j in 0..<8 { iv[j] = fs[0x147 - j] }
            var ctr = aligned >> 4
            for j in 0..<8 { iv[15 - j] = UInt8(ctr & 0xFF); ctr >>= 8 }
            let plain = AES.ctr(try read(h, e.offset + aligned, 0x20), key: bodyKey, iv: iv)
            let s = Int(off - aligned)
            if Array(plain[s..<(s + want.count)]) == want {
                return NCAInfo(contentType: ct, programID: programID, note: "\(note); data decrypts")
            }
            if sparse {
                return NCAInfo(contentType: ct, programID: programID, note: "\(note); header OK (sparse section: data checked during conversion)")
            }
            throw ConverterError("\(note): the data does not decrypt (\(titleKeyed ? "titlekek_\(kgs)" : "the key area key") is wrong, or the file is damaged)")
        }
        return NCAInfo(contentType: ct, programID: programID, note: "\(note); header OK")
    }
}
