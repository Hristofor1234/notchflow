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

    /// Смена рабочего стола под заставкой. macOS на время анимации сдвига столов на мгновение
    /// убирает окна, которые видны на всех столах, — заставка мигала и появлялась снова.
    /// Поэтому заставка сначала успокаивается до ровного цвета, затем дисплей плавно уходит
    /// в тот же цвет на уровне видеовыхода (это незаметно), стол меняется под ним, и дисплей
    /// возвращается. Системная анимация через затемнение дисплея не видна.
    /// Если затемнение недоступно, стол просто меняется под заставкой.
    func whileMasked<T>(_ body: () async -> T) async -> (result: T, faded: Bool) {
        guard window != nil, let renderer else { return (await body(), false) }
        // Заставка медленно (≈0.7 с) стихает до ровного тёмного цвета…
        renderer.calmTarget = 1
        try? await Task.sleep(for: .milliseconds(700))

        guard let fade = DisplayFade(color: renderer.solidColor) else {
            let result = await body()
            renderer.calmTarget = 0
            return (result, false)
        }
        // …дисплей медленно уходит в тот же цвет…
        guard await fade.animate(to: 1, duration: 0.7) else {
            let result = await body()
            renderer.calmTarget = 0
            return (result, false)
        }
        // …при полном затемнении меняется стол (экран ровный, без мигания)…
        let result = await body()
        // …и дисплей так же медленно возвращается.
        await fade.animate(to: 0, duration: 0.7)
        fade.restore()
        // Заставка снова переливается, и только потом открывается экран.
        renderer.calmTarget = 0
        try? await Task.sleep(for: .milliseconds(700))
        return (result, true)
    }

    func reveal() async {
        guard let window, let renderer else { return }
        await renderer.run(.reveal, duration: 0.85)
        window.orderOut(nil)
        self.window = nil
        self.renderer = nil
    }
}

/// Затемнение всех дисплеев в ровный цвет через таблицы гаммы. Действует на уровне видеовыхода,
/// поэтому системные анимации (сдвиг рабочих столов) под ним не видны. CGDisplayFade в macOS 26
/// не работает (ошибка 1006), таблицы гаммы — работают. При выходе процесса macOS сама
/// возвращает исходные таблицы, так что экран не останется затемнённым.
@MainActor
final class DisplayFade {
    private struct Table { let display: CGDirectDisplayID; let r, g, b: [CGGammaValue] }
    private let tables: [Table]
    private let color: SIMD3<Float>
    /// 0 — обычная картинка, 1 — ровный цвет.
    private var level: Float = 0

    init?(color: SIMD3<Float>) {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        tables = ids.prefix(Int(count)).compactMap { id in
            let cap = CGDisplayGammaTableCapacity(id)
            guard cap > 0 else { return nil }
            var r = [CGGammaValue](repeating: 0, count: Int(cap)), g = r, b = r
            var n: UInt32 = 0
            guard CGGetDisplayTransferByTable(id, cap, &r, &g, &b, &n) == .success, n > 0 else { return nil }
            return Table(display: id, r: Array(r.prefix(Int(n))), g: Array(g.prefix(Int(n))), b: Array(b.prefix(Int(n))))
        }
        guard !tables.isEmpty else { return nil }
        self.color = color
    }

    /// Плавный (ease-in-out) переход уровня затемнения к `target`.
    @discardableResult
    func animate(to target: Float, duration: Double) async -> Bool {
        let from = level, start = CACurrentMediaTime()
        while true {
            let t = Float(min(1, (CACurrentMediaTime() - start) / duration))
            level = from + (target - from) * ease(t)
            guard apply() else { return false }
            if t >= 1 { return true }
            try? await Task.sleep(for: .milliseconds(8))
        }
    }

    func restore() {
        CGDisplayRestoreColorSyncSettings()
        level = 0
    }

    private func apply() -> Bool {
        let c = color, k = level
        for t in tables {
            let r = t.r.map { $0 * (1 - k) + c.x * k }
            let g = t.g.map { $0 * (1 - k) + c.y * k }
            let b = t.b.map { $0 * (1 - k) + c.z * k }
            guard CGSetDisplayTransferByTable(t.display, UInt32(r.count), r, g, b) == .success else {
                restore()
                return false
            }
        }
        return true
    }
}

/// Плавный вход и выход (smoothstep).
private func ease(_ t: Float) -> Float { t * t * (3 - 2 * t) }

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
        var calm: Float
    }

    let device: MTLDevice
    var effect: Int32 = 0
    var leisure: Int32 = 0
    var intensity: Float = 0.8
    /// 0 — обычная заставка, 1 — ровный цвет `solidColor` (под затемнение дисплея).
    var calmTarget: Float = 0
    private var calm: Float = 0
    private var lastDraw = CACurrentMediaTime()

    /// Цвет «deep» из шейдера — в него переходит заставка и в него же затемняется дисплей.
    var solidColor: SIMD3<Float> {
        leisure != 0 ? SIMD3(0.05, 0.02, 0.12) : SIMD3(0.01, 0.03, 0.10)
    }

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
        let dt = Float(now - lastDraw)
        lastDraw = now
        // Равномерно за ~0.7 с к calmTarget; в шейдере сглаживается smoothstep.
        calm += max(-dt * 1.45, min(dt * 1.45, calmTarget - calm))
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
            intensity: intensity,
            calm: calm
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

struct U { float2 resolution; float progress; float time; int effect; int leisure; int phase; float intensity; float calm; };
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
    // Во время смены стола заставка становится ровным цветом deep — точно таким же,
    // в какой уходит дисплей, поэтому переход к затемнению не виден.
    if (u.phase == 1) color = mix(color, deep, smoothstep(0.0, 1.0, u.calm));

    float alpha = clamp(smoothstep(-0.02, 0.02, edge) + rim * 0.5 * u.intensity, 0.0, 1.0);
    return float4(color * alpha, alpha);
}
"""
