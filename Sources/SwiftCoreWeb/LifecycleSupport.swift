// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

#if canImport(UIKit)
import UIKit
#endif
import Foundation
import os

private let lifecycleLogger = Logger(subsystem: "SwiftCoreWeb", category: "server")

#if canImport(UIKit)
/// Keep-awake, screen dimming, and kiosk-mode helpers (the concurrency/lifecycle/network watchdog design). All are
/// `@MainActor` since they touch `UIApplication`/`UIScreen`.
@MainActor
final class KeepAwakeController {
    private var previousIdleTimerDisabled = false
    private var dimConfig: (after: TimeInterval, brightness: CGFloat)?
    private var dimTimer: Timer?
    private var previousBrightness: CGFloat = 1.0
    private var isDimmed = false

    /// Sets `isIdleTimerDisabled = true` so the device never auto-locks while
    /// serving. Called on server start and re-applied on every return to
    /// `.active`, since iOS can silently reset the idle timer.
    func applyKeepAwake() {
        previousIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        lifecycleLogger.debug("Idle timer disabled (keep device awake)")
    }

    /// Restores the previous idle-timer state. Called from `stopAsync()`.
    func restoreIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled
        stopDimming()
    }

    /// Lowers screen brightness after `after` seconds of touch inactivity,
    /// down to `brightness` (0...1). The screen stays on (no sleep, idle
    /// timer stays disabled); only brightness drops, for power saving on a
    /// dedicated device. Restored to the prior brightness on touch.
    func configureDimming(after: TimeInterval, brightness: CGFloat) {
        dimConfig = (after, brightness)
        resetDimTimer()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(userDidInteract),
            name: UIApplication.userDidTakeScreenshotNotification,
            object: nil
        )
    }

    @objc private func userDidInteract() {
        resetDimTimer()
    }

    /// Call from a `UIEvent`-observing tap/gesture hook in the hosting app
    /// (documented in the showcase) to reset the idle-to-dim countdown.
    func noteUserInteraction() {
        resetDimTimer()
    }

    private func resetDimTimer() {
        guard let dimConfig else { return }
        if isDimmed {
            UIScreen.main.brightness = previousBrightness
            isDimmed = false
        }
        dimTimer?.invalidate()
        dimTimer = Timer.scheduledTimer(withTimeInterval: dimConfig.after, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.dim() }
        }
    }

    private func dim() {
        guard let dimConfig else { return }
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            lifecycleLogger.notice("Low Power Mode is active while dimming for idle power saving")
        }
        if ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical {
            lifecycleLogger.warning("Thermal state is elevated (\(String(describing: ProcessInfo.processInfo.thermalState))) while dimming")
        }
        previousBrightness = UIScreen.main.brightness
        UIScreen.main.brightness = dimConfig.brightness
        isDimmed = true
    }

    private func stopDimming() {
        dimTimer?.invalidate()
        dimTimer = nil
        if isDimmed {
            UIScreen.main.brightness = previousBrightness
            isDimmed = false
        }
        dimConfig = nil
        NotificationCenter.default.removeObserver(self)
    }
}
#endif

extension WebApplication {
    /// Requests Autonomous Single App Mode (kiosk mode) so the user cannot
    /// leave the app while it serves. Requires a supervised device under MDM;
    /// on an unsupervised device this fails and the app should fall back to
    /// documenting manual Guided Access (Settings > Accessibility > Guided
    /// Access) to the operator.
    ///
    /// - Returns: `true` if the request succeeded.
    @MainActor
    @discardableResult
    public func requestSingleAppMode() async -> Bool {
        #if canImport(UIKit)
        let succeeded = await withCheckedContinuation { continuation in
            UIAccessibility.requestGuidedAccessSession(enabled: true) { didSucceed in
                continuation.resume(returning: didSucceed)
            }
        }
        if succeeded {
            lifecycleLogger.info("Autonomous Single App Mode session requested successfully")
        } else {
            lifecycleLogger.warning("Autonomous Single App Mode request failed — requires a supervised device under MDM; falling back to manual Guided Access")
        }
        return succeeded
        #else
        return false
        #endif
    }
}

#if canImport(UIKit)
/// Binds server lifecycle to iOS app lifecycle (the concurrency/lifecycle/network watchdog design): backgrounding (by the
/// user, or a system interruption) stops the server gracefully after
/// requesting background execution time; returning to `.active` restarts it
/// on the same port and re-applies keep-awake. iOS can suspend the app at
/// any point outside kiosk mode — no API prevents that, so this only makes
/// the transition graceful rather than preventing it.
@MainActor
public final class LifecycleBinding {
    private let app: WebApplication
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var wasRunning = false

    init(app: WebApplication) {
        self.app = app
        NotificationCenter.default.addObserver(
            self, selector: #selector(didEnterBackground),
            name: UIApplication.didEnterBackgroundNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(didBecomeActive),
            name: UIApplication.didBecomeActiveNotification, object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func didEnterBackground() {
        guard app.isRunning else { return }
        wasRunning = true
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "SwiftCoreWeb.shutdown") { [weak self] in
            self?.endBackgroundTask()
        }
        Task {
            try? await app.stopAsync()
            await MainActor.run { self.endBackgroundTask() }
        }
    }

    @objc private func didBecomeActive() {
        guard wasRunning, !app.isRunning else { return }
        wasRunning = false
        Task {
            try? await app.runAsync()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}

extension WebApplication {
    /// Installs the lifecycle binding described above (UIKit notifications
    /// variant). A SwiftUI `ScenePhase`-driven equivalent is documented in
    /// the showcase for apps that prefer observing `@Environment(\.scenePhase)`
    /// directly and calling `stopAsync()`/`runAsync()` from `onChange`.
    @MainActor
    @discardableResult
    public func bindToLifecycle() -> LifecycleBinding {
        LifecycleBinding(app: self)
    }
}
#endif
