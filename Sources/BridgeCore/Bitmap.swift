import Foundation
public enum BridgeError: Error, CustomStringConvertible {
    case invalid(String)
    public var description: String { if case .invalid(let s) = self { return s }; return "Bridge error" }
}
public enum Media: String, Codable, CaseIterable { case mm100x150, inch4x6
    public var size: (Double, Double) { self == .mm100x150 ? (100,150) : (101.6,152.4) }
}
public struct RasterPage: Codable, Equatable {
    public var width: Int; public var height: Int; public var black: Data; public var media: Media
    public init(width: Int, height: Int, black: Data, media: Media = .mm100x150) {
        self.width = width; self.height = height; self.black = black; self.media = media
    }
    public var rowBytes: Int { (width + 7) / 8 }
}
public enum Bitmap {
    public static func pack(row: Data, width: Int, bits: Int, colorSpace: Int) throws -> Data {
        guard (1...832).contains(width), [1,8].contains(bits), [0,3,18].contains(colorSpace),
              row.count == (width * bits + 7) / 8 else { throw BridgeError.invalid("Unsupported monochrome row") }
        var packed = Data(repeating: 0, count: (width + 7) / 8)
        if bits == 1 {
            packed = colorSpace == 3 ? row : Data(row.map { $0 ^ 0xff })
        } else {
            for x in 0..<width {
                let ink = colorSpace == 3 ? row[x] >= 128 : row[x] < 128
                if ink { packed[x / 8] |= UInt8(0x80 >> (x % 8)) }
            }
        }
        if width % 8 != 0 { packed[packed.count - 1] &= UInt8(0xff << (8 - width % 8) & 0xff) }
        return packed
    }
}

public extension RasterPage {
    func validate() throws {
        guard (1...832).contains(width), (1...1300).contains(height), black.count == rowBytes * height else {
            throw BridgeError.invalid("Invalid bitmap dimensions or length")
        }
    }
    var pbm: Data { Data("P4\n\(width) \(height)\n".utf8) + black }
}
