// Voca — a macOS menu bar app for saving selected text globally.
// Copyright (C) 2026 UNLINEARITY <https://github.com/UNLINEARITY>
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or (at
// your option) any later version.
//
// This program is distributed in the hope that it will be useful, but
// WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
// or FITNESS FOR A PARTICULAR PURPOSE. See the GNU Affero General Public
// License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import CoreMedia
import CoreVideo
import MetalKit
import ScreenCaptureKit
import SwiftUI
import simd

/// A live, privacy-preserving convex lens. ScreenCaptureKit supplies only an
/// in-memory frame of the display behind Voca; Metal refracts that frame and
/// discards everything outside the circular lens.
struct GalaxyLensView: NSViewRepresentable {
    func makeNSView(context: Context) -> GalaxyLensMetalView {
        GalaxyLensMetalView(frame: .zero)
    }

    func updateNSView(_ view: GalaxyLensMetalView, context: Context) {}

    static func dismantleNSView(_ view: GalaxyLensMetalView, coordinator: ()) {
        view.pauseRendering()
    }
}

final class GalaxyLensMetalView: MTKView {
    private var lensRenderer: GalaxyLensRenderer?

    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect, device: MTLDevice?) {
        let metalDevice = device ?? MTLCreateSystemDefaultDevice()
        super.init(frame: frameRect, device: metalDevice)
        guard let metalDevice else { return }

        wantsLayer = true
        layer?.isOpaque = false
        layer?.backgroundColor = NSColor.clear.cgColor
        clearColor = MTLClearColorMake(0, 0, 0, 0)
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = true
        preferredFramesPerSecond = 60
        enableSetNeedsDisplay = false
        isPaused = false

        lensRenderer = try? GalaxyLensRenderer(view: self, device: metalDevice)
        delegate = lensRenderer
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            pauseRendering()
        } else {
            resumeRendering()
        }
    }

    func pauseRendering() {
        isPaused = true
        lensRenderer?.stopCapture()
    }

    func resumeRendering() {
        isPaused = false
        lensRenderer?.startCaptureIfNeeded()
    }
}

private struct GalaxyLensUniforms {
    var lensOrigin = SIMD2<Float>(repeating: 0)
    var lensSize = SIMD2<Float>(repeating: 1)
    var captureSize = SIMD2<Float>(repeating: 1)
    var pointer = SIMD2<Float>(-0.38, 0.42)
    var time: Float = 0
    var refraction: Float = 0.29
    var dispersion: Float = 1.35
    var padding: Float = 0
    /// x=色散分布指数 y=扭曲衰减 z=边缘厚度 w=菲涅尔蓝调
    var tuning = SIMD4<Float>(2.0, 1.0, 0.30, 0.16)
}

private final class GalaxyLensRenderer: NSObject, MTKViewDelegate, SCStreamOutput, SCStreamDelegate {
    private static let captureQueue = DispatchQueue(
        label: "local.voca.galaxy-lens.capture",
        qos: .userInteractive
    )

    private weak var view: GalaxyLensMetalView?
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let textureCache: CVMetalTextureCache
    private let textureLock = NSLock()
    private var capturedTexture: (reference: CVMetalTexture, texture: MTLTexture)?
    private var stream: SCStream?
    private var isStartingCapture = false
    private var hasRequestedPermission = false
    private var captureDisplayID: CGDirectDisplayID?
    private let startedAt = CACurrentMediaTime()

    init(view: GalaxyLensMetalView, device: MTLDevice) throws {
        guard let commandQueue = device.makeCommandQueue() else {
            throw GalaxyLensError.metalUnavailable
        }
        self.view = view
        self.commandQueue = commandQueue

        var cache: CVMetalTextureCache?
        let cacheStatus = CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        guard cacheStatus == kCVReturnSuccess, let cache else {
            throw GalaxyLensError.metalUnavailable
        }
        textureCache = cache

        let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        guard let vertexFunction = library.makeFunction(name: "galaxyLensVertex"),
              let fragmentFunction = library.makeFunction(name: "galaxyLensFragment") else {
            throw GalaxyLensError.metalUnavailable
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        super.init()
    }

    func startCaptureIfNeeded() {
        guard stream == nil, !isStartingCapture, let view, view.window != nil else { return }

        if !CGPreflightScreenCaptureAccess() {
            guard !hasRequestedPermission else { return }
            hasRequestedPermission = true
            guard CGRequestScreenCaptureAccess() else {
                NSLog("Voca: Screen Recording permission is required for the live galaxy lens")
                return
            }
        }

        isStartingCapture = true
        SCShareableContent.getExcludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        ) { [weak self] content, error in
            DispatchQueue.main.async {
                self?.configureCapture(content: content, error: error)
            }
        }
    }

    func stopCapture() {
        isStartingCapture = false
        guard let stream else {
            clearCapturedTexture()
            return
        }
        self.stream = nil
        captureDisplayID = nil
        stream.stopCapture { [weak self] error in
            if let error {
                NSLog("Voca: Failed to stop galaxy lens capture: %@", error.localizedDescription)
            }
            self?.clearCapturedTexture()
        }
    }

    private func configureCapture(content: SCShareableContent?, error: Error?) {
        guard isStartingCapture else { return }
        isStartingCapture = false

        if let error {
            NSLog("Voca: Unable to inspect screen content for the galaxy lens: %@", error.localizedDescription)
            return
        }
        guard let view,
              let screen = view.window?.screen,
              let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let content,
              let display = content.displays.first(where: {
                  $0.displayID == CGDirectDisplayID(screenNumber.uint32Value)
              }) else {
            NSLog("Voca: Unable to match the galaxy window to a capturable display")
            return
        }

        let currentProcessID = pid_t(ProcessInfo.processInfo.processIdentifier)
        guard let ownApplication = content.applications.first(where: {
            $0.processID == currentProcessID
        }) else {
            NSLog("Voca: Refusing to start the galaxy lens because Voca could not be excluded from capture")
            return
        }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: [ownApplication],
            exceptingWindows: []
        )
        let configuration = SCStreamConfiguration()
        configuration.width = display.width
        configuration.height = display.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 2
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        configuration.capturesAudio = false

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: Self.captureQueue)
        } catch {
            NSLog("Voca: Unable to connect the galaxy lens capture output: %@", error.localizedDescription)
            return
        }

        self.stream = stream
        captureDisplayID = display.displayID
        stream.startCapture { [weak self, weak stream] error in
            if let error {
                NSLog("Voca: Unable to start the galaxy lens capture: %@", error.localizedDescription)
                DispatchQueue.main.async {
                    if self?.stream === stream {
                        self?.stream = nil
                    }
                }
            }
        }
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen,
              sampleBuffer.isValid,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var textureReference: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil,
            textureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &textureReference
        )
        guard status == kCVReturnSuccess,
              let textureReference,
              let texture = CVMetalTextureGetTexture(textureReference) else { return }

        textureLock.lock()
        capturedTexture = (textureReference, texture)
        textureLock.unlock()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("Voca: Galaxy lens capture stopped: %@", error.localizedDescription)
        DispatchQueue.main.async { [weak self, weak stream] in
            if self?.stream === stream {
                self?.stream = nil
                self?.clearCapturedTexture()
            }
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in metalView: MTKView) {
        guard let renderPass = metalView.currentRenderPassDescriptor,
              let drawable = metalView.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        renderPass.colorAttachments[0].loadAction = .clear
        renderPass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)

        textureLock.lock()
        let capture = capturedTexture
        textureLock.unlock()

        guard let capture,
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass),
              var uniforms = makeUniforms(
                  textureWidth: capture.texture.width,
                  textureHeight: capture.texture.height
              ) else {
            commandBuffer.present(drawable)
            commandBuffer.commit()
            return
        }

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(capture.texture, index: 0)
        encoder.setFragmentBytes(
            &uniforms,
            length: MemoryLayout<GalaxyLensUniforms>.stride,
            index: 0
        )
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func makeUniforms(textureWidth: Int, textureHeight: Int) -> GalaxyLensUniforms? {
        guard let view,
              let window = view.window,
              let screen = window.screen,
              captureDisplayID != nil else { return nil }

        let localRect = view.convert(view.bounds, to: nil)
        let screenRect = window.convertToScreen(localRect)
        let screenFrame = screen.frame
        guard screenFrame.width > 0, screenFrame.height > 0 else { return nil }

        let scaleX = CGFloat(textureWidth) / screenFrame.width
        let scaleY = CGFloat(textureHeight) / screenFrame.height
        let origin = SIMD2<Float>(
            Float((screenRect.minX - screenFrame.minX) * scaleX),
            Float((screenFrame.maxY - screenRect.maxY) * scaleY)
        )
        let size = SIMD2<Float>(
            Float(screenRect.width * scaleX),
            Float(screenRect.height * scaleY)
        )

        let mouse = NSEvent.mouseLocation
        let pointer = SIMD2<Float>(
            Float(((mouse.x - screenRect.midX) / max(screenRect.width * 0.5, 1)).clamped(to: -1...1)),
            Float(((mouse.y - screenRect.midY) / max(screenRect.height * 0.5, 1)).clamped(to: -1...1))
        )

        let tuning = GalaxyTuning.shared
        return GalaxyLensUniforms(
            lensOrigin: origin,
            lensSize: size,
            captureSize: SIMD2<Float>(Float(textureWidth), Float(textureHeight)),
            pointer: pointer,
            time: Float(CACurrentMediaTime() - startedAt),
            refraction: Float(tuning.refraction),
            dispersion: Float(tuning.dispersion),
            padding: 0,
            tuning: SIMD4(
                Float(tuning.chromaExponent),
                Float(tuning.warpFalloff),
                Float(tuning.rimStrength),
                Float(tuning.fresnelTint)
            )
        )
    }

    private func clearCapturedTexture() {
        textureLock.lock()
        capturedTexture = nil
        textureLock.unlock()
        CVMetalTextureCacheFlush(textureCache, 0)
    }

    private enum GalaxyLensError: Error {
        case metalUnavailable
    }

    private static let shaderSource = #"""
    #include <metal_stdlib>
    using namespace metal;

    struct LensVertexOut {
        float4 position [[position]];
        float2 uv;
    };

    struct LensUniforms {
        float2 lensOrigin;
        float2 lensSize;
        float2 captureSize;
        float2 pointer;
        float time;
        float refraction;
        float dispersion;
        float padding;
        float4 tuning; // x=chromaExponent y=warpFalloff z=rimStrength w=fresnelTint
    };

    vertex LensVertexOut galaxyLensVertex(uint vertexID [[vertex_id]]) {
        constexpr float2 positions[6] = {
            {-1.0, -1.0}, { 1.0, -1.0}, {-1.0,  1.0},
            {-1.0,  1.0}, { 1.0, -1.0}, { 1.0,  1.0}
        };
        constexpr float2 coordinates[6] = {
            {0.0, 1.0}, {1.0, 1.0}, {0.0, 0.0},
            {0.0, 0.0}, {1.0, 1.0}, {1.0, 0.0}
        };
        LensVertexOut output;
        output.position = float4(positions[vertexID], 0.0, 1.0);
        output.uv = coordinates[vertexID];
        return output;
    }

    fragment half4 galaxyLensFragment(
        LensVertexOut input [[stage_in]],
        texture2d<half> capturedFrame [[texture(0)]],
        constant LensUniforms &uniforms [[buffer(0)]]
    ) {
        constexpr sampler frameSampler(
            coord::normalized,
            address::clamp_to_edge,
            filter::linear
        );

        float2 p = input.uv * 2.0 - 1.0;
        float radiusSquared = dot(p, p);
        if (radiusSquared >= 1.0) {
            return half4(0.0);
        }

        float radius = sqrt(max(radiusSquared, 0.00001));
        float depth = sqrt(max(0.0, 1.0 - radiusSquared));

        // A convex lens samples points closer to its optical axis. The mapping
        // joins the unmodified background at the rim to avoid a visible seam.
        float magnification = 1.0 - uniforms.refraction
            * pow(1.0 - radius, uniforms.tuning.y)
            * (0.78 + 0.22 * depth);
        float2 refractedPoint = p * magnification;
        float2 localSample = refractedPoint * 0.5 + 0.5;
        float2 screenPixel = uniforms.lensOrigin + localSample * uniforms.lensSize;
        float2 screenUV = screenPixel / uniforms.captureSize;

        // Physically restrained chromatic aberration is concentrated near the
        // rim, where a thick glass sphere separates wavelengths most visibly.
        float2 radialDirection = p / max(radius, 0.001);
        float chroma = uniforms.dispersion * pow(radius, uniforms.tuning.x);
        float2 chromaUV = radialDirection * chroma / uniforms.captureSize;
        half red = capturedFrame.sample(frameSampler, screenUV + chromaUV).r;
        half green = capturedFrame.sample(frameSampler, screenUV).g;
        half blue = capturedFrame.sample(frameSampler, screenUV - chromaUV).b;
        half3 color = half3(red, green, blue);

        float3 normal = normalize(float3(p.x, -p.y, depth));
        float2 movingLight = mix(float2(-0.42, 0.48), uniforms.pointer * 0.42, 0.38);
        float3 lightDirection = normalize(float3(movingLight.x, movingLight.y, 0.92));
        float facingLight = max(dot(normal, lightDirection), 0.0);
        float sharpHighlight = pow(facingLight, 92.0);
        float softHighlight = pow(facingLight, 11.0);
        float fresnel = pow(1.0 - depth, 4.2);

        // A small drifting caustic keeps the sphere alive without drawing a
        // synthetic white outline around it.
        float causticPhase = uniforms.time * 0.16;
        float2 causticCenter = float2(
            0.34 + sin(causticPhase) * 0.035,
            0.28 + cos(causticPhase * 0.83) * 0.025
        );
        float causticDistance = length(p - causticCenter);
        float caustic = exp(-pow((causticDistance - 0.23) * 18.0, 2.0))
            * smoothstep(0.2, 0.75, radius);

        color *= half(1.0 - fresnel * 0.075);
        color += half3(0.23, 0.30, 0.38) * half(fresnel * uniforms.tuning.w);
        color += half3(1.0, 0.97, 0.90) * half(sharpHighlight * 0.48);
        color += half3(0.30, 0.38, 0.48) * half(softHighlight * 0.055);
        color += half3(0.48, 0.67, 0.82) * half(caustic * 0.075);

        // Darken only the final inner millimetres to make the glass thickness
        // legible while keeping the sphere itself optically transparent.
        float innerRim = smoothstep(0.90, 0.998, radius);
        color *= half(1.0 - innerRim * uniforms.tuning.z);
        return half4(color, 1.0);
    }
    """#
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
