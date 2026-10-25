// The three AES modes an NCA uses, on top of CommonCrypto's ECB: XTS for the header (Nintendo's tweak is the
// sector number in big-endian), ECB for title keys and the key area, CTR for section data.
import CommonCrypto
import Foundation

enum AES {
    /// One ECB pass over whole 16-byte blocks.
    static func ecb(_ data: [UInt8], key: [UInt8], encrypt: Bool) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: data.count)
        var moved = 0
        let status = CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                             key, key.count, nil, data, data.count, &out, out.count, &moved)
        precondition(status == kCCSuccess, "AES-ECB failed (\(status))")
        return out
    }

    /// AES-128-XTS decryption of whole sectors; the tweak of sector n is n as a big-endian 128-bit number.
    static func xtsDecrypt(_ data: [UInt8], key: [UInt8], sectorSize: Int, firstSector: Int = 0) -> [UInt8] {
        let k1 = Array(key[0..<16]), k2 = Array(key[16..<32])
        var out = data
        var sector = firstSector
        for start in stride(from: 0, to: data.count, by: sectorSize) {
            var tweakIn = [UInt8](repeating: 0, count: 16)
            var n = UInt64(sector)
            for i in 0..<8 { tweakIn[15 - i] = UInt8(n & 0xFF); n >>= 8 }
            var t = ecb(tweakIn, key: k2, encrypt: true)
            let end = min(start + sectorSize, data.count)
            var blocks = [UInt8](repeating: 0, count: end - start)
            var tweaks: [[UInt8]] = []
            for b in stride(from: start, to: end, by: 16) {
                tweaks.append(t)
                for i in 0..<16 { blocks[b - start + i] = data[b + i] ^ t[i] }
                // T × α in GF(2^128), little-endian as in IEEE 1619
                var carry: UInt8 = 0
                for i in 0..<16 {
                    let next = t[i] >> 7
                    t[i] = (t[i] << 1) | carry
                    carry = next
                }
                if carry != 0 { t[0] ^= 0x87 }
            }
            let dec = ecb(blocks, key: k1, encrypt: false)
            for (j, b) in stride(from: 0, to: dec.count, by: 16).enumerated() {
                for i in 0..<16 { out[start + b + i] = dec[b + i] ^ tweaks[j][i] }
            }
            sector += 1
        }
        return out
    }

    /// AES-128-CTR from a block-aligned counter value.
    static func ctr(_ data: [UInt8], key: [UInt8], iv: [UInt8]) -> [UInt8] {
        var counter = iv
        var stream: [UInt8] = []
        while stream.count < data.count {
            stream += ecb(counter, key: key, encrypt: true)
            for i in stride(from: 15, through: 0, by: -1) {
                counter[i] &+= 1
                if counter[i] != 0 { break }
            }
        }
        return zip(data, stream).map { $0 ^ $1 }
    }
}
