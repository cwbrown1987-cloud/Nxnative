import SwiftUI
import UniformTypeIdentifiers
import PortCore

enum StudioStyle {
    static let ground = Color(white: 0.045)
    static let surface = Color(white: 0.085)
    static let raised = Color(white: 0.14)
    static let muted = Color(white: 0.70)
    static let signal = Color(red: 0.94, green: 0.69, blue: 0.39)
}

struct StudioView: View {
    @Bindable var model: StudioModel
    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 202)
            Rectangle().fill(.white.opacity(0.06)).frame(width: 1)
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if let failure = model.failure { errorNotice(failure) }
                        switch model.page {
                        case .create: createPage
                        case .devices: DevicesView(model: model)
                        case .environment: EnvironmentView(model: model)
                        case .log: ActivityView(model: model)
                        }
                    }.padding(28)
                }
                if model.isBusy || model.completedURL != nil { progressFooter }
            }
        }
        .background(StudioStyle.ground)
        .foregroundStyle(.white)
        .font(.system(size: 14))
        .onChange(of: model.destination) { Task { await model.checkEnvironment() } }
        .sheet(isPresented: $model.showingKeysSheet, onDismiss: { model.pastedKeys = "" }) { keysSheet }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                PortMark().frame(width: 30, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("NX Port").font(.system(size: 18, weight: .semibold))
                    Text("Studio").foregroundStyle(StudioStyle.muted).font(.system(size: 12))
                }
            }.padding(.bottom, 38).padding(.top, 38)
            Text(t("Workspace")).font(.system(size: 12)).foregroundStyle(StudioStyle.muted).padding(.bottom, 12)
            ForEach(StudioPage.allCases) { page in
                Button { model.page = page } label: {
                    HStack(spacing: 11) {
                        Image(systemName: page.icon).font(.system(size: 16)).frame(width: 20)
                        Text(t(page.rawValue))
                        Spacer()
                        if page == .log && model.isBusy { ProgressView().controlSize(.mini) }
                    }
                    .foregroundStyle(model.page == page ? .white : StudioStyle.muted)
                    .fontWeight(model.page == page ? .semibold : .regular)
                    .frame(height: 40).contentShape(Rectangle())
                }.buttonStyle(.plain).help(t(page.rawValue))
            }
            Spacer(minLength: 40)
            VStack(alignment: .leading, spacing: 10) {
                Text("nxnative").font(.system(size: 14, weight: .medium))
                Text(t("Your games. Apple hardware.")).font(.system(size: 12)).foregroundStyle(StudioStyle.muted)
                Button { model.openURL("https://github.com/seedds/nxnative") } label: {
                    Label(t("Source on GitHub"), systemImage: "arrow.up.right").font(.system(size: 12))
                }.buttonStyle(.plain).foregroundStyle(StudioStyle.muted)
            }.padding(.bottom, 24)
        }.padding(.horizontal, 22)
    }

    private var header: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(t(model.page.rawValue)).font(.system(size: 22, weight: .semibold))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(StudioStyle.muted)
            }
            Spacer()
            if model.isPreparing { ProgressView().controlSize(.small) }
            Label(t(model.status), systemImage: model.isBusy ? "circle.dotted" : "circle.fill")
                .font(.system(size: 12)).foregroundStyle(StudioStyle.muted)
                .labelStyle(.titleAndIcon)
        }.padding(.horizontal, 28).padding(.top, 28).padding(.bottom, 22)
    }
    private var subtitle: String {
        switch model.page {
        case .create: t("From your game files to an Apple app.")
        case .devices: t("Sign and install on your paired iPhone or iPad.")
        case .environment: t("Everything the native build pipeline needs.")
        case .log: t("Live output from nxnative and Xcode.")
        }
    }

    private var createPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !model.missingRequirements.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "wrench.and.screwdriver").foregroundStyle(StudioStyle.signal)
                    Text(t("Some build tools need preparation.")).font(.system(size: 13))
                    Spacer()
                    Button(t("Review environment")) { model.page = .environment }.buttonStyle(QuietButtonStyle())
                }.padding(14).background(StudioStyle.surface, in: RoundedRectangle(cornerRadius: 12))
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 18) { inputs; summary.frame(width: 240) }
                VStack(alignment: .leading, spacing: 18) { inputs; summary }
            }
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(t(model.destination == .macOS ? "A Mac app, ready in Downloads." : model.installMode ? "An Xcode project, ready for your device." : "An IPA for your sideloading tool."))
                        .fontWeight(.medium)
                    Text(t(model.destination == .macOS ? "Self-contained .app with audio and controller support." : "iOS / iPadOS 26 · A17 Pro or M-series hardware.")).font(.system(size: 12)).foregroundStyle(StudioStyle.muted)
                }
                Spacer()
                Button { model.build() } label: {
                    Label(t(model.destination == .iOS && model.installMode ? "Prepare port" : "Create port"), systemImage: "arrow.right")
                        .fontWeight(.semibold).padding(.horizontal, 18).frame(height: 38)
                }.buttonStyle(PrimaryButtonStyle()).disabled(!model.canBuild).keyboardShortcut(.return, modifiers: .command)
                    .help(t("Choose game files and prod.keys first. Command-Return starts the build."))
            }.padding(.top, 3)
        }
    }

    private var inputs: some View {
        VStack(alignment: .leading, spacing: 18) {
            StudioPanel {
                VStack(alignment: .leading, spacing: 16) {
                    sectionTitle("Game files", icon: "folder")
                    Button { model.chooseGame() } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(t(model.gamePath.isEmpty ? "Choose a game folder" : "Change game folder")).fontWeight(.medium)
                                Spacer(); Image(systemName: "folder.badge.plus")
                            }
                            Text(model.gamePath.isEmpty ? t("NSP, XCI, NSZ or XCZ · Base game, updates and DLC together") : model.gamePath)
                                .font(.system(size: 12)).foregroundStyle(StudioStyle.muted).lineLimit(2).truncationMode(.middle)
                        }.padding(16).frame(maxWidth: .infinity, minHeight: 85, alignment: .leading)
                            .background(StudioStyle.raised, in: RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(.plain).disabled(model.isBusy)
                        .dropDestination(for: URL.self) { urls, _ in
                            guard !model.isBusy, let first = urls.first else { return false }
                            model.setGame(first); return true
                        }
                    if !model.gameFiles.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(model.gameFiles.prefix(3), id: \.path) { file in
                                HStack(spacing: 8) {
                                    Image(systemName: "doc.zipper").foregroundStyle(StudioStyle.muted)
                                    Text(file.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                }.font(.system(size: 12))
                            }
                            if model.gameFiles.count > 3 { Text("+ \(model.gameFiles.count - 3) " + t("more files")).font(.system(size: 12)).foregroundStyle(StudioStyle.muted) }
                        }
                    }
                    Divider().overlay(.white.opacity(0.02))
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("prod.keys").fontWeight(.medium)
                            Text(t(model.keysPath.isEmpty ? "Import the keys from your console." : "Keys selected · kept on this Mac")).font(.system(size: 12)).foregroundStyle(StudioStyle.muted)
                        }
                        Spacer()
                        Button(t("Paste")) { model.showingKeysSheet = true }.buttonStyle(QuietButtonStyle())
                        Button(t(model.keysPath.isEmpty ? "Import" : "Change")) { model.chooseKeys() }.buttonStyle(QuietButtonStyle())
                    }.disabled(model.isBusy)
                }
            }
            StudioPanel {
                VStack(alignment: .leading, spacing: 16) {
                    sectionTitle("Destination", icon: "arrow.up.forward.app")
                    HStack(spacing: 10) {
                        destinationButton(.macOS, title: "Mac", icon: "desktopcomputer", detail: ".app")
                        destinationButton(.iOS, title: "iPhone / iPad", icon: "ipad.and.iphone", detail: ".ipa / Xcode")
                    }.disabled(model.isBusy)
                    if model.destination == .iOS {
                        Toggle(t("Prepare for direct installation"), isOn: $model.installMode).toggleStyle(.switch).disabled(model.isBusy)
                        Text(t("Use Xcode signing for USB or paired Wi-Fi devices. Leave off to export an unsigned IPA.")).font(.system(size: 12)).foregroundStyle(StudioStyle.muted)
                    }
                    VStack(alignment: .leading, spacing: 7) {
                        Text(t("Port name")).font(.system(size: 12)).foregroundStyle(StudioStyle.muted)
                        TextField(t("Use the game folder name"), text: $model.appName).textFieldStyle(.plain).padding(10).background(StudioStyle.raised, in: RoundedRectangle(cornerRadius: 7)).disabled(model.isBusy)
                    }
                    HStack {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(t("Game language")).font(.system(size: 12)).foregroundStyle(StudioStyle.muted)
                            Picker(t("Game language"), selection: $model.language) {
                                Text("Español").tag("es"); Text("Español latinoamericano").tag("es-419")
                                Text("English").tag("en-US"); Text("日本語").tag("ja")
                                Text("Français").tag("fr"); Text("Deutsch").tag("de")
                                Text("Italiano").tag("it"); Text("Português").tag("pt")
                            }.labelsHidden().frame(maxWidth: 220).disabled(model.isBusy)
                        }
                        Spacer()
                        Toggle(t("Show FPS"), isOn: $model.showFPS).toggleStyle(.checkbox).disabled(model.isBusy)
                    }
                }
            }
        }.frame(minWidth: 370, maxWidth: .infinity)
    }

    private var summary: some View {
        StudioPanel {
            VStack(alignment: .leading, spacing: 20) {
                Text(t("Your port")).font(.system(size: 16, weight: .semibold))
                PortRoute(destination: model.destination)
                VStack(alignment: .leading, spacing: 7) {
                    Text(model.gamePath.isEmpty ? t("No game selected") : model.appName.isEmpty ? URL(fileURLWithPath: model.gamePath).lastPathComponent : model.appName).font(.system(size: 17, weight: .medium)).lineLimit(3)
                    Text(model.destination == .macOS ? "macOS · Apple silicon" : "iOS / iPadOS · ARM64").font(.system(size: 12)).foregroundStyle(StudioStyle.muted)
                }
                VStack(spacing: 12) {
                    summaryRow("Files", value: "\(model.gameFiles.count)")
                    summaryRow("Source size", value: ByteCountFormatter.string(fromByteCount: model.inputBytes, countStyle: .file))
                    summaryRow("Free space estimate", value: model.gameFiles.isEmpty ? "—" : model.approximateSpace)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(t(model.destination == .iOS && model.installMode ? "Project location" : "Save to")).font(.system(size: 12)).foregroundStyle(StudioStyle.muted)
                    Text(model.destination == .iOS && model.installMode ? (model.gamePath.isEmpty ? t("Beside your game files") : model.gamePath) : model.outputFolder).font(.system(size: 12)).lineLimit(3).truncationMode(.middle).textSelection(.enabled)
                    if model.destination != .iOS || !model.installMode {
                        Button(t("Change folder")) { model.chooseOutput() }.buttonStyle(.plain).font(.system(size: 12, weight: .medium)).disabled(model.isBusy)
                    }
                }
                Text(t("Compatibility depends on the game and its version. The first build can take 30–60 minutes.")).font(.system(size: 12)).foregroundStyle(StudioStyle.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var progressFooter: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.isBusy ? (model.stageName.isEmpty ? t(model.status) : model.stageName) : t(model.status)).fontWeight(.medium)
                    Text(model.isBusy ? model.stepName : model.completedURL?.lastPathComponent ?? "").font(.system(size: 12)).foregroundStyle(StudioStyle.muted).lineLimit(1)
                }
                Spacer()
                if model.stageTotal > 0 { Text("\(model.stageIndex) / \(model.stageTotal)").monospacedDigit().foregroundStyle(StudioStyle.muted) }
                if model.isBusy { Button(t("Cancel")) { model.cancel() }.buttonStyle(QuietButtonStyle()) }
                else {
                    if model.projectURL != nil { Button(t("Install on device")) { model.page = .devices; Task { await model.refreshDevices() } }.buttonStyle(PrimaryButtonStyle()) }
                    Button(t("Show in Finder")) { model.revealOutput() }.buttonStyle(QuietButtonStyle())
                }
            }
            if let progress = model.progress { ProgressView(value: progress).tint(StudioStyle.signal) }
            else if model.isBusy { ProgressView().progressViewStyle(.linear).tint(StudioStyle.signal) }
        }.padding(20).background(StudioStyle.surface)
    }
    private func destinationButton(_ destination: BuildDestination, title: String, icon: String, detail: String) -> some View {
        Button { model.destination = destination; model.completedURL = nil } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 22))
                VStack(alignment: .leading, spacing: 3) { Text(title).fontWeight(.medium); Text(detail).font(.system(size: 11)).foregroundStyle(StudioStyle.muted) }
                Spacer(minLength: 0)
                Image(systemName: model.destination == destination ? "checkmark.circle.fill" : "circle").font(.system(size: 15))
            }.padding(12).background(model.destination == destination ? Color(white: 0.19) : StudioStyle.raised, in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain).accessibilityLabel(title).accessibilityAddTraits(model.destination == destination ? .isSelected : [])
    }
    private func summaryRow(_ key: String, value: String) -> some View { HStack { Text(t(key)).foregroundStyle(StudioStyle.muted); Spacer(); Text(value).monospacedDigit() }.font(.system(size: 12)) }
    private func sectionTitle(_ title: String, icon: String) -> some View { Label(t(title), systemImage: icon).font(.system(size: 16, weight: .medium)) }
    private func errorNotice(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(StudioStyle.signal)
            Text(message).font(.system(size: 13)).textSelection(.enabled)
            Spacer()
            Button { model.failure = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel(t("Dismiss error"))
        }.padding(14).background(StudioStyle.raised, in: RoundedRectangle(cornerRadius: 10))
    }
    private var keysSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(t("Paste prod.keys")).font(.system(size: 22, weight: .semibold))
            Text(t("Stored privately on this Mac. Key contents are never included in logs or sent to GitHub.")).foregroundStyle(StudioStyle.muted)
            TextEditor(text: $model.pastedKeys).font(.system(size: 12, design: .monospaced)).privacySensitive().frame(height: 220).scrollContentBackground(.hidden).padding(10).background(StudioStyle.raised, in: RoundedRectangle(cornerRadius: 8))
            HStack { Spacer(); Button(t("Cancel")) { model.pastedKeys = ""; model.showingKeysSheet = false }; Button(t("Save keys")) { model.savePastedKeys() }.disabled(model.pastedKeys.isEmpty) }
        }.padding(28).frame(width: 520).background(StudioStyle.surface)
    }
}

struct StudioPanel<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { content.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(StudioStyle.surface, in: RoundedRectangle(cornerRadius: 16)) }
}
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.padding(.horizontal, 14).frame(minHeight: 36).foregroundStyle(isEnabled ? .black : .white.opacity(0.6))
            .background(isEnabled ? Color(white: configuration.isPressed ? 0.75 : 0.95) : Color(white: 0.22), in: Capsule())
    }
}
struct QuietButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.padding(.horizontal, 12).frame(minHeight: 32).foregroundStyle(isEnabled ? .white : StudioStyle.muted)
            .background(Color(white: configuration.isPressed ? 0.23 : 0.17), in: Capsule())
    }
}
struct PortMark: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5).stroke(.white, lineWidth: 2).frame(width: 21, height: 27).offset(x: -3)
            Image(systemName: "arrow.right").font(.system(size: 20, weight: .bold)).padding(3).background(StudioStyle.ground).offset(x: 7, y: 2)
        }.accessibilityHidden(true)
    }
}
struct PortRoute: View {
    let destination: BuildDestination
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "sdcard").font(.system(size: 30, weight: .light))
            Rectangle().fill(StudioStyle.signal).frame(height: 1)
            Image(systemName: "arrow.right").foregroundStyle(StudioStyle.signal)
            Image(systemName: destination == .macOS ? "desktopcomputer" : "ipad.and.iphone").font(.system(size: 30, weight: .light))
        }.frame(height: 60).foregroundStyle(.white.opacity(0.8)).accessibilityLabel(t("Game files to Apple app"))
    }
}
