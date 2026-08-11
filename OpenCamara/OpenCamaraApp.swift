import SwiftUI

@main
struct OpenCamaraApp: App {
    @StateObject private var localization = LocalizationManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 960, minHeight: 640)
                .environmentObject(localization)
                .environment(\.locale, localization.locale)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .defaultSize(width: 1180, height: 760)
    }
}
