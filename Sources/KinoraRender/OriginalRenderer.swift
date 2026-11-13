// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import CoreGraphics
import Foundation
import IOSurface
import KinoraKit
import Metal

/// The values every original's shader reads. Five 16-byte vectors, matching the Metal struct.
public struct OriginalUniforms: Equatable, Sendable {
    public var resolutionTime: SIMD4<Float>
    public var sun: SIMD4<Float>
    public var colorA: SIMD4<Float>
    public var colorB: SIMD4<Float>
    public var colorC: SIMD4<Float>
}

public enum OriginalRenderError: Error, Equatable {
    case noMetalDevice
    case shaderMissing(String)
    case cannotAllocate
}

/// Draws Kinora's originals with Metal: into a layer's drawable for live wallpapers and
/// previews, or into an IOSurface for snapshots and thumbnails. Pipelines are compiled once per
/// process and shared; Metal devices, queues and pipeline states are thread-safe.
public final class OriginalRenderer: @unchecked Sendable {
    public let device: MTLDevice
    public let queue: MTLCommandQueue
    private let library: MTLLibrary
    private var pipelines: [String: MTLRenderPipelineState] = [:]
    private let lock = NSLock()

    public static let pixelFormat = MTLPixelFormat.bgra8Unorm

    /// One renderer per process, made on first use; nil where Metal is unavailable.
    public static let shared: OriginalRenderer? = try? OriginalRenderer()

    public init(device: MTLDevice? = MTLCreateSystemDefaultDevice()) throws {
        guard let device, let queue = device.makeCommandQueue() else { throw OriginalRenderError.noMetalDevice }
        self.device = device
        self.queue = queue
        library = try device.makeLibrary(source: OriginalShaders.source, options: nil)
    }

    /// The compiled pipeline for an original, compiled on first use.
    public func pipeline(for original: KinoraOriginal) throws -> MTLRenderPipelineState {
        if let cached = lock.withLock({ pipelines[original.slug] }) { return cached }
        guard let vertex = library.makeFunction(name: OriginalShaders.vertexFunction) else { throw OriginalRenderError.shaderMissing(OriginalShaders.vertexFunction) }
        guard let fragment = library.makeFunction(name: original.slug) else { throw OriginalRenderError.shaderMissing(original.slug) }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "Kinora \(original.name)"
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = Self.pixelFormat
        let state = try device.makeRenderPipelineState(descriptor: descriptor)
        lock.withLock { pipelines[original.slug] = state }
        return state
    }

    /// The uniforms for one frame.
    public static func uniforms(for original: KinoraOriginal, width: Int, height: Int, time: Double, sky: SkySample) -> OriginalUniforms {
        func color(_ index: Int) -> SIMD4<Float> {
            let rgb = index < original.palette.count ? original.palette[index] : SIMD3<Float>(repeating: 0.5)
            return SIMD4<Float>(rgb, 1)
        }
        // Float loses sub-frame precision after weeks of motion; wrapping keeps it smooth.
        let wrapped = Float(time.truncatingRemainder(dividingBy: 1_048_576))
        return OriginalUniforms(
            resolutionTime: SIMD4<Float>(Float(width), Float(height), wrapped, 0),
            sun: SIMD4<Float>(Float(sky.elevation), Float(sky.azimuth), Float(sky.daylight), Float(sky.offset)),
            colorA: color(0), colorB: color(1), colorC: color(2))
    }

    /// Encodes one frame of `original` into `texture`.
    public func encode(_ original: KinoraOriginal, uniforms: OriginalUniforms, into texture: MTLTexture, commandBuffer: MTLCommandBuffer) throws {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { throw OriginalRenderError.cannotAllocate }
        encoder.setRenderPipelineState(try pipeline(for: original))
        var values = uniforms
        encoder.setFragmentBytes(&values, length: MemoryLayout<OriginalUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    /// One frame drawn into a new BGRA IOSurface, waiting for the GPU. For snapshots.
    public func surface(_ original: KinoraOriginal, width: Int, height: Int, time: Double, sky: SkySample) throws -> IOSurfaceRef {
        guard width > 0, height > 0, width <= 16_384, height <= 16_384,
              let surface = IOSurfaceCreate([kIOSurfaceWidth: width, kIOSurfaceHeight: height, kIOSurfaceBytesPerElement: 4,
                                             kIOSurfacePixelFormat: 0x4247_5241 /* 'BGRA' */] as CFDictionary)
        else { throw OriginalRenderError.cannotAllocate }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.pixelFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed
        guard let texture = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0),
              let commands = queue.makeCommandBuffer() else { throw OriginalRenderError.cannotAllocate }
        try encode(original, uniforms: Self.uniforms(for: original, width: width, height: height, time: time, sky: sky),
                   into: texture, commandBuffer: commands)
        if descriptor.storageMode == .managed, let blit = commands.makeBlitCommandEncoder() {
            blit.synchronize(resource: texture)
            blit.endEncoding()
        }
        commands.commit()
        commands.waitUntilCompleted()
        if commands.status == .error { throw OriginalRenderError.cannotAllocate }
        return surface
    }

    /// One frame as an image, for thumbnails.
    public func image(_ original: KinoraOriginal, width: Int, height: Int, time: Double, sky: SkySample) throws -> CGImage {
        let surface = try surface(original, width: width, height: height, time: time, sky: sky)
        IOSurfaceLock(surface, .readOnly, nil)
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let bytesPerRow = IOSurfaceGetBytesPerRow(surface)
        let data = Data(bytes: IOSurfaceGetBaseAddress(surface), count: bytesPerRow * height)
        guard let provider = CGDataProvider(data: data as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { throw OriginalRenderError.cannotAllocate }
        return image
    }

    /// GPU milliseconds per frame, averaged over `frames` frames drawn offscreen at `width` × `height`.
    /// Nil when the GPU does not report timestamps.
    public func measure(_ original: KinoraOriginal, width: Int, height: Int, frames: Int = 60) throws -> Double? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.pixelFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw OriginalRenderError.cannotAllocate }
        // Warm up: the first frame includes pipeline compilation.
        _ = try pipeline(for: original)
        var total = 0.0, counted = 0
        for frame in 0..<frames {
            guard let commands = queue.makeCommandBuffer() else { throw OriginalRenderError.cannotAllocate }
            try encode(original, uniforms: Self.uniforms(for: original, width: width, height: height, time: Double(frame) / 30, sky: .afternoon),
                       into: texture, commandBuffer: commands)
            commands.commit()
            commands.waitUntilCompleted()
            let gpu = commands.gpuEndTime - commands.gpuStartTime
            if frame > 0, gpu > 0 { total += gpu; counted += 1 }
        }
        return counted > 0 ? total / Double(counted) * 1000 : nil
    }
}
