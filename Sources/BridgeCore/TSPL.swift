import Foundation
/// ITPP130B BITMAP uses zero for black; internal/PBM pages use one for black.
/// The direction command matches the USB filter, but physical output orientation
/// is still unresolved. Gap and head geometry require physical calibration.
public enum TSPL {
    public static func encode(page: RasterPage) throws -> Data {
        try page.validate()
        let size = page.media == .mm100x150 ? "100 mm,150 mm" : "101.6 mm,152.4 mm"
        var result = Data("SIZE \(size)\r\nGAP 3 mm,0 mm\r\nDIRECTION 0,0\r\nREFERENCE 0,0\r\nCLS\r\n".utf8)
        for first in stride(from: 0,to: page.height,by: 100) {
            let rows = min(100,page.height - first)
            result.append(Data("BITMAP 0,\(first),\(page.rowBytes),\(rows),0,".utf8))
            for y in first..<(first + rows) {
                var row = page.black.subdata(in: (y * page.rowBytes)..<((y + 1) * page.rowBytes))
                if page.width % 8 != 0 { row[row.count - 1] &= UInt8(0xff << (8 - page.width % 8) & 0xff) }
                result.append(contentsOf: row.map { ~$0 })
            }
            result.append(Data("\r\n".utf8))
        }
        result.append(Data("PRINT 1,1\r\n".utf8))
        return result
    }
}
