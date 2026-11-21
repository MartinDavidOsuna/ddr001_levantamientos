// macOS-only synthetic optical fixtures; no network or production labels.
// swift tool/hydrostatic/qr_fixtures.swift /tmp/hydrostatic-qr
import AppKit
import CoreImage
let directory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/hydrostatic-qr"
try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
let fixtures = [
    ("01-valid-test", "https://id.aquafim.com/ddr001/AQ26980015"),
    ("02-invalid-digit-test", "https://id.aquafim.com/ddr001/AQ26980010"),
    ("03-invalid-host-test", "https://example.invalid/ddr001/AQ26980015")
]
for (name, payload) in fixtures {
    let filter = CIFilter(name: "CIQRCodeGenerator")!
    filter.setValue(Data(payload.utf8), forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    let code = filter.outputImage!
    let padded = code.composited(over: CIImage(color: .white).cropped(to: code.extent.insetBy(dx: -4, dy: -4)))
    let scaled = padded.transformed(by: CGAffineTransform(scaleX: 16, y: 16))
    let image = CIContext().createCGImage(scaled, from: scaled.extent)!
    let bitmap = NSBitmapImageRep(cgImage: image)
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(directory)/\(name).png"))
}
