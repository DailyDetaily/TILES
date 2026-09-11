import AppKit
let base = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
let blue = NSColor(srgbRed: 76/255, green: 146/255, blue: 233/255, alpha: 1)
let gray = NSColor(srgbRed: 156/255, green: 163/255, blue: 175/255, alpha: 1)
let filledTiles = [(0, 0), (1, 0), (2, 0), (1, 1), (1, 2)]
let outlinedTiles = [(0, 1), (2, 1), (0, 2), (2, 2)]
for size in [16,32,64,128,256,512,1024] {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let scale = CGFloat(size)/1024
    let transform = NSAffineTransform(); transform.scale(by: scale); transform.concat()
    NSColor.white.setFill(); NSBezierPath(roundedRect: NSRect(x: 24, y: 24, width: 976, height: 976), xRadius: 212, yRadius: 212).fill()
    for (column, row) in filledTiles {
        let x = 140 + CGFloat(column)*255, y = 629 - CGFloat(row)*255
        (column == 0 && row == 0 ? NSColor.black : blue).setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: y, width: 230, height: 230), xRadius: 38, yRadius: 38).fill()
    }
    gray.setStroke()
    for (column, row) in outlinedTiles {
        let x = 140 + CGFloat(column)*255, y = 629 - CGFloat(row)*255
        let path = NSBezierPath(roundedRect: NSRect(x: x + 24, y: y + 24, width: 182, height: 182), xRadius: 30, yRadius: 30)
        path.lineWidth = 48
        path.stroke()
    }
    image.unlockFocus()
    guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("PNG encoding failed") }
    if size <= 512 { try png.write(to: base.appendingPathComponent("icon_\(size)x\(size).png")) }
    if size >= 32 { try png.write(to: base.appendingPathComponent("icon_\(size/2)x\(size/2)@2x.png")) }
}
