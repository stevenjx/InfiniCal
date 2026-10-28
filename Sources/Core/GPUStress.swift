//
//  GPUStress.swift
//  A controllable Metal compute load for the discharge phase of a stress
//  calibration.
//
//  The kernel is compiled from source at runtime, so there is no .metal file to
//  add to the build and nothing to keep in sync with the Xcode target.
//
//  Deliberately a separate object from the CPU workers in CalibrationEngine:
//  the GPU has to be droppable on its own when the die gets hot, without
//  touching the CPU load that is already running.
//
//  Kernel notes (measured on an M2 Pro):
//    • A sin/cos loop looks heavy but runs on the special-function pipe and
//      leaves the FMA units idle — 20 s of it moved the die by 0.0 °C.
//    • A single dependent FMA chain is latency-bound: 1.45 TFLOPS, ~21 % of
//      peak, and also barely warms the die.
//    • Eight independent float4 chains reach ~11 ms per dispatch and warm the
//      die as much as nine busy CPU threads do. That is what ships.
//

import Foundation
import Metal

final class GPUStress {

    /// Threads per dispatch. With the kernel below this is ~11 ms of GPU time,
    /// short enough that `stop()` is felt promptly.
    private static let grid = 1 << 20

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    kernel void burn(device float *out [[buffer(0)]], uint id [[thread_position_in_grid]]) {
        float4 a0 = float4(float(id)) * 0.0001f + float4(1.0f);
        float4 a1 = a0 + 0.7f, a2 = a0 + 1.4f, a3 = a0 + 2.1f;
        float4 a4 = a0 + 2.8f, a5 = a0 + 3.5f, a6 = a0 + 4.2f, a7 = a0 + 4.9f;
        for (int i = 0; i < 1024; i++) {
            a0 = fma(a0, 0.9999f, 0.5f);
            a1 = fma(a1, 0.9999f, 0.5f);
            a2 = fma(a2, 0.9999f, 0.5f);
            a3 = fma(a3, 0.9999f, 0.5f);
            a4 = fma(a4, 0.9999f, 0.5f);
            a5 = fma(a5, 0.9999f, 0.5f);
            a6 = fma(a6, 0.9999f, 0.5f);
            a7 = fma(a7, 0.9999f, 0.5f);
        }
        out[id] = a0.x + a1.y + a2.z + a3.w + a4.x + a5.y + a6.z + a7.w;
    }
    """

    private let queue = DispatchQueue(label: "com.infinitycomputer.infinical.gpu-stress",
                                      qos: .userInitiated)
    private let commandQueue: MTLCommandQueue?
    private let pipeline: MTLComputePipelineState?
    private let buffer: MTLBuffer?

    private let stateLock = NSLock()
    private var running = false
    private var dutyCycle: Double = 1

    var isAvailable: Bool { commandQueue != nil && pipeline != nil && buffer != nil }

    init() {
        let device = MTLCreateSystemDefaultDevice()
        commandQueue = device?.makeCommandQueue()
        buffer = device?.makeBuffer(length: Self.grid * MemoryLayout<Float>.stride,
                                    options: .storageModePrivate)
        var compiled: MTLComputePipelineState?
        if let device {
            do {
                let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
                if let function = library.makeFunction(name: "burn") {
                    compiled = try device.makeComputePipelineState(function: function)
                }
            } catch {
                compiled = nil
            }
        }
        pipeline = compiled
    }

    deinit { stop() }

    // MARK: - Control

    /// Fraction of wall-clock time the GPU should be executing, 0…1. Scaling
    /// the grid instead would not reduce the load: the queue is refilled as
    /// soon as a dispatch finishes, so only a gap between dispatches does.
    func start(dutyCycle: Double) {
        setDutyCycle(dutyCycle)
        stateLock.lock()
        let alreadyRunning = running
        running = true
        stateLock.unlock()
        guard !alreadyRunning else { return }
        queue.async { [weak self] in self?.loop() }
    }

    func stop() {
        stateLock.lock()
        running = false
        stateLock.unlock()
    }

    private func setDutyCycle(_ value: Double) {
        stateLock.lock()
        dutyCycle = min(1, max(0.05, value))
        stateLock.unlock()
    }

    private var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running
    }

    private var currentDutyCycle: Double {
        stateLock.lock()
        defer { stateLock.unlock() }
        return dutyCycle
    }

    // MARK: - Load

    private func loop() {
        guard let commandQueue, let pipeline, let buffer else { return }
        let threadgroup = MTLSize(width: min(64, pipeline.maxTotalThreadsPerThreadgroup),
                                  height: 1, depth: 1)
        while isRunning {
            let started = Date()
            if let commandBuffer = commandQueue.makeCommandBuffer(),
               let encoder = commandBuffer.makeComputeCommandEncoder() {
                encoder.setComputePipelineState(pipeline)
                encoder.setBuffer(buffer, offset: 0, index: 0)
                encoder.dispatchThreads(MTLSize(width: Self.grid, height: 1, depth: 1),
                                        threadsPerThreadgroup: threadgroup)
                encoder.endEncoding()
                commandBuffer.commit()
                commandBuffer.waitUntilCompleted()
            }

            // Duty cycle: idle for the same share of time the dispatch just
            // took. Measured, not assumed — dispatch cost changes with clocks.
            let duty = currentDutyCycle
            guard duty < 0.999 else { continue }
            let elapsed = Date().timeIntervalSince(started)
            let idle = elapsed * (1 / duty - 1)
            if idle > 0.001 { usleep(useconds_t(min(idle, 1.0) * 1_000_000)) }
        }
    }
}
