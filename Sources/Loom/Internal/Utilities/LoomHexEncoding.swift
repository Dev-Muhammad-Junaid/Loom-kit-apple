//
//  LoomHexEncoding.swift
//  Loom
//
//  Lookup-table hex encoding shared across Loom targets.
//

import CryptoKit
import Foundation

private let hexTable: [UInt8] = {
    let chars = Array("0123456789abcdef".utf8)
    var table = [UInt8](repeating: 0, count: 512)
    for byte in UInt8.min ... UInt8.max {
        let index = Int(byte) * 2
        table[index] = chars[Int(byte >> 4)]
        table[index + 1] = chars[Int(byte & 0x0F)]
    }
    return table
}()

package enum LoomHex {
    package static func encode<S: Sequence<UInt8>>(_ bytes: S) -> String {
        var utf8: [UInt8] = []
        for byte in bytes {
            let index = Int(byte) * 2
            utf8.append(hexTable[index])
            utf8.append(hexTable[index + 1])
        }
        return String(bytes: utf8, encoding: .ascii) ?? ""
    }

    package static func sha256Hex(_ data: Data) -> String {
        encode(SHA256.hash(data: data))
    }
}
