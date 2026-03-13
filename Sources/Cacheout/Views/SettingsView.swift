/// # SettingsView — Preferences Window (Cmd+,)
///
/// Wraps `SettingsContentView` for use in the macOS Settings scene.
/// The same content is also embedded in the main window's Settings tab
/// via `ContentView(updater:)` which passes the SPUUpdater through.
///
/// This thin wrapper exists so the Settings scene and the tab can share
/// identical preferences UI while the scene passes in the SPUUpdater.

import SwiftUI
import Sparkle

struct SettingsView: View {
    @EnvironmentObject var viewModel: CacheoutViewModel
    let updater: SPUUpdater

    var body: some View {
        SettingsContentView(updater: updater)
            .environmentObject(viewModel)
            .frame(width: 460, height: 320)
    }
}
