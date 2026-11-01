import Foundation
import LocalAuthentication
import Testing
@testable import KeyAgent

@Suite("App lock")
struct AppLockTests {
    /// A lock with its launch prompt up.
    private func prompting() throws -> (lock: AppLock, attempt: AppLock.Attempt) {
        var lock = AppLock()
        let attempt = lock.sceneChanged(to: .active)
        return (lock, try #require(attempt))
    }

    private func finished(with outcome: AppLock.Outcome) throws -> AppLock {
        var (lock, attempt) = try prompting()
        lock.finish(attempt, with: outcome)
        return lock
    }

    @Test func startsLocked() {
        #expect(!AppLock().isUnlocked)
        #expect(AppLock().covers(showingSamples: false))
    }

    @Test func unlocksOnlyOnSuccess() throws {
        #expect(try finished(with: .success).isUnlocked)
        #expect(try !finished(with: .failed).isUnlocked)
        #expect(try !finished(with: .passcodeNotSet).isUnlocked)
    }

    @Test func aDeviceWithoutAPasscodeStaysLockedAndSaysSo() throws {
        let lock = try finished(with: .passcodeNotSet)
        #expect(lock.needsPasscode)
        #expect(lock.covers(showingSamples: false))
        #expect(try !finished(with: .failed).needsPasscode)
    }

    @Test func inactiveDoesNotLock() throws {
        var lock = try finished(with: .success)
        #expect(lock.sceneChanged(to: .inactive) == nil)
        #expect(lock.isUnlocked)
    }

    @Test func backgroundLocks() throws {
        var lock = try finished(with: .success)
        #expect(lock.sceneChanged(to: .background) == nil)
        #expect(!lock.isUnlocked)
    }

    @Test func theSceneComingBackFromAPromptDoesNotPromptAgain() throws {
        var (lock, attempt) = try prompting()
        #expect(lock.sceneChanged(to: .inactive) == nil)
        lock.finish(attempt, with: .failed)
        #expect(lock.sceneChanged(to: .active) == nil)
        #expect(!lock.isUnlocked)
    }

    @Test func theBackgroundArmsTheNextPrompt() throws {
        var lock = try finished(with: .success)
        _ = lock.sceneChanged(to: .background)
        #expect(lock.sceneChanged(to: .active) != nil)
    }

    @Test func aFailedAttemptCanBeRetried() throws {
        var lock = try finished(with: .failed)
        let retry = lock.requestUnlock()
        lock.finish(try #require(retry), with: .success)
        #expect(lock.isUnlocked)
    }

    @Test func onlyOnePromptAtATime() throws {
        var (lock, attempt) = try prompting()
        #expect(lock.requestUnlock() == nil)
        lock.finish(attempt, with: .failed)
        #expect(lock.requestUnlock() != nil)
    }

    @Test func nothingToPromptForOnceUnlocked() throws {
        var lock = try finished(with: .success)
        #expect(lock.requestUnlock() == nil)
    }

    @Test func aResultArrivingAfterTheBackgroundDoesNotUnlock() throws {
        var (lock, attempt) = try prompting()
        _ = lock.sceneChanged(to: .background)
        lock.finish(attempt, with: .success)
        #expect(!lock.isUnlocked)
    }

    @Test func anEarlierAttemptsResultDoesNotUnlockANewerOne() throws {
        var (lock, first) = try prompting()
        _ = lock.sceneChanged(to: .background)
        let second = lock.sceneChanged(to: .active)
        lock.finish(first, with: .success)
        #expect(!lock.isUnlocked)
        #expect(lock.requestUnlock() == nil)
        lock.finish(try #require(second), with: .success)
        #expect(lock.isUnlocked)
    }

    @Test func onlyADeviceThatCannotAuthenticateIsOfferedSamplesOnTheLockScreen() throws {
        #expect(try finished(with: .passcodeNotSet).offersSampleServers)
        #expect(try !finished(with: .failed).offersSampleServers)
        #expect(try !finished(with: .success).offersSampleServers)
    }

    @Test func samplesOpenWithoutUnlockingAndLeavingThemReturnsToTheLock() throws {
        let lock = try finished(with: .passcodeNotSet)
        #expect(!lock.covers(showingSamples: true))
        #expect(!lock.isUnlocked)
        #expect(lock.covers(showingSamples: false))
    }

    @Test func leavingSamplesAfterARelockReturnsToTheLock() throws {
        var lock = try finished(with: .success)
        #expect(!lock.covers(showingSamples: false))
        _ = lock.sceneChanged(to: .background)
        #expect(!lock.covers(showingSamples: true))
        #expect(lock.covers(showingSamples: false))
    }

    @Test func settingAPasscodeLaterUnlocksThroughThePrompt() throws {
        var lock = try finished(with: .passcodeNotSet)
        _ = lock.sceneChanged(to: .background)
        let attempt = lock.sceneChanged(to: .active)
        lock.finish(try #require(attempt), with: .success)
        #expect(lock.isUnlocked)
        #expect(!lock.needsPasscode)
        #expect(!lock.offersSampleServers)
    }

    @Test func onlyAMissingPasscodeIsToldApartFromFailure() {
        func outcome(_ code: LAError.Code) -> AppLock.Outcome {
            AppLock.Outcome(failure: NSError(domain: LAErrorDomain, code: code.rawValue))
        }
        #expect(outcome(.passcodeNotSet) == .passcodeNotSet)
        #expect(outcome(.userCancel) == .failed)
        #expect(outcome(.biometryLockout) == .failed)
        #expect(outcome(.appCancel) == .failed)
        #expect(AppLock.Outcome(failure: nil) == .failed)
    }
}
