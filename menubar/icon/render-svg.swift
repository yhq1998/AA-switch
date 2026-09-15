// 用 AppKit 把 SVG 渲染成透明背景的 PNG：swift render-svg.swift 输入.svg 输出.png 宽 高
import AppKit

let args = CommandLine.arguments
guard args.count == 5, let width = Int(args[3]), let height = Int(args[4]),
      let image = NSImage(contentsOfFile: args[1]) else {
    FileHandle.standardError.write(Data("用法：render-svg.swift 输入.svg 输出.png 宽 高\n".utf8)); exit(1)
}
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
rep.size = NSSize(width: width, height: height)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high
image.draw(in: NSRect(x: 0, y: 0, width: width, height: height), from: .zero, operation: .sourceOver, fraction: 1)
NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try! png.write(to: URL(fileURLWithPath: args[2]))
