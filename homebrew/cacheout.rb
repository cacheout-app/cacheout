cask "cacheout" do
  # NOTE: version and sha256 are filled at release time after notarized DMG is produced.
  # Do NOT `brew install` from this file until a release artifact exists.
  version "2.0.0"
  sha256 "6de067232a27cdf2d46c20b6b8d5d135b8d2cb21199f13b9fe384ae7abb66942"

  url "https://github.com/cacheout-app/cacheout/releases/download/v#{version}/Cacheout-#{version}.dmg"
  name "Cacheout"
  desc "Developer cache cleaner & memory manager for macOS — reclaim disk space and manage system memory"
  homepage "https://github.com/cacheout-app/cacheout"

  depends_on macos: ">= :sonoma"

  app "Cacheout.app"

  binary "#{appdir}/Cacheout.app/Contents/MacOS/Cacheout", target: "cacheout"

  postflight do
    # First-run onboarding in the GUI will prompt for helper installation.
    # Users can also install/uninstall the helper via CLI:
    #   cacheout --cli install-helper
    #   cacheout --cli uninstall-helper
  end

  # Unregister the privileged helper and stop the daemon before the app bundle
  # is removed. The bundled binary is required for SMAppService unregistration,
  # so this must run while Cacheout.app still exists.
  uninstall_preflight do
    helper_binary = "#{appdir}/Cacheout.app/Contents/MacOS/Cacheout"
    if File.exist?(helper_binary)
      # Unregister the SMAppService daemon registration (best-effort:
      # helper may never have been installed, or bundle may be damaged)
      system_command helper_binary,
                     args: ["--cli", "uninstall-helper"],
                     must_succeed: false,
                     print_stderr: false
      # Stop the running daemon process if active (best-effort:
      # daemon may not be running, or may never have been approved)
      system_command "/bin/launchctl",
                     args: ["bootout", "system/com.cacheout.memhelper"],
                     sudo: true,
                     must_succeed: false,
                     print_stderr: false
    end
  end

  zap trash: [
    "~/.cacheout",
    "~/Library/Preferences/com.cacheout.app.plist",
    "~/Library/Caches/com.cacheout.app",
  ]

  caveats <<~EOS
    Cacheout runs as a menubar app with a 4-tab main window
    (Caches, Memory, Processes, Settings).

    On first launch, an onboarding flow will offer to install the
    privileged helper for advanced memory management features.
    Without the helper, disk cache cleaning and system stats still work.

    On `brew uninstall --cask cacheout`, the uninstaller attempts to
    unregister the helper and stop the daemon (best-effort, requires sudo).
    To manually manage: cacheout --cli install-helper / uninstall-helper
    To manually stop a running daemon after removal:
      sudo launchctl bootout system/com.cacheout.memhelper

    CLI interface (headless, JSON output):
      cacheout --cli version          # Show version + capabilities
      cacheout --cli scan             # List all cache categories
      cacheout --cli clean <slugs>    # Clean specific categories
      cacheout --cli smart-clean 5.0  # Auto-clean safe categories
      cacheout --cli disk-info        # Show disk space info
      cacheout --cli memory-stats     # System memory statistics
      cacheout --cli top-processes    # Top memory consumers
      cacheout --cli memory-pressure  # Current pressure classification
      cacheout --cli recommendations  # Advisory recommendations
      cacheout --cli intervene <name> # Execute memory intervention
      cacheout --cli install-helper   # Register privileged helper
      cacheout --cli uninstall-helper # Unregister privileged helper

    Daemon mode (long-lived headless monitoring):
      cacheout --daemon               # Start daemon with socket server
      cacheout --daemon --help        # Show daemon options

    The MCP server (cacheout-mcp) is available separately:
      pip install cacheout-mcp
  EOS
end
