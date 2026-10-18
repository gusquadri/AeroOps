import AeroCore
import Foundation
import Observation
import SSHKit
import Synchronization

/// One queued upload or download of one or more items (folders included).
@MainActor
@Observable
final class FileTransfer: Identifiable {
    enum Direction {
        case upload
        case download
    }

    enum Phase: Equatable {
        case waiting
        /// Connecting and walking the folders.
        case preparing
        case copying
        /// Done; some items may have failed (``FileTransfer/failures``).
        case finished
        case failed(String)
        case cancelled

        var isActive: Bool { self == .preparing || self == .copying }
        var isOver: Bool { !isActive && self != .waiting }
    }

    typealias Run = @MainActor (FileTransfer, TransferProgress) async throws -> Void

    let id = UUID()
    let direction: Direction
    let hostID: RemoteHost.ID
    let title: String
    let destination: String
    var phase: Phase = .waiting
    private(set) var totalBytes: Int64 = 0
    private(set) var copiedBytes: Int64 = 0
    private(set) var fileCount = 0
    private(set) var currentFile: String?
    var failures: [SFTPTransferFailure] = []
    /// Items left out (special files, links to folders inside folders), with the reason.
    private(set) var skipped: [String] = []
    var started: Date?
    var ended: Date?

    @ObservationIgnored var task: Task<Void, Never>?
    @ObservationIgnored let run: Run
    @ObservationIgnored let completion: @MainActor () -> Void

    init(
        direction: Direction,
        hostID: RemoteHost.ID,
        title: String,
        destination: String,
        run: @escaping Run,
        completion: @escaping @MainActor () -> Void
    ) {
        self.direction = direction
        self.hostID = hostID
        self.title = title
        self.destination = destination
        self.run = run
        self.completion = completion
    }

    /// Fraction copied, once the size is known.
    var fraction: Double? {
        guard phase == .copying || phase == .finished, totalBytes > 0 else { return nil }
        return min(1, Double(copiedBytes) / Double(totalBytes))
    }

    /// Bytes per second since the copy started.
    var speed: Double? {
        guard let started, copiedBytes > 0 else { return nil }
        let elapsed = (ended ?? .now).timeIntervalSince(started)
        return elapsed > 0.5 ? Double(copiedBytes) / elapsed : nil
    }

    func begin(totalBytes: Int64, files: Int, skipped: [String]) {
        self.totalBytes = totalBytes
        fileCount = files
        self.skipped = skipped
        // Speed counts from here, not from connecting and walking folders.
        started = .now
        phase = .copying
    }

    func update(_ progress: TransferProgress) {
        let snapshot = progress.snapshot
        if copiedBytes != snapshot.bytes { copiedBytes = snapshot.bytes }
        if currentFile != snapshot.file { currentFile = snapshot.file }
    }

    /// "report.pdf", or "report.pdf and 2 more".
    static func title(for names: [String]) -> String {
        guard let first = names.first else { return "" }
        return names.count == 1 ? first : "\(first) and \(names.count - 1) more"
    }
}

/// Progress reported by SSHKit from its own tasks, read by the UI a few times a second.
final class TransferProgress: Sendable {
    private let state = Mutex<(bytes: Int64, file: String?)>((0, nil))

    func record(_ event: SFTPTransferEvent) {
        state.withLock { state in
            switch event {
            case .file(let path): state.file = path
            case .bytes(let count): state.bytes += count
            }
        }
    }

    var snapshot: (bytes: Int64, file: String?) {
        state.withLock { $0 }
    }
}

/// Transfers in the order they were added; a few run at once, the rest wait.
@MainActor
@Observable
final class FileTransferQueue {
    private(set) var transfers: [FileTransfer] = []
    /// Transfers running at once.
    let concurrentTransfers: Int

    init(concurrentTransfers: Int = 2) {
        self.concurrentTransfers = concurrentTransfers
    }

    func add(_ transfer: FileTransfer) {
        transfers.append(transfer)
        schedule()
    }

    func cancel(_ transfer: FileTransfer) {
        switch transfer.phase {
        case .waiting:
            transfer.phase = .cancelled
            transfer.ended = .now
        case .preparing, .copying:
            transfer.task?.cancel()
        case .finished, .failed, .cancelled:
            break
        }
    }

    func cancelAll() {
        for transfer in transfers { cancel(transfer) }
    }

    func remove(_ transfer: FileTransfer) {
        guard !transfer.phase.isActive else { return }
        transfers.removeAll { $0.id == transfer.id }
    }

    func clearFinished() {
        transfers.removeAll { $0.phase.isOver }
    }

    /// "All done", "2 running", "1 running, 3 waiting".
    var summary: String {
        let active = transfers.count { $0.phase.isActive }
        let waiting = transfers.count { $0.phase == .waiting }
        return switch (active, waiting) {
        case (0, 0): "All done"
        case (_, 0): "\(active) running"
        default: "\(active) running, \(waiting) waiting"
        }
    }

    /// Starts waiting transfers while fewer than ``concurrentTransfers`` run.
    private func schedule() {
        var running = transfers.count { $0.phase.isActive }
        for transfer in transfers where transfer.phase == .waiting && running < concurrentTransfers {
            start(transfer)
            running += 1
        }
    }

    private func start(_ transfer: FileTransfer) {
        transfer.phase = .preparing
        transfer.started = .now
        let progress = TransferProgress()
        transfer.task = Task { [weak self] in
            let ticker = Task {
                while !Task.isCancelled {
                    transfer.update(progress)
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            do {
                try await transfer.run(transfer, progress)
                transfer.phase = .finished
            } catch {
                transfer.phase = Task.isCancelled || error is CancellationError
                    ? .cancelled
                    : .failed(error.localizedDescription)
            }
            ticker.cancel()
            transfer.update(progress)
            transfer.ended = .now
            transfer.completion()
            self?.schedule()
        }
    }
}
