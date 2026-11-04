import AppKit
import MetalKit

/// Полноэкранная заставка поверх всех окон: закрывает экран (cover), держит его, пока идёт
/// смена режима, и открывает (reveal). Окно не принимает клики и видно на всех рабочих столах.
@MainActor
final class TransitionOverlay {
    /// Уровень окна заставки; замер (--overlay-space-test) сравнивает варианты.
    var level = NSWindow.Level.screenSaver
    private var window: NSWindow?
    private var renderer: TransitionRenderer?

    /// Возвращает false, если Metal недоступен; тогда режим переключается без анимации.
    func cover(mode: Mode, effect: TransitionEffect, intensity: Double) async -> Bool {
        guard let screen = NSScreen.main, let renderer = TransitionRenderer.make() else { return false }
        renderer.leisure = mode == .leisure ? 1 : 0
        renderer.effect = effect.shaderIndex
        renderer.intensity = Float(intensity)

        let view = MTKView(frame: CGRect(origin: .zero, size: screen.frame.size), device: renderer.device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.preferredFramesPerSecond = 120
        view.wantsLayer = true
        view.layer?.isOpaque = false
        view.delegate = renderer

        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = level
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.contentView = view
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()

        self.window = window
        self.renderer = renderer
        await renderer.run(.cover, duration: 0.75)
        renderer.hold()
        return true
    }

    /// Для измерений (--overlay-space-test): видна ли заставка, на активном ли столе, сколько кадров нарисовано.
    var diagnostics: (visible: Bool, onActiveSpace: Bool, frames: Int)? {
        guard let window, let renderer else { return nil }
        return (window.occlusionState.contains(.visible), window.isOnActiveSpace, renderer.framesDrawn)
    }

    func reveal() async {
        guard let window, let renderer else { return }
        await renderer.run(.reveal, duration: 0.85)
        window.orderOut(nil)
        self.window = nil
        self.renderer = nil
    }
}

@MainActor
final class TransitionRenderer: NSObject, MTKViewDelegate {
    enum Phase: Int32 {
        case cover = 0, hold = 1, reveal = 2
    }

    /// Раскладка совпадает со struct U в шейдере.
    private struct Uniforms {
        var resolution: SIMD2<Float>
        var progress: Float
        var time: Float
        var effect: Int32
        var leisure: Int32
        var phase: Int32
        var intensity: Float
    }

    let device: MTLDevice
    var effect: Int32 = 0
    var leisure: Int32 = 0
    var intensity: Float = 0.8

    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let startTime = CACurrentMediaTime()
    private var phase: Phase = .cover
    private var phaseStart = CACurrentMediaTime()
    private var phaseDuration: CFTimeInterval = 1
    private var generation = 0
    private var completion: CheckedContinuation<Void, Never>?
    private(set) var framesDrawn = 0

    private init(device: MTLDevice, queue: MTLCommandQueue, pipeline: MTLRenderPipelineState) {
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
    }

    static func make() -> TransitionRenderer? {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        do {
            let library = try device.makeLibrary(source: shaderSource, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "transitionVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "transitionFragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            return TransitionRenderer(device: device, queue: queue, pipeline: pipeline)
        } catch {
            NSLog("NotchFlow: не удалось подготовить Metal: \(error)")
            return nil
        }
    }

    func run(_ phase: Phase, duration: CFTimeInterval) async {
        finish(generation)
        generation += 1
        let current = generation
        self.phase = phase
        phaseStart = CACurrentMediaTime()
        phaseDuration = duration
        await withCheckedContinuation { continuation in
            completion = continuation
            // Если кадры перестали рисоваться (экран погас), не зависаем.
            DispatchQueue.main.asyncAfter(deadline: .now() + duration + 1.5) { [weak self] in
                MainActor.assumeIsolated { self?.finish(current) }
            }
        }
    }

    func hold() {
        finish(generation)
        phase = .hold
    }

    private func finish(_ forGeneration: Int) {
        guard forGeneration == generation, let completion else { return }
        self.completion = nil
        completion.resume()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        framesDrawn += 1
        let now = CACurrentMediaTime()
        let progress = phase == .hold ? 1 : Float(min(1, (now - phaseStart) / phaseDuration))
        guard let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass)
        else { return }

        var uniforms = Uniforms(
            resolution: SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height)),
            progress: progress,
            time: Float(now - startTime),
            effect: effect,
            leisure: leisure,
            phase: phase.rawValue,
            intensity: intensity
        )
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        buffer.present(drawable)

        // Фаза считается завершённой, только когда последний кадр реально показан.
        if phase != .hold, progress >= 1, completion != nil {
            let current = generation
            buffer.addCompletedHandler { [weak self] _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.finish(current) }
                }
            }
        }
        buffer.commit()
    }
}

private let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct U { float2 resolution; float progress; float time; int effect; int leisure; int phase; float intensity; };
struct VOut { float4 position [[position]]; float2 uv; };

vertex VOut transitionVertex(uint id [[vertex_id]]) {
    float2 p[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    VOut o;
    o.position = float4(p[id], 0.0, 1.0);
    o.uv = float2((p[id].x + 1.0) * 0.5, 1.0 - (p[id].y + 1.0) * 0.5); // (0,0) — левый верхний угол
    return o;
}

fragment float4 transitionFragment(VOut in [[stage_in]], constant U& u [[buffer(0)]]) {
    float2 uv = in.uv;
    float aspect = u.resolution.x / max(u.resolution.y, 1.0);
    float t = u.time;
    float q = smoothstep(0.0, 1.0, clamp(u.progress, 0.0, 1.0));
    // Открытие — обратный ход закрытия: волна уходит обратно в вырез, а не проходит экран
    // второй раз сверху вниз (это выглядело как повторное закрытие).
    if (u.phase == 2) q = 1.0 - q;
    bool leisure = u.leisure != 0;

    float3 deep = leisure ? float3(0.05, 0.02, 0.12) : float3(0.01, 0.03, 0.10);
    float3 mid  = leisure ? float3(0.36, 0.17, 0.70) : float3(0.07, 0.38, 0.76);
    float3 glow = leisure ? float3(0.98, 0.62, 1.00) : float3(0.62, 0.93, 1.00);

    // edge > 0 — точка закрыта заставкой.
    float edge;
    if (u.effect == 0) {
        // Liquid Glass: волна стекает от выреза вниз (при открытии — поднимается обратно).
        float ripple = 0.035 * sin(uv.x * 9.0 + t * 5.0) + 0.015 * sin(uv.x * 23.0 - t * 3.7);
        float front = mix(-0.2, 1.2, q) + ripple;
        edge = front - uv.y;
    } else {
        // Aurora Sweep: круг расходится от выреза (при открытии — стягивается обратно).
        float2 p = (uv - float2(0.5, 0.0)) * float2(aspect, 1.0);
        float d = length(p) + 0.03 * sin(atan2(p.x, p.y) * 7.0 + t * 3.0);
        float radius = q * (length(float2(aspect * 0.5, 1.0)) + 0.25);
        edge = radius - d;
    }
    if (u.phase == 1) edge = 1.0;

    float flow = 0.5 + 0.5 * sin((uv.x * 3.1 + uv.y * 2.3 + t * 0.35 + 0.3 * sin(uv.x * 4.0 - t * 0.5)) * 6.283);
    float3 color = mix(deep, mid, flow * 0.55 * u.intensity);
    float rim = exp(-abs(edge) * 24.0);
    color += glow * rim * 0.65 * u.intensity;
    float shine = pow(max(0.0, sin(uv.x * 5.0 + uv.y * 3.5 + t * 0.6)), 16.0);
    color += glow * shine * 0.12 * u.intensity;
    float vignette = 1.0 - smoothstep(0.35, 0.9, length((uv - 0.5) * float2(aspect * 0.8, 1.0)));
    color *= mix(0.75, 1.0, vignette);

    float alpha = clamp(smoothstep(-0.02, 0.02, edge) + rim * 0.5 * u.intensity, 0.0, 1.0);
    return float4(color * alpha, alpha);
}
"""
