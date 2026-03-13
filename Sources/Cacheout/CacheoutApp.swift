/// # CacheoutApp — Main Application Structure
///
/// The root `App` struct that defines Cacheout's three scenes and manages
/// the application lifecycle.
///
/// ## Scenes
///
/// 1. **Main Window** (`WindowGroup(id: "main")`): The primary content view showing
///    scan results, cache categories, node_modules, and cleanup controls.
///    Default size: 620×680, minimum: 560×500.
///
/// 2. **Menu Bar Extra** (`MenuBarExtra`): A persistent menubar popover with a compact
///    disk status gauge, top reclaimable categories, Docker prune button, and quick-clean
///    action. Displays free GB in the menubar title (e.g., "42GB").
///
/// 3. **Settings** (`Settings`): A three-tab preferences window (General, Cleaning,
///    Advanced) accessible via ⌘, keyboard shortcut.
///
/// ## Auto-Scan Timer
///
/// A 60-second tick timer checks whether a rescan is due based on the user's preferred
/// interval (default: 30 minutes). The timer uses fixed 60s ticks rather than the actual
/// interval because `Timer.publish` intervals are immutable after creation.
///
/// ## Low-Disk Notifications
///
/// When free space drops below the user-configured threshold (default: 10 GB), a local
/// notification is sent via `UNUserNotificationCenter`. Notifications are throttled to
/// at most once per hour. All notification APIs are guarded behind a `bundleIdentifier`
/// check to prevent crashes when running from `.build/release/` (unbundled binary).
///
/// ## First-Run Onboarding
///
/// On first launch, a sheet presents a 3-step onboarding flow that explains the
/// privileged helper's purpose and offers install/skip. The user's choice is
/// persisted via `OnboardingState` (UserDefaults). `registerHelperIfNeeded()` is
/// only called if the user chose to install during onboarding (or via the CLI).
/// Onboarding is suppressed when the helper is already enabled (e.g. CLI
/// `install-helper` ran before the first GUI launch).
///
/// ## Sparkle Integration
///
/// Uses `SPUStandardUpdaterController` for auto-update checks. Initialized with
/// `startingUpdater: false` to defer update checks until a signed appcast is configured.
/// The SPUUpdater is injected into the Settings tab via `ContentView(updater:)`.

import SwiftUI
import UserNotifications
import Sparkle
import os


struct CacheoutApp: App {
    @StateObject private var viewModel = CacheoutViewModel()

    /// Tracks whether onboarding sheet should be shown.
    /// Suppressed when the helper is already enabled (e.g. CLI installed before
    /// first GUI launch) even if onboarding was never formally completed.
    @State private var showOnboarding = !OnboardingState.isCompleted
        && HelperInstaller().status != .enabled

    /// Sparkle updater — initialized lazily, safe even without a bundle.
    /// Set SUFeedURL in Info.plist or pass an appcast URL to enable updates.
    private let updaterController: SPUStandardUpdaterController

    init() {
        // startingUpdater: false prevents auto-check until we have a signed appcast
        updaterController = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    }

    /// Periodic scan timer — uses customizable interval (default 30 min)
    /// Note: Timer.publish interval is fixed at creation, so we use 60s ticks
    /// and check elapsed time against the user's preferred interval.
    private let tickTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some Scene {
        // Main window
        WindowGroup(id: "main") {
            ContentView(updater: updaterController.updater)
                .environmentObject(viewModel)
                .frame(minWidth: 560, minHeight: 500)
                .sheet(isPresented: $showOnboarding) {
                    OnboardingView { _ in
                        // Install/skip was already handled inside OnboardingView
                        // with explicit user feedback. Just dismiss the sheet.
                        showOnboarding = false
                    }
                    .interactiveDismissDisabled()
                }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 620, height: 680)

        // Menubar mini-mode
        MenuBarExtra {
            MenuBarView()
                .environmentObject(viewModel)
                .onReceive(tickTimer) { _ in
                    Task { @MainActor in
                        if viewModel.shouldAutoRescan && !viewModel.isScanning {
                            await viewModel.scan()
                            checkLowDisk()
                        }
                    }
                }
                .task {
                    // Request notification permission on first launch
                    requestNotificationPermission()
                    // Register the privileged helper daemon only if the user
                    // chose install during onboarding AND registration hasn't
                    // already been done (enabled/requiresApproval are terminal).
                    if OnboardingState.didChooseInstallHelper == true {
                        let installer = HelperInstaller()
                        switch installer.status {
                        case .enabled, .requiresApproval, .notFound:
                            break // Already registered, pending approval, or unavailable
                        case .notRegistered:
                            registerHelperIfNeeded()
                        }
                    }
                    // Ensure the main window is visible on first launch so the
                    // onboarding sheet is presented even if only the menubar
                    // extra activated (e.g. future LSUIElement/LaunchAgent).
                    if !OnboardingState.isCompleted {
                        await MainActor.run {
                            NSApplication.shared.activate(ignoringOtherApps: true)
                            // The WindowGroup(id: "main") scene creates the main window
                            // at launch. Bring it to front for onboarding.
                            for window in NSApplication.shared.windows where
                                window.identifier?.rawValue.contains("main") == true {
                                window.makeKeyAndOrderFront(nil)
                            }
                        }
                    }
                }
        } label: {
            Label {
                Text(viewModel.menuBarTitle)
            } icon: {
                menuBarIconView
            }
        }
        .menuBarExtraStyle(.window)

        // Settings window (⌘,)
        Settings {
            SettingsView(updater: updaterController.updater)
                .environmentObject(viewModel)
        }
    }

    /// Custom menubar icon — uses the template image from Resources,
    /// with a warning badge overlay when disk usage is critical.
    @ViewBuilder
    private var menuBarIconView: some View {
        let img = Image(nsImage: menuBarNSImage)
        if let pct = viewModel.diskInfo?.usedPercentage, pct > 0.95 {
            img.overlay(alignment: .bottomTrailing) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 8, weight: .bold))
            }
        } else {
            img
        }
    }

    /// Load the template image from the bundle, falling back to SF Symbol
    private var menuBarNSImage: NSImage {
        if let img = Bundle.main.image(forResource: "MenuBarIconTemplate") {
            img.isTemplate = true
            img.size = NSSize(width: 18, height: 18)
            return img
        }
        // Fallback: SF Symbol
        return NSImage(systemSymbolName: "externaldrive.fill", accessibilityDescription: "Cacheout")
            ?? NSImage()
    }

    // MARK: - Helper registration

    private func registerHelperIfNeeded() {
        let installer = HelperInstaller()
        do {
            try installer.installIfNeeded()
        } catch {
            // Log but don't crash — helper features will be unavailable
            Logger(subsystem: "com.cacheout", category: "app")
                .error("Helper registration failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Low-disk notification

    /// UNUserNotificationCenter crashes without a proper app bundle (e.g. running
    /// from .build/release/). Guard all calls behind a bundleIdentifier check.
    private var canUseNotifications: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    private func requestNotificationPermission() {
        guard canUseNotifications else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func checkLowDisk() {
        guard canUseNotifications else { return }
        guard let disk = viewModel.diskInfo else { return }
        let freeGB = Double(disk.freeSpace) / (1024 * 1024 * 1024)

        // Notify when free space drops below user-configured threshold
        guard freeGB < viewModel.lowDiskThresholdGB else { return }

        // Throttle: don't nag more than once per hour
        let lastKey = "cacheout.lastLowDiskNotification"
        let lastNotif = UserDefaults.standard.double(forKey: lastKey)
        guard Date().timeIntervalSince1970 - lastNotif > 3600 else { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastKey)

        let content = UNMutableNotificationContent()
        content.title = "Disk Space Low"
        content.body = String(format: "Only %.1f GB free. Open Cacheout to reclaim %.1f GB of caches.",
                              freeGB,
                              Double(viewModel.totalRecoverable) / (1024 * 1024 * 1024))
        content.sound = .default

        let request = UNNotificationRequest(identifier: "lowDisk", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
