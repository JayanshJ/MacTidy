#!/bin/sh
# Regenerate Support/AppIcon.icns from assets/logo.svg.
#
# The generated .icns is committed, so you only need this after editing the
# logo. Rasterizing goes through AppKit's NSImage (which reads SVG on macOS
# 11+) so there's no dependency on rsvg/Inkscape/ImageMagick.
#
# Note: NSImage's SVG parser drops `fill-opacity` on elements that inherit
# `fill` from a parent <g>. assets/logo.svg sets both per element to avoid
# flattening the icon to solid white — keep it that way.
set -eu

cd "$(dirname "$0")/.."
SVG="assets/logo.svg"
ICONSET="$(mktemp -d)/AppIcon.iconset"
RENDER="$(mktemp -d)/render.swift"
mkdir -p "$ICONSET"

cat > "$RENDER" <<'SWIFT'
import AppKit
let src = CommandLine.arguments[1], out = CommandLine.arguments[2]
let size = Int(CommandLine.arguments[3])!
guard let img = NSImage(contentsOfFile: src) else {
    FileHandle.standardError.write("cannot load \(src)\n".data(using: .utf8)!); exit(1)
}
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                           isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: size, height: size)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high
img.draw(in: NSRect(x: 0, y: 0, width: size, height: size),
         from: .zero, operation: .sourceOver, fraction: 1.0)
NSGraphicsContext.restoreGraphicsState()
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
SWIFT

render() { swift "$RENDER" "$SVG" "$ICONSET/$2" "$1"; }

render 16   icon_16x16.png
render 32   icon_16x16@2x.png
render 32   icon_32x32.png
render 64   icon_32x32@2x.png
render 128  icon_128x128.png
render 256  icon_128x128@2x.png
render 256  icon_256x256.png
render 512  icon_256x256@2x.png
render 512  icon_512x512.png
render 1024 icon_512x512@2x.png

iconutil -c icns "$ICONSET" -o Support/AppIcon.icns
echo "Wrote Support/AppIcon.icns"
