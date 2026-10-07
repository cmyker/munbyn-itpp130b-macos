import Foundation
import Testing
@testable import BridgeCore

struct CalibrationTests {
    @Test func calibrationRulerRetainsTwoHundredDotsAcrossSixteenRows() throws {
        // A one-row diagnostic was physically too faint to measure. These
        // hand-derived packed rows catch shortening, shifting or thinning it.
        for (media, width, height, frameByte, frameMask) in [
            (Media.mm100x150, 799, 1199, 97, UInt8(0x20)),
            (Media.inch4x6, 812, 1218, 98, UInt8(0x01))
        ] {
            let page = Calibration.page(media: media)
            try #require(page.width == width)
            try #require(page.height == height)
            #expect(page.media == media)
            try page.validate()

            var frameRow = Data(repeating: 0, count: media == .mm100x150 ? 100 : 102)
            frameRow[2] = 0x08 // x=20
            frameRow[frameByte] = frameMask // x=778 or x=791
            var rulerRow = frameRow
            // x=40...239 is exactly 25 complete bytes = 200 black dots.
            rulerRow.replaceSubrange(5..<30, with: Data(repeating: 0xff, count: 25))
            for y in 80..<96 {
                let row = page.black.subdata(in: (y * frameRow.count)..<((y + 1) * frameRow.count))
                #expect(row == rulerRow)
            }
            for y in [79, 96] {
                let row = page.black.subdata(in: (y * frameRow.count)..<((y + 1) * frameRow.count))
                #expect(row == frameRow)
            }
        }
    }
}
