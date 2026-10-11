import Foundation

/// Status colour class shared by container and pod rows.
/// Views map it to `AeroTheme` colours: healthy green, warning yellow, failing red, inactive grey.
public enum WorkloadHealth: String, Codable, Sendable, Hashable, CaseIterable {
    /// Running and ready (green).
    case healthy
    /// Starting, pending, paused or partly ready (yellow).
    case warning
    /// Crash-looping, failed, unhealthy or exited with an error (red).
    case failing
    /// Finished cleanly or never started (grey).
    case inactive
}

extension PodInfo {
    /// Waiting reasons that mean the container cannot run without a change (red).
    static let failingWaitingReasons: Set<String> = [
        "CrashLoopBackOff", "ImagePullBackOff", "ErrImagePull", "InvalidImageName", "ErrImageNeverPull",
        "CreateContainerConfigError", "CreateContainerError", "RunContainerError",
    ]

    /// Status colour class:
    /// - Running with every container ready: healthy (green);
    /// - Pending, `ContainerCreating`, or Running but not all ready: warning (yellow);
    /// - Failed, `CrashLoopBackOff`, image pull errors, or a container terminated with an error:
    ///   failing (red);
    /// - Succeeded (`Completed`): inactive (grey).
    public var health: WorkloadHealth {
        switch phase {
        case .failed: return .failing
        case .succeeded: return .inactive
        case .pending, .running, .unknown: break
        }
        for container in containers {
            if let reason = container.waitingReason, Self.failingWaitingReasons.contains(reason) { return .failing }
            if container.isTerminated, container.terminatedReason == "Error" || (container.exitCode ?? 0) != 0 {
                return .failing
            }
        }
        if phase == .running, !containers.isEmpty, readyCount == containerCount { return .healthy }
        return .warning
    }

    /// `true` when a container is in `CrashLoopBackOff`, or is terminated with an error between
    /// restarts (the brief window before the kubelet's back-off kicks in).
    public var isCrashLooping: Bool {
        containers.contains { container in
            if container.waitingReason == "CrashLoopBackOff" { return true }
            let errored = container.terminatedReason == "Error" || (container.exitCode ?? 0) != 0
            return container.isTerminated && errored && container.restartCount > 0 && phase == .running
        }
    }

    /// kubectl-style STATUS text: the last container's waiting reason (`CrashLoopBackOff`,
    /// `ContainerCreating`), else its terminated reason (`Completed`, `Error`), else
    /// `ExitCode:N`; otherwise the phase (`Running`, `Pending`).
    public var displayStatus: String {
        for container in containers.reversed() {
            if let reason = container.waitingReason, !reason.isEmpty { return reason }
            if let reason = container.terminatedReason, !reason.isEmpty { return reason }
            if let code = container.exitCode { return "ExitCode:\(code)" }
        }
        return phase.rawValue
    }

    /// Short age from ``createdAt`` (`5m`, `3h`, `2d`), or `nil` when unknown.
    public func age(now: Date = .now) -> String? {
        createdAt.map { AgeFormat.short(since: $0, now: now) }
    }
}
