import AppKit
import CoreImage
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/munbyn-synthetic"
try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
for (name, mm) in [("100x150",(100.0,150.0)),("4x6",(101.6,152.4)),
                   ("100x150-landscape",(150.0,100.0)),("4x6-landscape",(152.4,101.6))] {
    var box = CGRect(x: 0,y: 0,width: mm.0 / 25.4 * 72,height: mm.1 / 25.4 * 72)
    let url = URL(fileURLWithPath: output).appendingPathComponent(name + ".pdf")
    let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
    for page in 1...2 {
        ctx.beginPDFPage(nil)
        ctx.setFillColor(CGColor(gray: 1,alpha: 1)); ctx.fill(box)
        ctx.setStrokeColor(CGColor(gray: 0,alpha: 1)); ctx.setLineWidth(0.7)
        ctx.stroke(box.insetBy(dx: 14,dy: 14))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx,flipped: false)
        ("SYNTHETIC TEST ONLY\nMUNBYN BLE Bridge\nPage \(page) of 2\n\(name) media" as NSString).draw(at: CGPoint(x: 28,y: box.height - 110),withAttributes: [.font:NSFont.systemFont(ofSize: 14),.foregroundColor:NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        ctx.setFillColor(CGColor(gray: 0,alpha: 1))
        ctx.fill(CGRect(x: 28,y: box.height - 140,width: 200.0 / 203 * 72,height: 8))
        let filter = CIFilter(name:"CIQRCodeGenerator")!
        filter.setValue(Data("MUNBYN-BRIDGE-SYNTHETIC-PAGE-\(page)".utf8),forKey:"inputMessage")
        filter.setValue("M",forKey:"inputCorrectionLevel")
        let image = CIContext().createCGImage(filter.outputImage!,from: filter.outputImage!.extent)!
        ctx.interpolationQuality = .none
        let landscape = box.width > box.height
        ctx.draw(image,in: CGRect(x: 28,y: landscape ? 28 : 90,width: 90,height: 90))
        ctx.endPDFPage()
    }
    ctx.closePDF()
    print(url.path)
}
