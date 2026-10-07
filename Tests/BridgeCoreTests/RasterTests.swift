import Foundation
import Testing
import CBridge
@testable import BridgeCore

func rasterFixture(copies: UInt32 = 1, collate: UInt32 = 0, width: UInt32 = 799, bits: UInt32 = 1, cs: cups_cspace_t = CUPS_CSPACE_K, order: cups_order_t = CUPS_ORDER_CHUNKED, bpl: UInt32? = nil) throws -> Data {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let fd = open(url.path,O_CREAT | O_RDWR | O_TRUNC,0o600)
    guard fd >= 0, let raster = cupsRasterOpen(fd,CUPS_RASTER_WRITE) else { throw BridgeError.invalid("Fixture open failed") }
    defer { cupsRasterClose(raster); close(fd); try? FileManager.default.removeItem(at: url) }
    for byte: UInt8 in [0x80,0x40] {
        var h = cups_page_header2_t()
        h.cupsWidth = width; h.cupsHeight = 1199
        h.HWResolution = (203,203); h.cupsPageSize = (283.46457,425.19685)
        h.PageSize = (283,425); h.cupsBitsPerColor = bits; h.cupsBitsPerPixel = bits
        h.cupsColorSpace = cs; h.cupsColorOrder = order; h.cupsNumColors = 1
        h.cupsBytesPerLine = bpl ?? ((width * bits + 7) / 8); h.NumCopies = copies; h.Collate = cups_bool_t(rawValue: collate)
        guard cupsRasterWriteHeader2(raster,&h) == 1 else { throw BridgeError.invalid("Fixture header") }
        var row = [UInt8](repeating: 0,count: Int(h.cupsBytesPerLine)); row[0] = byte
        for _ in 0..<1199 { _ = cupsRasterWritePixels(raster,&row,h.cupsBytesPerLine) }
    }
    return try Data(contentsOf: url)
}
func readRaster(_ data: Data, maxBytes: Int = 64 * 1024 * 1024) throws -> [RasterPage] {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try data.write(to: url)
    let fd = open(url.path,O_RDONLY); defer { close(fd); try? FileManager.default.removeItem(at: url) }
    return try RasterReader.read(fd: fd,maxBytes: maxBytes)
}
struct RasterTests {
    @Test func parsesNativeAPIFixtureWithoutChangingBinaryPixels() throws {
        let pages = try readRaster(rasterFixture())
        #expect(pages.count == 2)
        #expect(pages.first?.width == 799); #expect(pages.first?.height == 1199)
        #expect(pages.first?.black.prefix(2) == Data([0x80,0]))
    }
    @Test func collatedAndUncollatedHeaderCopiesAppliedOnce() throws {
        let collated = try readRaster(rasterFixture(copies: 2,collate: 1))
        #expect(collated.map { $0.black[0] } == [0x80,0x40,0x80,0x40])
        let uncollated = try readRaster(rasterFixture(copies: 2))
        #expect(uncollated.map { $0.black[0] } == [0x80,0x80,0x40,0x40])
    }
    @Test func truncatedPixelsAndHeadersRejected() throws {
        let fixture = try rasterFixture()
        expectThrows(try readRaster(fixture.dropLast()))
        expectThrows(try readRaster(fixture.prefix(20)))
        expectThrows(try readRaster(fixture + Data([0])))
        expectThrows(try readRaster(Data()))
    }
    @Test func unsupportedVariantsFormatsAndLimitsRejected() throws {
        expectThrows(try readRaster(Data("2SaR".utf8)))
        expectThrows(try readRaster(rasterFixture(width: 900)))
        expectThrows(try readRaster(rasterFixture(cs: CUPS_CSPACE_RGB)))
        expectThrows(try readRaster(rasterFixture(order: CUPS_ORDER_PLANAR)))
        expectThrows(try readRaster(rasterFixture(bpl: 101)))
        expectThrows(try readRaster(rasterFixture(copies: 17)))
        expectThrows(try readRaster(rasterFixture(),maxBytes: 100))
    }
}
