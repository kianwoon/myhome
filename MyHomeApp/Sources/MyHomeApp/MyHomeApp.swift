// baseline-guard:allow new source file, no prior baseline
import AppKit
import SwiftUI
import MyHomeCore

/// UI shell state: which surface the (single) panel hosting view shows.
/// General rule: the app renders in exactly ONE SwiftUI hosting view — the
/// MenuBarExtra panel. A second live Window scene re-renders concurrently on
/// macOS 27.x and its hosting view ping-pongs layout with the panel's
/// (100% CPU DisplayList recursion, sampled twice), so no second scene may
/// observe the store.
final class UIState: ObservableObject {
    @Published var showDashboard = false
    private var observer: NSObjectProtocol?

    init() {
        // General rule: the MenuBarExtra panel's hosting view NEVER gets
        // onDisappear (it stays alive across open/close), so view-lifecycle
        // hooks cannot reset panel state. The reliable signal is the panel
        // WINDOW resigning key — i.e. the user clicked anywhere else. That is
        // the moment the dashboard view must reset to the compact list.
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.showDashboard = false
            }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}

@main
struct MyHomeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = DeviceStore()
    @StateObject private var ui = UIState()

    var body: some Scene {
        MenuBarExtra {
            Group {
                if ui.showDashboard {
                    DashboardView()
                        .overlay(alignment: .topTrailing) {
                            Button {
                                ui.showDashboard = false
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .padding(6)
                            .help("Back to device list")
                        }
                } else {
                    MenuContentView()
                }
            }
                .environmentObject(store)
                .environmentObject(ui)
                // General rule: a MenuBarExtra .window panel must have fixed
                // geometry. Its hosting view stays alive while closed; with
                // content-driven height, every store write re-layouts it and,
                // alongside the dashboard window, the two hosts invalidate
                // each other (100% CPU render ping-pong, sampled in
                // DisplayList.ViewUpdater.update/updateInheritedView).
                .frame(width: 380, height: 520)
        } label: {
            ZStack {
                Image(systemName: "house")
                // General rule: a GUI defect needs a click-free repro path;
                // MYHOME_AUTOOPEN=1 shows the dashboard surface on launch.
                AutoOpenTrigger()
                    // Menu-bar labels render outside the scene's environment;
                    // inject the shell state explicitly.
                    .environmentObject(ui)
            }
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar only: no Dock icon, no app switcher entry.
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationWillTerminate(_ notification: Notification) {
        BridgeClient.shared.stop()
    }
}

/// Diagnostic-only launch trigger: opens the dashboard without a click so the
/// main window's layout/polling behavior can be reproduced headlessly.
struct AutoOpenTrigger: View {
    @EnvironmentObject private var ui: UIState

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                guard ProcessInfo.processInfo.environment["MYHOME_AUTOOPEN"] == "1" else {
                    return
                }
                Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    ui.showDashboard = true
                }
            }
    }
}
