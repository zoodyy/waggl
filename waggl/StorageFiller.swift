//
//  StorageFiller.swift
//  waggl
//
//  Fills the device's free storage with a file of binary zeros, then
//  deletes it again — repeated for the chosen number of passes. Each
//  pass is one full create → fill → delete cycle, so nothing is left
//  behind at the end.
//

import Foundation
import Combine

@MainActor
final class StorageFiller: ObservableObject {

    enum Phase: Equatable {
        case idle
        case filling
        case deleting
        case done
        case cancelled
        case failed(String)
    }

    /// One full create → fill → delete cycle.
    private enum PassOutcome {
        case completed(Int64)   // bytes written before deleting
        case cancelled(Int64)
        case failed(String)
    }

    /// How many create/delete cycles to run (1...5). Set from the UI while idle.
    @Published var passes: Int = 1

    @Published private(set) var phase: Phase = .idle
    /// Bytes written in the current pass.
    @Published private(set) var bytesWritten: Int64 = 0
    /// Free space reported by the system right now.
    @Published private(set) var availableBytes: Int64 = 0
    /// Free space captured at the start of the current pass (denominator for progress).
    @Published private(set) var startingFreeBytes: Int64 = 0
    /// The largest size the file reached across all passes.
    @Published private(set) var peakBytesWritten: Int64 = 0
    /// Which pass we're on (1...totalPasses).
    @Published private(set) var currentPass: Int = 0
    /// Total passes for this run.
    @Published private(set) var totalPasses: Int = 1

    private var worker: Task<Void, Never>?

    var isRunning: Bool {
        phase == .filling || phase == .deleting
    }

    /// 0...1 estimate of how full the disk is for the current pass.
    var progress: Double {
        guard startingFreeBytes > 0 else { return 0 }
        return min(1.0, Double(bytesWritten) / Double(startingFreeBytes))
    }

    private let fileName = "waggl_zero_fill.bin"

    private var fillURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent(fileName)
    }

    // MARK: - Control

    func start() {
        guard !isRunning else { return }

        let count = min(5, max(1, passes))
        totalPasses = count
        currentPass = 0
        bytesWritten = 0
        peakBytesWritten = 0
        startingFreeBytes = Self.freeSpace(near: fillURL)
        availableBytes = startingFreeBytes
        phase = .filling

        let url = fillURL
        worker = Task.detached(priority: .utility) { [weak self] in
            await self?.runAllPasses(count: count, at: url)
        }
    }

    func cancel() {
        worker?.cancel()
    }

    // MARK: - Pass loop (runs off the main actor)

    private nonisolated func runAllPasses(count: Int, at url: URL) async {
        for pass in 1...count {
            if Task.isCancelled {
                await self.finish(.cancelled)
                return
            }

            await self.beginPass(pass)
            // Every second pass writes all 1-bits (0xFF); odd passes write all 0-bits.
            let fillByte: UInt8 = pass.isMultiple(of: 2) ? 0xFF : 0x00
            let outcome = await self.runSinglePass(at: url, fillByte: fillByte)

            switch outcome {
            case .completed:
                continue
            case .cancelled:
                await self.finish(.cancelled)
                return
            case .failed(let message):
                await self.finish(.failed(message))
                return
            }
        }

        await self.finish(.done)
    }

    /// One create → fill → delete cycle. `fillByte` is the byte repeated
    /// through the whole file (0x00 = all 0-bits, 0xFF = all 1-bits).
    private nonisolated func runSinglePass(at url: URL, fillByte: UInt8) async -> PassOutcome {
        let fm = FileManager.default

        // Safety net: make sure the file is gone however we leave this pass.
        defer { try? fm.removeItem(at: url) }

        // Fresh, empty file.
        try? fm.removeItem(at: url)
        guard fm.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url) else {
            return .failed("Could not create the fill file.")
        }
        defer { try? handle.close() }

        // A reusable buffer of a single repeated byte (all 0-bits or all 1-bits).
        var chunkSize = 32 * 1024 * 1024          // start at 32 MB
        let minChunkSize = 64 * 1024               // stop refining below 64 KB
        var chunk = Data(repeating: fillByte, count: chunkSize)

        var written: Int64 = 0
        var lastUIUpdate = Date.distantPast

        while chunkSize >= minChunkSize {
            if Task.isCancelled {
                await self.report(written: written, available: Self.freeSpace(near: url))
                return .cancelled(written)
            }

            do {
                try handle.write(contentsOf: chunk)
                written += Int64(chunkSize)

                // Throttle UI updates so we don't flood the main actor.
                let now = Date()
                if now.timeIntervalSince(lastUIUpdate) > 0.12 {
                    lastUIUpdate = now
                    await self.report(written: written, available: Self.freeSpace(near: url))
                }
            } catch {
                // Disk is full (or nearly) for this chunk size — shrink and top it off.
                chunkSize /= 2
                chunk = Data(repeating: fillByte, count: chunkSize)
            }
        }

        try? handle.synchronize()
        await self.recordPeak(written)

        // Delete it again so this pass ends where it started.
        await self.setPhase(.deleting)
        try? handle.close()
        try? fm.removeItem(at: url)

        await self.report(written: written, available: Self.freeSpace(near: url))
        return .completed(written)
    }

    // MARK: - Main-actor updates

    private func beginPass(_ pass: Int) {
        currentPass = pass
        bytesWritten = 0
        startingFreeBytes = Self.freeSpace(near: fillURL)
        availableBytes = startingFreeBytes
        phase = .filling
    }

    private func report(written: Int64, available: Int64) {
        bytesWritten = written
        availableBytes = available
    }

    private func recordPeak(_ value: Int64) {
        peakBytesWritten = max(peakBytesWritten, value)
    }

    private func setPhase(_ value: Phase) {
        phase = value
    }

    private func finish(_ value: Phase) {
        phase = value
        worker = nil
    }

    // MARK: - Helpers

    private nonisolated static func freeSpace(near url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ]
        let values = try? url.resourceValues(forKeys: keys)
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 {
            return Int64(important)
        }
        if let available = values?.volumeAvailableCapacity, available > 0 {
            return Int64(available)
        }
        return 0
    }
}
