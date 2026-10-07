import Foundation
import Testing
@testable import BridgeCore
struct EncoderTests {
    @Test func testBinarySafeTSPLAndWhitePadding() throws {
        let page = RasterPage(width: 9, height: 1, black: Data([0x80,0xff]))
        var expected = Data("SIZE 100 mm,150 mm\r\nGAP 3 mm,0 mm\r\nDIRECTION 0,0\r\nREFERENCE 0,0\r\nCLS\r\nBITMAP 0,0,2,1,0,".utf8)
        // ITPP130B calibration: TSPL bit 0 marks black; padding must be 1 (white).
        expected.append(contentsOf: [0x7f,0x7f])
        expected.append(Data("\r\nPRINT 1,1\r\n".utf8))
        expectEqual(try TSPL.encode(page: page), expected)
    }
    @Test func testSeparateExactFourBySixMedia() throws {
        let output = try TSPL.encode(page: .init(width: 8,height: 1,black: Data([0xf5]),media: .inch4x6))
        #expect(output.starts(with: Data("SIZE 101.6 mm,152.4 mm\r\n".utf8)))
        #expect(output.range(of: Data([0x30,0x2c,0x0a,0x0d,0x0a])) != nil)
    }
    @Test func testDevicePolarityWhiteAndBlackBytes() throws {
        let output = try TSPL.encode(page: .init(width:8,height:2,black:Data([0x00,0xff])))
        var expected = Data("SIZE 100 mm,150 mm\r\nGAP 3 mm,0 mm\r\nDIRECTION 0,0\r\nREFERENCE 0,0\r\nCLS\r\nBITMAP 0,0,1,2,0,".utf8)
        expected.append(contentsOf:[0xff,0x00])
        expected.append(Data("\r\nPRINT 1,1\r\n".utf8))
        #expect(output == expected)
    }
    @Test func testPolarityAndThresholdWithoutDither() throws {
        expectEqual(try Bitmap.pack(row: Data([0x81,0xff]),width: 9,bits: 1,colorSpace: 3), Data([0x81,0x80]))
        expectEqual(try Bitmap.pack(row: Data([0x7e,0x00]),width: 9,bits: 1,colorSpace: 0), Data([0x81,0x80]))
        expectEqual(try Bitmap.pack(row: Data([0,127,128,255,0,255,0,255]),width: 8,bits: 8,colorSpace: 18), Data([0xca]))
        expectEqual(try Bitmap.pack(row: Data([0,127,128,255,0,255,0,255]),width: 8,bits: 8,colorSpace: 3), Data([0x35]))
    }
    @Test func testPaperDirectionMatchesUSBWithoutRotatingRaster() throws {
        // The installed USB filter's normal Rotate=0 setting emits DIRECTION 0,0.
        // Asymmetric rows catch an accidental second bitmap rotation/mirroring.
        let page = RasterPage(width: 8,height: 3,black: Data([0x80,0x40,0x04]),media: .inch4x6)
        var expected = Data("SIZE 101.6 mm,152.4 mm\r\nGAP 3 mm,0 mm\r\nDIRECTION 0,0\r\nREFERENCE 0,0\r\nCLS\r\nBITMAP 0,0,1,3,0,".utf8)
        expected.append(contentsOf: [0x7f,0xbf,0xfb])
        expected.append(Data("\r\nPRINT 1,1\r\n".utf8))
        #expect(try TSPL.encode(page: page) == expected)
    }
    @Test func testRejectBadDimensionsAndPayload() {
        for page in [RasterPage(width: 0,height: 1,black: Data()), .init(width: Int.max,height: 2,black: Data()), .init(width: 8,height: 2,black: Data([0]))] {
            expectThrows(try TSPL.encode(page: page))
        }
        expectThrows(try Bitmap.pack(row: Data([0]),width: 8,bits: 8,colorSpace: 1))
        expectThrows(try Bitmap.pack(row: Data(),width: 8,bits: 1,colorSpace: 3))
    }
    @Test func testStripFramingAndFullLabelLength() throws {
        let output = try TSPL.encode(page: .init(width: 8,height: 101,black: Data(repeating: 0,count: 101)))
        expectNotNil(output.range(of: Data("BITMAP 0,100,1,1,0,".utf8)))
        #expect(output.hasSuffix(Data("\r\nPRINT 1,1\r\n".utf8)))
    }
}
extension Data { func hasSuffix(_ other: Data) -> Bool { suffix(other.count) == other } }

func expectEqual<T: Equatable>(_ a: T, _ b: T) { #expect(a == b) }
func expectNotNil<T>(_ a: T?) { #expect(a != nil) }
func expectThrows(_ expression: @autoclosure () throws -> Any) {
    do { _ = try expression(); Issue.record("Expected rejection") } catch {}
}
