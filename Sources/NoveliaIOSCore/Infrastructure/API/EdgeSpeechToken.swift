// SPDX-License-Identifier: LGPL-3.0-only
// Token algorithm adapted from rany2/edge-tts drm.py, Copyright (c) 2025- rany <rany@riseup.net>.
// Swift adaptation: Copyright (C) 2026 Novelia iOS contributors; modified 2026-11-04.
// Upstream commit: bd44c1d1aaebdc1db7f47456ee12431b42ec7cac
// License and attribution: iOSApp/Resources/ThirdPartyLicenses/edge-tts-LICENSE.txt
import Foundation

/// Edge 公开客户端协议的时间令牌；不是用户凭据，不从钥匙串或浏览器读取身份。
enum EdgeSpeechToken {
    private static let initial: [UInt32] = [0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A, 0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19]
    private static let seed: [UInt32] = [0xFD9FBEA2, 0x91243CE7, 0xBE499094, 0xCD2E1E0A, 0x6C006F49, 0x04BD35AB, 0xFEB0A7E4, 0x03EFFBD2]
    private static let scheduleSeed: [UInt32] = [0xEB24BF9E, 0x1558691F, 0xA0C09EE2, 0x0CFA32BA, 0xA622EE8C, 0xD1DD9491, 0xC0DD25A0, 0xF9E70AB6, 0xF0C31573, 0x7058CE4E, 0x7188E606, 0x00E5AB33, 0xD258B060, 0x72766564]
    private static let constants: [UInt32] = [0x428A2F98, 0x71374491, 0xB5C0FBCF, 0xE9B5DBA5, 0x3956C25B, 0x59F111F1, 0x923F82A4, 0xAB1C5ED5, 0xD807AA98, 0x12835B01, 0x243185BE, 0x550C7DC3, 0x72BE5D74, 0x80DEB1FE, 0x9BDC06A7, 0xC19BF174, 0xE49B69C1, 0xEFBE4786, 0x0FC19DC6, 0x240CA1CC, 0x2DE92C6F, 0x4A7484AA, 0x5CB0A9DC, 0x76F988DA, 0x983E5152, 0xA831C66D, 0xB00327C8, 0xBF597FC7, 0xC6E00BF3, 0xD5A79147, 0x06CA6351, 0x14292967, 0x27B70A85, 0x2E1B2138, 0x4D2C6DFC, 0x53380D13, 0x650A7354, 0x766A0ABB, 0x81C2C92E, 0x92722C85, 0xA2BFE8A1, 0xA81A664B, 0xC24B8B70, 0xC76C51A3, 0xD192E819, 0xD6990624, 0xF40E3585, 0x106AA070, 0x19A4C116, 0x1E376C08, 0x2748774C, 0x34B0BCB5, 0x391C0CB3, 0x4ED8AA4A, 0x5B9CCA4F, 0x682E6FF3, 0x748F82EE, 0x78A5636F, 0x84C87814, 0x8CC70208, 0x90BEFFFA, 0xA4506CEB, 0xBEF9A3F7, 0xC67178F2]
    private static let coefficients: [(UInt32, UInt32)] = [(0xE82E91B1, 0xB32700D0), (0x44DE24C6, 0x88DFF51D), (0x3BEB65BC, 0x29514038), (0xC89C5933, 0xB328CBDF), (0x8D1EC211, 0xD405B4D5), (0x314EF5D5, 0x26E55F3C), (0xE92491B1, 0x607801C6), (0xF0A5B9D5, 0x82B2C1FB), (0x06064CF3, 0xFA51A3DA), (0xDA79FA60, 0x207CC464), (0xBED20560, 0x3C3C74F3), (0x89F9C9F8, 0xD2D14B61), (0x35FA38C6, 0xBB04A2C1), (0xCB49E3C6, 0xC5626167)]

    private static func rotate(_ x: UInt32, _ bits: UInt32) -> UInt32 { (x >> bits) | (x << (32 - bits)) }
    private static func swap(_ x: UInt32) -> UInt32 { (x << 16) | (x >> 16) }
    private static func small0(_ x: UInt32) -> UInt32 { rotate(x, 7) ^ rotate(x, 18) ^ (x >> 3) }
    private static func small1(_ x: UInt32) -> UInt32 { rotate(x, 17) ^ rotate(x, 19) ^ (x >> 10) }
    private static func expand(_ words: inout [UInt32], from start: Int = 16) {
        for i in start..<64 { words.append(small1(words[i-2]) &+ words[i-7] &+ small0(words[i-15]) &+ words[i-16]) }
    }
    private static func rounds(_ state: [UInt32], _ words: [UInt32], from start: Int = 0) -> [UInt32] {
        var a=state[0], b=state[1], c=state[2], d=state[3], e=state[4], f=state[5], g=state[6], h=state[7]
        for i in start..<64 {
            let k: UInt32 = start == 14 && i == 14 ? 0xC9DC06A7 : constants[i]
            let t1 = h &+ (rotate(e,6) ^ rotate(e,11) ^ rotate(e,25)) &+ ((e & f) ^ (~e & g)) &+ k &+ words[i]
            let t2 = (rotate(a,2) ^ rotate(a,13) ^ rotate(a,22)) &+ ((a & b) ^ (a & c) ^ (b & c))
            h=g; g=f; f=e; e=d &+ t1; d=c; c=b; b=a; a=t1 &+ t2
        }
        return [a,b,c,d,e,f,g,h]
    }
    private static func bigWord(_ bytes: [UInt8]) -> UInt32 { bytes.reduce(0) { ($0 << 8) | UInt32($1) } }
    private static func littleWord(_ bytes: [UInt8]) -> UInt32 { bigWord(Array(bytes.reversed())) }
    private static func bytes(_ value: UInt32, little: Bool = false) -> [UInt8] {
        let result = [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
        return little ? Array(result.reversed()) : result
    }
    private static func digest(_ data: [UInt8]) -> [UInt8] {
        var words = [UInt32](repeating: 0, count: 14)
        words.append(bigWord(Array(data[0..<3]))); words.append(bigWord(Array(data[3..<7])))
        for i in 16..<30 {
            var v = scheduleSeed[i-16]
            if i-2 >= 14 { v = v &+ (small1(words[i-2]) ^ (i == 16 ? 0x000B92C0 : 0)) }
            if i-7 >= 14 { v = v &+ words[i-7] }
            if i-15 >= 14 { v = v &+ (small0(words[i-15]) ^ (i == 29 ? 0x059C0B80 : 0)) }
            words.append(v)
        }
        words.append(small1(words[28]) &+ words[23] &+ small0(words[15]) &+ words[14] &+ 0xC9DC06A7 &- constants[14])
        expand(&words, from: 31)
        var state = zip(initial, rounds(seed, words, from: 14)).map { $0 &+ $1 }
        var padded = Array(data.dropFirst(7)); padded.append(0x80)
        while padded.count % 64 != 56 { padded.append(0) }
        let bitLength = UInt64(57 + data.count) * 8
        padded += (0..<8).reversed().map { UInt8(truncatingIfNeeded: bitLength >> ($0 * 8)) }
        for offset in stride(from: 0, to: padded.count, by: 64) {
            var block = stride(from: offset, to: offset + 64, by: 4).map { bigWord(Array(padded[$0..<($0+4)])) }
            expand(&block)
            state = zip(state, rounds(state, block)).map { $0 &+ $1 }
        }
        return state.flatMap { bytes($0) }
    }
    private static func cs64(_ data: [UInt8], digest: [UInt8]) -> [UInt8] {
        let a = littleWord(Array(digest[0..<4])) | 1, b = littleWord(Array(digest[4..<8])) | 1
        let factors = [a &* 0x82893933, b &* 0x82893933]
        var terms = coefficients.enumerated().map { $0.element.0 &* factors[$0.offset % 2] }
        var offsets = coefficients.map { $0.1 }
        var padded: [UInt8] = [0] + data
        while padded.count % 8 != 0 { padded.append(0) }
        for i in stride(from: 0, to: padded.count, by: 4) {
            let word = littleWord(Array(padded[i..<(i+4)])), even = i % 8 == 0
            var term = word &* (even ? a : b)
            var offset = swap(word) &* (even ? 0xEF0569FB : 0xC31713DB)
            if i == 0 { term = term &+ (0xF2F90B1A &* factors[0]); offset = offset &+ 0x0B1A0000 }
            terms.append(term); offsets.append(offset)
        }
        var swapped: UInt32=0, last: UInt32=0, state: UInt32=0, acc: UInt32=0
        for i in stride(from: 0, to: terms.count, by: 2) {
            let q0 = swap(offsets[i] &+ terms[i]) &* 0x76F50F34
            swapped = swapped &+ (swap(q0) &* 0xC3EFEA97 &+ q0)
            let q1 = swap(offsets[i+1] &+ terms[i+1]) &* 0x1881CE3C
            last = swap(q1) &* 0x35BD1EC9 &+ q1
            swapped = swapped &+ last
            state = state &* a &+ terms[i]
            for factor: UInt32 in [0xCF98B111,0x87085B9F,0x12CEB96D,0x257E1D83] { state = swap(state) &* factor }
            acc = acc &+ state
            var t = state &* b &+ terms[i+1]
            t = swap(t) &* 0xA27416F5; t = swap(t) &* 0xD38396FF
            state = swap(swap(t) &* 0x7C932B89) &* 0xBFA49F69
            acc = acc &+ state
        }
        return bytes(last ^ state, little: true) + bytes(swapped ^ acc, little: true)
    }
    static func value(at date: Date, clientToken: String) -> String {
        let windows = date.timeIntervalSince1970 + 11_644_473_600
        let ticks = UInt64(floor(windows / 300) * 300 * 10_000_000)
        let data = Array((String(ticks) + clientToken).utf8)
        let hash = digest(data)
        func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02X", $0) }.joined() }
        return hex(cs64(data, digest: hash)) + "-" + hex(hash)
    }
}
