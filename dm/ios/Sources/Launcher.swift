// Launcher: a settings screen shown before the game starts (front_ios.m dm_show_launcher). It sets the same environment switches as Documents/env.txt (DM_FPS_TARGET, DM_RENDER_SCALE,
// DM_OPMODE, DM_SHOW_FPS, DM_METAL_HUD, DM_LANG), which take precedence when both set one: env.txt is read first and the launcher never overwrites a value already set.
// The choices are kept in UserDefaults; only the settings the game profile supports are shown (fps_target for the frame rate, render_scale for the render scale).
// DM_LAUNCHER=0 in env.txt skips the screen and starts the game at once.
import SwiftUI
import UIKit
import os

private let defaults = UserDefaults.standard

private struct Profile {
    let fpsTarget: Int      // the profile's fps_target (0 = the game has no frame step: no frame-rate setting)
    let renderScale: Bool   // the profile's render_scale
    let docked: Bool        // the profile's op_mode
}

private func info(_ key: String) -> Any? { Bundle.main.object(forInfoDictionaryKey: key) }

private func languageName(_ code: String) -> String {
    let name = Locale.current.localizedString(forIdentifier: code) ?? code
    return name.prefix(1).capitalized + name.dropFirst()
}

final class LauncherSettings: ObservableObject {
    @Published var fps: Int
    @Published var renderScale: Double
    @Published var docked: Bool
    @Published var showFPS: Bool
    @Published var metalHUD: Bool
    @Published var language: String
    let languages: [String]

    fileprivate init(_ p: Profile) {
        languages = ((info("DMLanguages") as? String) ?? "").split(separator: " ").map(String.init)
        let packed = (info("DMLanguage") as? String) ?? "en-US"
        fps = defaults.object(forKey: "fps") as? Int ?? p.fpsTarget
        renderScale = defaults.object(forKey: "renderScale") as? Double ?? 1.0
        docked = defaults.object(forKey: "docked") as? Bool ?? p.docked
        showFPS = defaults.object(forKey: "showFPS") as? Bool ?? ((info("DMShowFPS") as? Bool) ?? false)
        metalHUD = defaults.bool(forKey: "metalHUD")
        let saved = defaults.string(forKey: "language") ?? packed
        language = languages.isEmpty || languages.contains(saved) ? saved : packed
    }

    fileprivate func apply(_ p: Profile) {
        defaults.set(fps, forKey: "fps")
        defaults.set(renderScale, forKey: "renderScale")
        defaults.set(docked, forKey: "docked")
        defaults.set(showFPS, forKey: "showFPS")
        defaults.set(metalHUD, forKey: "metalHUD")
        defaults.set(language, forKey: "language")
        var env = ["DM_OPMODE": docked ? "1" : "0", "DM_SHOW_FPS": showFPS ? "1" : "0", "DM_METAL_HUD": metalHUD ? "1" : "0", "DM_LANG": language]
        if p.fpsTarget != 0 { env["DM_FPS_TARGET"] = String(fps) }
        if p.renderScale && renderScale < 1 { env["DM_RENDER_SCALE"] = String(format: "%.2f", renderScale) }
        for (k, v) in env {
            if getenv(k) == nil {
                setenv(k, v, 0)
                fputs("launcher: \(k)=\(v)\n", stderr)
            } else {
                fputs("launcher: \(k) kept at \(String(cString: getenv(k))) (env.txt)\n", stderr)
            }
        }
    }
}

private struct LauncherView: View {
    @StateObject var s: LauncherSettings
    let profile: Profile
    let play: () -> Void
    @State private var memory = os_proc_available_memory()

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 16) {
                if let icon = UIImage(named: "AppIcon") ?? appIcon() {
                    Image(uiImage: icon).resizable().frame(width: 96, height: 96).clipShape(RoundedRectangle(cornerRadius: 22))
                }
                Text((info("CFBundleDisplayName") as? String) ?? "Game").font(.title.weight(.bold)).multilineTextAlignment(.center)
                Text("Version \((info("CFBundleShortVersionString") as? String) ?? "")").font(.callout).foregroundStyle(.secondary)
                playButton
            }
            .padding(24)
            .frame(maxWidth: .infinity)
            Form {
                if profile.fpsTarget != 0 {
                    Section {
                        Picker("Frame rate", selection: $s.fps) {
                            Text("30 fps").tag(30)
                            Text("60 fps").tag(60)
                        }
                    } footer: {
                        Text("30 fps saves battery and keeps the device cooler")
                    }
                }
                if profile.renderScale {
                    Section {
                        HStack {
                            Text("Render scale")
                            Slider(value: $s.renderScale, in: 0.5...1.0, step: 0.05)
                            Text(s.renderScale >= 1 ? "Native" : "\(Int((s.renderScale * 100).rounded())) %").monospacedDigit().foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
                        }
                    } footer: {
                        Text("Below native, the 3D views render at that fraction of the game's size and its dynamic resolution is off; the HUD stays sharp")
                    }
                }
                Section {
                    Picker("Console mode", selection: $s.docked) {
                        Text("Docked").tag(true)
                        Text("Handheld").tag(false)
                    }
                } footer: {
                    Text("Handheld renders at a lower resolution, lighter on the GPU and battery")
                }
                if s.languages.count > 1 {
                    Section {
                        Picker("Game language", selection: $s.language) {
                            ForEach(s.languages, id: \.self) { Text(languageName($0)).tag($0) }
                        }
                    }
                }
                Section {
                    Toggle("Frame-rate counter", isOn: $s.showFPS)
                    Toggle("Performance HUD", isOn: $s.metalHUD)
                    HStack {
                        Text("Memory available")
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: Int64(memory), countStyle: .memory)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .preferredColorScheme(.dark)
        .task {
            while !Task.isCancelled {
                memory = os_proc_available_memory()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    @ViewBuilder var playButton: some View {
        let button = Button(action: play) {
            Text("Play").font(.title3.weight(.semibold)).frame(maxWidth: 220)
        }
        .controlSize(.large)
        if #available(iOS 26.0, *) {
            button.buttonStyle(.glassProminent)
        } else {
            button.buttonStyle(.borderedProminent)
        }
    }

    private func appIcon() -> UIImage? {
        guard let icons = info("CFBundleIcons") as? [String: Any], let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primary["CFBundleIconFiles"] as? [String], let last = files.last else { return nil }
        return UIImage(named: last)
    }
}

@_cdecl("dm_launcher_enabled")
public func dmLauncherEnabled() -> Bool {
    guard let e = getenv("DM_LAUNCHER") else { return true }
    return String(cString: e) != "0"
}

@_cdecl("dm_show_launcher")
public func dmShowLauncher(_ viewController: UnsafeMutableRawPointer, _ fpsTarget: Int32, _ renderScale: Bool, _ docked: Bool, _ done: @convention(c) () -> Void) {
    let parent = Unmanaged<UIViewController>.fromOpaque(viewController).takeUnretainedValue()
    let profile = Profile(fpsTarget: Int(fpsTarget), renderScale: renderScale, docked: docked)
    let settings = LauncherSettings(profile)
    var host: UIViewController?
    let view = LauncherView(s: settings, profile: profile) {
        guard let h = host else { return }
        host = nil
        settings.apply(profile)
        h.dismiss(animated: false) { done() }
    }
    let h = UIHostingController(rootView: view)
    h.modalPresentationStyle = .fullScreen
    host = h
    parent.present(h, animated: false)
}
