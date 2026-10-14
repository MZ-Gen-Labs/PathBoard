import AppKit
import Foundation
let output = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for size in [16,32,64,128,256,512,1024] {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let scale = Double(size) / 1024
    NSColor(calibratedRed: 0.12, green: 0.18, blue: 0.28, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 40*scale, y: 40*scale, width: 944*scale, height: 944*scale), xRadius: 180*scale, yRadius: 180*scale).fill()
    for row in 0..<2 { for column in 0..<2 {
        NSColor(calibratedRed: column == 0 ? 0.30 : 0.40, green: row == 0 ? 0.76 : 0.60, blue: 0.83, alpha: 1).setFill()
        let x = Double(160 + column*370)*scale, y = Double(160 + row*370)*scale
        NSBezierPath(roundedRect: NSRect(x: x, y: y, width: 330*scale, height: 330*scale), xRadius: 48*scale, yRadius: 48*scale).fill()
        NSColor.white.withAlphaComponent(0.85).setFill()
        for line in 0..<3 { NSBezierPath(roundedRect: NSRect(x: x+65*scale, y: y+Double(75+line*65)*scale, width: Double(line == 0 ? 140 : 200)*scale, height: 24*scale), xRadius: 12*scale, yRadius: 12*scale).fill() }
    } }
    image.unlockFocus()
    let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
    let data = bitmap.representation(using: .png, properties: [:])!
    if size <= 512 { try data.write(to: output.appendingPathComponent("icon_\(size)x\(size).png")) }
    if size >= 32 { let half = size/2; try data.write(to: output.appendingPathComponent("icon_\(half)x\(half)@2x.png")) }
}
