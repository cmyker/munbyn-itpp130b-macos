import Foundation
import CBridge
public enum RasterReader {
    public static func read(fd: Int32,maxBytes: Int = 64 * 1024 * 1024,timeout: Double = 60,onPageRead: (() -> Void)? = nil) throws -> [RasterPage] {
        guard maxBytes > 0, let reader = mb_raster_open(fd,UInt64(maxBytes),timeout) else {
            throw BridgeError.invalid("Unsupported, empty, truncated or timed-out raster stream; expected CUPS raster v3")
        }
        defer { mb_raster_close(reader) }
        var pages: [RasterPage] = []; var counts: [Int] = []; var collated: Bool?
        while true {
            var h = cups_page_header2_t()
            let result = mb_raster_header(reader,&h)
            if result == 0 { break }
            guard result == 1 else { throw BridgeError.invalid("Invalid or truncated raster header") }
            let w = Int(h.cupsWidth), height = Int(h.cupsHeight), bits = Int(h.cupsBitsPerColor)
            let cs = Int(h.cupsColorSpace.rawValue)
            guard pages.count < 32, h.HWResolution.0 == 203, h.HWResolution.1 == 203,
                  h.cupsColorOrder == CUPS_ORDER_CHUNKED, [0,3,18].contains(cs),
                  [1,8].contains(bits), h.cupsBitsPerPixel == h.cupsBitsPerColor, h.cupsNumColors == 1,
                  (1...832).contains(w), (1...1300).contains(height),
                  Int(h.cupsBytesPerLine) == (w * bits + 7) / 8,
                  h.NumCopies <= 16 else { throw BridgeError.invalid("Unsupported raster metadata or safety limit") }
            let points = (Double(h.cupsPageSize.0),Double(h.cupsPageSize.1))
            guard points.0.isFinite,points.1.isFinite else { throw BridgeError.invalid("Invalid physical media") }
            let media: Media
            if abs(points.0 - 283.464567) < 0.1 && abs(points.1 - 425.196850) < 0.1 { media = .mm100x150 }
            else if abs(points.0 - 288) < 0.1 && abs(points.1 - 432) < 0.1 { media = .inch4x6 }
            else { throw BridgeError.invalid("Only portrait physical 100 x 150 mm and 4 x 6 inch media supported; CUPS rotates content") }
            let expected = media == .mm100x150 ? (799,1199) : (812,1218)
            guard abs(w - expected.0) <= 1, abs(height - expected.1) <= 1 else { throw BridgeError.invalid("Raster dimensions inconsistent with media") }
            let shouldCollate = h.Collate == CUPS_TRUE
            if let previous = collated, previous != shouldCollate { throw BridgeError.invalid("Inconsistent collation metadata") }
            collated = shouldCollate
            var black = Data(); black.reserveCapacity((w + 7) / 8 * height)
            var row = [UInt8](repeating: 0,count: Int(h.cupsBytesPerLine))
            for _ in 0..<height {
                guard mb_raster_pixels(reader,&row,h.cupsBytesPerLine) == h.cupsBytesPerLine else { throw BridgeError.invalid("Truncated raster pixels") }
                black.append(try Bitmap.pack(row: Data(row),width: w,bits: bits,colorSpace: cs))
            }
            pages.append(.init(width: w,height: height,black: black,media: media))
            counts.append(max(1,Int(h.NumCopies)))
            onPageRead?() // Progress only; complete EOF and whole-job validation still required.
        }
        guard !pages.isEmpty, counts.reduce(0,+) <= 64 else { throw BridgeError.invalid("Empty or excessive label job") }
        if collated == true {
            guard Set(counts).count == 1 else { throw BridgeError.invalid("Inconsistent copy count for collation") }
            return (0..<counts[0]).flatMap { _ in pages }
        }
        return zip(pages,counts).flatMap { page,count in Array(repeating: page,count: count) }
    }
}
