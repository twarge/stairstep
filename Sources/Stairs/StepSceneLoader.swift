import Foundation
import Observation
import StairsCore

@Observable
final class StepSceneLoader {
    enum Phase {
        case idle
        case loading
        case loaded(StepModel)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// Import completion in `0...1` while `phase == .loading`. Stays 0 for formats
    /// or stages that report no progress, so the UI falls back to an indeterminate
    /// indicator.
    private(set) var progress: Double = 0

    @ObservationIgnored private var loadTask: Task<Void, Never>?

    func load(data: Data, fileName: String) {
        loadTask?.cancel()
        phase = .loading
        progress = 0

        loadTask = Task {
            // Coalesce OCCT's frequent progress callbacks down to whole-percent
            // steps so we don't flood the main actor.
            let throttle = ProgressThrottle()
            let handler: @Sendable (Double) -> Void = { fraction in
                guard throttle.shouldReport(fraction) else { return }
                Task { @MainActor in
                    self.updateProgress(fraction)
                }
            }

            do {
                let model = try await Task.detached(priority: .userInitiated) {
                    try StepMeshImporter.load(data: data, fileName: fileName, progress: handler)
                }.value

                guard !Task.isCancelled else {
                    return
                }

                progress = 1
                phase = .loaded(model)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func updateProgress(_ fraction: Double) {
        // Drop stale callbacks that arrive after loading settled.
        guard case .loading = phase else {
            return
        }
        progress = min(max(fraction, progress), 1)
    }

    func cancel() {
        loadTask?.cancel()
        loadTask = nil
    }

    func reset() {
        loadTask?.cancel()
        loadTask = nil
        phase = .idle
        progress = 0
    }
}

/// Thread-safe whole-percent gate for progress callbacks that arrive from OCCT
/// worker threads. `nonisolated` so it can be used from the background import.
private nonisolated final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var lastPercent = -1

    func shouldReport(_ fraction: Double) -> Bool {
        let percent = Int((min(max(fraction, 0), 1) * 100).rounded(.down))
        lock.lock()
        defer { lock.unlock() }
        guard percent > lastPercent else {
            return false
        }
        lastPercent = percent
        return true
    }
}
