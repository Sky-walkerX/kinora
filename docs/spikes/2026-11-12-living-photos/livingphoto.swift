// THROWAWAY SPIKE: turn a still photo into a seamlessly looping "living" wallpaper video.
// Subject lift (Vision) -> hole fill (blur) -> two-layer parallax on a figure-eight -> HEVC.
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Vision

let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: livingphoto <photo> <out.mov> [seconds] [width] [height]"); exit(64) }
let input = URL(fileURLWithPath: args[1]), output = URL(fileURLWithPath: args[2])
let seconds = args.count > 3 ? Double(args[3])! : 12
let outW = args.count > 4 ? Double(args[4])! : 2940, outH = args.count > 5 ? Double(args[5])! : 1912
let fps = 30.0
let debugDir = output.deletingLastPathComponent()
let context = CIContext(options: [.cacheIntermediates: false])

func png(_ image: CIImage, _ name: String) {
    try? context.writePNGRepresentation(of: image, to: debugDir.appendingPathComponent(name), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
}

// 1. The photo, scaled to cover the wallpaper plus 8% overscan so motion never shows an edge.
guard var photo = CIImage(contentsOf: input, options: [.applyOrientationProperty: true]) else { print("cannot read photo"); exit(1) }
let overscan = 1.08
let coverScale = max(outW * overscan / photo.extent.width, outH * overscan / photo.extent.height)
photo = photo.transformed(by: CGAffineTransform(scaleX: coverScale, y: coverScale))
photo = photo.transformed(by: CGAffineTransform(translationX: -photo.extent.minX, y: -photo.extent.minY))
let canvas = photo.extent
print("canvas \(Int(canvas.width))x\(Int(canvas.height))")

// 2. Subject mask from Vision.
let started = Date()
var mask = CIImage(color: .black).cropped(to: canvas)
guard let cg = context.createCGImage(photo, from: canvas) else { exit(1) }
let request = VNGenerateForegroundInstanceMaskRequest()
let handler = VNImageRequestHandler(cgImage: cg)
try handler.perform([request])
if let observation = request.results?.first, !observation.allInstances.isEmpty {
    let buffer = try observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler)
    mask = CIImage(cvPixelBuffer: buffer)
    print("subject instances: \(observation.allInstances.count), mask in \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
} else {
    print("no subject found; the photo moves as one layer")
}
// Pull the edge in a little first, so the subject layer carries none of the background behind it.
let softMask = mask.applyingFilter("CIMorphologyMinimum", parameters: ["inputRadius": 2.0])
    .clampedToExtent().applyingGaussianBlur(sigma: 1.5).cropped(to: canvas)
png(softMask, "mask.png")

// 3. Background with the subject's place filled: grow the mask, put a heavy blur of the photo there.
let grown = mask.applyingFilter("CIMorphologyMaximum", parameters: ["inputRadius": canvas.width * 0.012])
    .clampedToExtent().applyingGaussianBlur(sigma: canvas.width * 0.006).cropped(to: canvas)
// Normalized convolution: blur(photo x keep) / blur(keep), so the hole takes only the colours around it.
let keep = grown.applyingFilter("CIColorInvert")
let kept = photo.applyingFilter("CIMultiplyCompositing", parameters: ["inputBackgroundImage": keep])
// Fill at three scales: nearby pixels win where they reach, the wide blur only fills what is left.
func normalizedFill(_ sigma: Double) -> (fill: CIImage, confidence: CIImage) {
    let numerator = kept.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: canvas)
    let denominator = keep.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: canvas)
    let safe = denominator.applyingFilter("CIColorClamp", parameters: ["inputMinComponents": CIVector(x: 0.02, y: 0.02, z: 0.02, w: 1)])
    let fill = safe.applyingFilter("CIDivideBlendMode", parameters: ["inputBackgroundImage": numerator])
    // Confidence ramps from 0 at 15% coverage to 1 at 45%.
    let confidence = denominator.applyingFilter("CIColorMatrix", parameters: [
        "inputRVector": CIVector(x: 3.33, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 3.33, z: 0, w: 0),
        "inputBVector": CIVector(x: 0, y: 0, z: 3.33, w: 0), "inputBiasVector": CIVector(x: -0.5, y: -0.5, z: -0.5, w: 0),
    ]).applyingFilter("CIColorClamp")
    return (fill, confidence)
}
var fill = normalizedFill(canvas.width * 0.04).fill
for sigma in [canvas.width * 0.015, canvas.width * 0.006] {
    let level = normalizedFill(sigma)
    fill = level.fill.applyingFilter("CIBlendWithMask", parameters: ["inputBackgroundImage": fill, "inputMaskImage": level.confidence])
}
let background = fill.applyingFilter("CIBlendWithMask", parameters: ["inputBackgroundImage": photo, "inputMaskImage": grown])
let subject = photo.applyingFilter("CIBlendWithMask", parameters: ["inputBackgroundImage": CIImage.empty(), "inputMaskImage": softMask])
png(background, "background.png")

// 4. A frame at loop phase t in [0, 1): figure-eight camera path; the subject moves 2.5x the
//    background, which reads as depth. sin(2πt) and sin(4πt) both return to start, so it loops.
func subjectBounds() -> CGRect? {
    let small = 256.0, scale = small / max(canvas.width, canvas.height)
    let tiny = mask.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    let w = Int(tiny.extent.width), h = Int(tiny.extent.height)
    var pixels = [UInt8](repeating: 0, count: w * h)
    context.render(tiny, toBitmap: &pixels, rowBytes: w, bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .L8, colorSpace: nil)
    var minX = w, minY = h, maxX = -1, maxY = -1
    for y in 0..<h { for x in 0..<w where pixels[y * w + x] > 127 { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) } }
    guard maxX >= minX else { return nil }
    // Bitmap rows run top to bottom; Core Image's y runs bottom to top.
    return CGRect(x: Double(minX) / scale, y: canvas.height - Double(maxY + 1) / scale,
                  width: Double(maxX - minX + 1) / scale, height: Double(maxY - minY + 1) / scale)
}
var center = CGPoint(x: canvas.midX, y: canvas.midY)
if let subject = subjectBounds() {
    let headroom = outH * 0.08
    // The crop's top sits headroom above the subject's top; then clamp inside the canvas.
    var cy = subject.maxY + headroom - outH / 2
    cy = min(max(cy, outH / 2 + canvas.height * 0.02), canvas.height - outH / 2 - canvas.height * 0.02)
    var cx = subject.midX
    cx = min(max(cx, outW / 2 + canvas.width * 0.02), canvas.width - outW / 2 - canvas.width * 0.02)
    center = CGPoint(x: cx, y: cy)
    print("subject \(Int(subject.width))x\(Int(subject.height)) at \(Int(subject.minX)),\(Int(subject.minY)); crop centre \(Int(cx)),\(Int(cy))")
}
func layer(_ image: CIImage, scale: Double, dx: Double, dy: Double) -> CIImage {
    image.transformed(by: CGAffineTransform(translationX: -center.x, y: -center.y)
        .concatenating(CGAffineTransform(scaleX: scale, y: scale))
        .concatenating(CGAffineTransform(translationX: center.x + dx, y: center.y + dy)))
}
let outRect = CGRect(x: center.x - outW / 2, y: center.y - outH / 2, width: outW, height: outH)
func frame(_ t: Double) -> CIImage {
    let a = 2 * Double.pi * t
    let dx = 0.011 * outW * sin(a), dy = 0.006 * outH * sin(2 * a)
    let bg = layer(background, scale: 1.0 + 0.008 * sin(a), dx: 0.4 * dx, dy: 0.4 * dy)
    let fg = layer(subject, scale: 1.0 + 0.016 * sin(a), dx: dx, dy: dy)
    return fg.composited(over: bg).cropped(to: outRect).transformed(by: CGAffineTransform(translationX: -outRect.minX, y: -outRect.minY))
}
png(frame(0), "frame-000.png"); png(frame(0.25), "frame-025.png")

// 5. Encode the loop as HEVC.
try? FileManager.default.removeItem(at: output)
let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
let input2 = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: Int(outW), AVVideoHeightKey: Int(outH),
    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000, AVVideoExpectedSourceFrameRateKey: Int(fps)],
])
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input2, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: Int(outW),
    kCVPixelBufferHeightKey as String: Int(outH), kCVPixelBufferIOSurfacePropertiesKey as String: [:],
])
writer.add(input2)
writer.startWriting(); writer.startSession(atSourceTime: .zero)
let frames = Int(seconds * fps)
let renderStart = Date()
for i in 0..<frames {
    while !input2.isReadyForMoreMediaData { usleep(1000) }
    var buffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
    context.render(frame(Double(i) / Double(frames)), to: buffer!, bounds: CGRect(x: 0, y: 0, width: outW, height: outH), colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
}
input2.markAsFinished()
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
let bytes = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.intValue ?? 0
print("wrote \(frames) frames in \(String(format: "%.1f", Date().timeIntervalSince(renderStart)))s, \(bytes / 1_000_000) MB, status \(writer.status.rawValue) \(writer.error.map { "\($0)" } ?? "")")
