import SwiftUI
import AppKit

@main
struct StudioApp: App {
    @State private var model = StudioModel()
    var body: some Scene {
        Window("NX Port Studio", id: "main") {
            StudioView(model: model)
                .preferredColorScheme(.dark)
                .frame(minWidth: 900, minHeight: 660)
                .task { await model.initialize() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.runner.cancelImmediately() }
        }
        .defaultSize(width: 1160, height: 810)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .help) {
                Button(t("nxnative documentation")) { model.openURL("https://github.com/seedds/nxnative") }
                Button(t("Mac guide")) { model.openURL("https://www.applegamingwiki.com/wiki/Nxnative_Switch_to_Mac_conversion") }
            }
        }
    }
}

func t(_ key: String) -> String {
    guard let url = Bundle.module.url(forResource: "es", withExtension: "lproj", subdirectory: "Resources"),
          let bundle = Bundle(url: url) else { return key }
    return bundle.localizedString(forKey: key, value: key, table: nil)
}
