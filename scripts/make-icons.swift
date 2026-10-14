// Genera Resources/AppIcon.png e Resources/MenuIcon.png (template 22pt @2x) da design/icon.svg e design/glyph.svg.
// Uso: swift scripts/make-icons.swift
import AppKit

func render(_ svg: String, _ n: Int, _ out: String) {
    let img = NSImage(contentsOfFile: svg)!
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: n, pixelsHigh: n, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    img.draw(in: NSRect(x: 0, y: 0, width: n, height: n))
    NSGraphicsContext.current = nil
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
}

render("design/icon.svg", 1024, "Resources/AppIcon.png")
render("design/glyph.svg", 44, "Resources/MenuIcon.png")
