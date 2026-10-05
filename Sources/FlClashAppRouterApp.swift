import SwiftUI
import AppKit

@main
struct FlClashAppRouterApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(AppRouterModel.shared)
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: NSApplication.willTerminateNotification)
                ) { _ in
                    // Cmd+Q 退出兜底：若恰好在重载窗口期（FLClash 被 kill 未拉起），负责拉起它
                    AppRouterModel.shared.ensureFlClashAliveBeforeExit()
                }
        }
        .windowResizability(.contentSize)
    }
}
