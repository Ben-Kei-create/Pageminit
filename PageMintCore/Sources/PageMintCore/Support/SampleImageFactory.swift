import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// テスト・スパイク用の合成画像生成 (実画像フィクスチャは別途用意する)。
public enum SampleImageFactory {
    public static func writePNG(to url: URL, width: Int, height: Int, hue: CGFloat = 0.45) throws {
        try write(to: url, width: width, height: height, hue: hue, type: .png)
    }

    public static func writeJPEG(to url: URL, width: Int, height: Int, hue: CGFloat = 0.1) throws {
        try write(to: url, width: width, height: height, hue: hue, type: .jpeg)
    }

    private static func write(to url: URL, width: Int, height: Int, hue: CGFloat, type: UTType) throws {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw CocoaError(.fileWriteUnknown) }
        ctx.setFillColor(CGColor(red: 0.95, green: 0.94, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(red: hue, green: 0.7, blue: 0.6, alpha: 1))
        ctx.fill(CGRect(x: width / 8, y: height / 8, width: width * 3 / 4, height: height * 3 / 4))
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }
}
