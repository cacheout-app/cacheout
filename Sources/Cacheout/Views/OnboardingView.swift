/// # OnboardingView — First-Run Onboarding Flow
///
/// A multi-step SwiftUI onboarding flow shown on first launch. It explains the
/// privileged helper's purpose, offers the user a choice to install or skip,
/// attempts installation with feedback, and persists the decision via UserDefaults.
///
/// ## Steps
///
/// 1. **Welcome** — Introduces Cacheout and its capabilities.
/// 2. **Helper Explanation** — Explains what the privileged helper enables
///    (memory management, process control) and what works without it
///    (disk cache cleaning, system-level stats).
/// 3. **Install/Skip** — Lets the user install the helper or skip for now.
/// 4. **Result** — Shows the install outcome before dismissing.
///
/// ## Persistence
///
/// Onboarding completion is stored in `UserDefaults` under the key
/// `cacheout.onboardingCompleted`. The helper installation choice is stored
/// under `cacheout.helperChoiceInstall` (true = install, false = skipped).
///
/// ## Degraded Mode
///
/// When the helper is skipped:
/// - Caches tab: fully functional
/// - Memory tab: system-level stats only (no jetsam controls)
/// - Processes tab: read-only (no kill/freeze actions)
/// - Settings tab: limited options

import SwiftUI

struct OnboardingView: View {
    /// Called when onboarding completes. The Bool indicates whether the helper
    /// was successfully installed (true) or skipped/failed (false).
    let onComplete: (Bool) -> Void

    @State private var currentStep = 0
    @State private var installResult: InstallResult?

    /// Possible outcomes of the helper install attempt.
    enum InstallResult {
        case enabled
        case requiresApproval
        case unavailable
        case failed(String)
        case skipped
    }

    /// Number of dots to show (3 for steps 0-2, hides on result step).
    private var totalSteps: Int { 3 }

    var body: some View {
        VStack(spacing: 0) {
            // Step content
            Group {
                switch currentStep {
                case 0:
                    welcomeStep
                case 1:
                    helperExplanationStep
                case 2:
                    installChoiceStep
                case 3:
                    resultStep
                default:
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.slide)
            .animation(.easeInOut(duration: 0.3), value: currentStep)

            // Navigation dots + buttons
            HStack {
                // Step indicator dots (hidden on result step)
                if currentStep < 3 {
                    HStack(spacing: 8) {
                        ForEach(0..<totalSteps, id: \.self) { step in
                            Circle()
                                .fill(step == currentStep ? Color.accentColor : Color.secondary.opacity(0.3))
                                .frame(width: 8, height: 8)
                        }
                    }
                }

                Spacer()

                // Navigation buttons
                if currentStep < 2 {
                    Button("Continue") {
                        withAnimation {
                            currentStep += 1
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding()
        }
        .frame(width: 520, height: 400)
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "externaldrive.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)

            Text("Welcome to Cacheout")
                .font(.largeTitle.bold())

            Text("Cacheout helps you reclaim disk space by finding and cleaning developer caches, build artifacts, and package manager leftovers.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            Spacer()
        }
        .padding()
    }

    // MARK: - Step 2: Helper Explanation

    private var helperExplanationStep: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "lock.shield")
                .font(.system(size: 48))
                .foregroundStyle(.tint)

            Text("Privileged Helper")
                .font(.title.bold())

            Text("Cacheout can install a small privileged helper to enable advanced memory management features.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            VStack(alignment: .leading, spacing: 12) {
                featureRow(icon: "checkmark.circle.fill", color: .green,
                           title: "Without helper",
                           detail: "Disk cache cleaning, system memory stats, read-only process list")
                featureRow(icon: "plus.circle.fill", color: .blue,
                           title: "With helper",
                           detail: "Jetsam memory limits, process freeze/terminate, memory pressure relief")
            }
            .padding(.horizontal, 40)
            .padding(.top, 8)

            Spacer()
        }
        .padding()
    }

    // MARK: - Step 3: Install/Skip

    private var installChoiceStep: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "arrow.down.circle")
                .font(.system(size: 48))
                .foregroundStyle(.tint)

            Text("Install Helper?")
                .font(.title.bold())

            Text("You can install the helper now or skip and use Cacheout in limited mode. You can always install later from the CLI.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            VStack(spacing: 12) {
                Button {
                    attemptInstall()
                } label: {
                    Label("Install Helper", systemImage: "lock.shield.fill")
                        .frame(maxWidth: 200)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    installResult = .skipped
                    OnboardingState.markCompleted(helperInstall: false)
                    withAnimation { currentStep = 3 }
                } label: {
                    Text("Skip for Now")
                        .frame(maxWidth: 200)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .foregroundStyle(.secondary)
            }
            .padding(.top, 8)

            Text("You can install the helper later with: cacheout --cli install-helper")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Spacer()
        }
        .padding()
    }

    // MARK: - Step 4: Result

    private var resultStep: some View {
        VStack(spacing: 20) {
            Spacer()

            Group {
                switch installResult {
                case .enabled:
                    resultContent(
                        icon: "checkmark.circle.fill",
                        color: .green,
                        title: "Helper Installed",
                        message: "The privileged helper is active. All features are available."
                    )
                case .requiresApproval:
                    resultContent(
                        icon: "person.fill.checkmark",
                        color: .orange,
                        title: "Approval Required",
                        message: "The helper was registered but requires your approval in System Settings > General > Login Items & Extensions."
                    )
                case .unavailable:
                    resultContent(
                        icon: "info.circle.fill",
                        color: .secondary,
                        title: "Helper Unavailable",
                        message: "The helper is not available in this build. Install Cacheout via Homebrew cask for full functionality, or use the app in limited mode."
                    )
                case .failed(let error):
                    resultContent(
                        icon: "exclamationmark.triangle.fill",
                        color: .red,
                        title: "Installation Failed",
                        message: "Could not register the helper: \(error). You can try again later with: cacheout --cli install-helper"
                    )
                case .skipped:
                    resultContent(
                        icon: "arrow.right.circle.fill",
                        color: .secondary,
                        title: "Helper Skipped",
                        message: "Cacheout will run in limited mode. You can install the helper anytime with: cacheout --cli install-helper"
                    )
                case .none:
                    EmptyView()
                }
            }

            Button("Get Started") {
                let installed = if case .enabled = installResult { true } else { false }
                onComplete(installed)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)

            Spacer()
        }
        .padding()
    }

    private func resultContent(icon: String, color: Color, title: String, message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundStyle(color)

            Text(title)
                .font(.title.bold())

            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
        }
    }

    // MARK: - Helpers

    private func featureRow(icon: String, color: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .font(.title3)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func attemptInstall() {
        let installer = HelperInstaller()
        let status = installer.status

        // Persist user intent as true — the user chose install. On failure
        // or unavailability, this lets the app retry on next launch (the
        // launch-time gate only attempts registration for .notRegistered).
        if status == .notFound {
            installResult = .unavailable
            OnboardingState.markCompleted(helperInstall: true)
            withAnimation { currentStep = 3 }
            return
        }

        do {
            try installer.installIfNeeded()
            let newStatus = installer.status
            if newStatus == .enabled {
                installResult = .enabled
            } else {
                installResult = .requiresApproval
            }
            OnboardingState.markCompleted(helperInstall: true)
        } catch {
            installResult = .failed(error.localizedDescription)
            // Persist intent as true so the app retries on next launch
            OnboardingState.markCompleted(helperInstall: true)
        }

        withAnimation { currentStep = 3 }
    }
}

// MARK: - Onboarding State

/// Persisted onboarding state stored in UserDefaults.
enum OnboardingState {
    private static let completedKey = "cacheout.onboardingCompleted"
    private static let helperChoiceKey = "cacheout.helperChoiceInstall"

    /// Whether the onboarding flow has been completed.
    static var isCompleted: Bool {
        UserDefaults.standard.bool(forKey: completedKey)
    }

    /// Whether the user wants the helper installed (via onboarding or CLI).
    /// Returns nil if neither onboarding nor CLI has set a preference yet.
    static var didChooseInstallHelper: Bool? {
        guard UserDefaults.standard.object(forKey: helperChoiceKey) != nil else { return nil }
        return UserDefaults.standard.bool(forKey: helperChoiceKey)
    }

    /// Mark onboarding as completed with the given helper install choice.
    /// Called only from the GUI onboarding flow.
    static func markCompleted(helperInstall: Bool) {
        UserDefaults.standard.set(true, forKey: completedKey)
        UserDefaults.standard.set(helperInstall, forKey: helperChoiceKey)
    }

    /// Update only the helper preference without affecting onboarding
    /// completion. Used by CLI install-helper/uninstall-helper commands.
    static func setHelperPreference(install: Bool) {
        UserDefaults.standard.set(install, forKey: helperChoiceKey)
    }
}
