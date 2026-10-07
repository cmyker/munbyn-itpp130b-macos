import Foundation

public enum Calibration {
    public static func page(media: Media) -> RasterPage {
        let width = media == .mm100x150 ? 799 : 812
        let height = media == .mm100x150 ? 1199 : 1218
        let rowBytes = (width + 7) / 8
        var bitmap = Data(repeating: 0, count: rowBytes * height)
        for y in 20..<(height - 20) {
            for x in 20..<(width - 20)
            where y == 20 || y == height - 21 || x == 20 || x == width - 21 || ((80..<96).contains(y) && (40..<240).contains(x)) {
                bitmap[y * rowBytes + x / 8] |= UInt8(0x80 >> (x % 8))
            }
        }
        return RasterPage(width: width, height: height, black: bitmap, media: media)
    }
}
