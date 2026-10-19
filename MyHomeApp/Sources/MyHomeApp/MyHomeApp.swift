// baseline-guard:allow new source file, no prior baseline
import AppKit
import SwiftUI
import MyHomeCore

@main
struct MyHomeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = DeviceStore()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(store)
        } label: {
            Image(systemName: "house")
        }
        .menuBarExtraStyle(.window)

        Window("MyHome", id: "dashboard") {
            DashboardView()
                .environmentObject(store)
        }
        .defaultSize(width: 760, height: 520)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
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
