import SwiftUI
import PortCore

struct DevicesView: View {
    @Bindable var model: StudioModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(t("Available devices")).font(.system(size: 16, weight: .medium))
                Spacer()
                if model.isDiscoveringDevices { ProgressView().controlSize(.small) }
                Button(t("Refresh")) { Task { await model.refreshDevices() } }.buttonStyle(QuietButtonStyle()).disabled(model.isDiscoveringDevices || model.isBusy)
                Button(t("Pair in Xcode")) { model.openDevicesWindow() }.buttonStyle(QuietButtonStyle())
            }
            StudioPanel {
                if model.devices.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(t("Connect your iPhone or iPad"), systemImage: "cable.connector").font(.system(size: 17, weight: .medium))
                        Text(t("Connect by USB, unlock the device and trust this Mac. Then pair it in Xcode → Window → Devices and Simulators.")).foregroundStyle(StudioStyle.muted)
                        Text(t("For Wi-Fi, enable Connect via network in Xcode after pairing and keep both devices on the same network. Proximity alone does not enable installation.")).foregroundStyle(StudioStyle.muted)
                    }.fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(spacing: 0) {
                        ForEach(model.devices) { device in
                            Button { model.selectedDeviceID = device.id } label: {
                                HStack(spacing: 16) {
                                    Image(systemName: device.model.lowercased().contains("ipad") ? "ipad" : "iphone").font(.system(size: 28, weight: .light)).frame(width: 32)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(device.name).fontWeight(.medium)
                                        Text("\(device.model) · iOS \(device.osVersion) · \(device.connectionLabel)").font(.system(size: 12)).foregroundStyle(StudioStyle.muted)
                                    }
                                    Spacer()
                                    Text(t(device.canInstall ? "Ready" : !device.isConnected ? "Disconnected" : !device.isPaired ? "Pairing required" : !device.supportsRequiredOS ? "iOS 26 required" : "Enable Developer Mode")).font(.system(size: 12)).foregroundStyle(device.canInstall ? .white : StudioStyle.muted)
                                    Image(systemName: device.id == model.selectedDeviceID ? "checkmark.circle.fill" : "circle")
                                }.padding(12).background(device.id == model.selectedDeviceID ? StudioStyle.raised : .clear, in: RoundedRectangle(cornerRadius: 9))
                            }.buttonStyle(.plain).disabled(model.isBusy)
                        }
                    }
                }
            }
            if !model.devices.isEmpty {
                Text(t("USB: unlock, trust this Mac and enable Developer Mode. Wi-Fi: pair first in Xcode, enable Connect via network and use the same network."))
                    .font(.system(size: 12)).foregroundStyle(StudioStyle.muted)
            }
            StudioPanel {
                VStack(alignment: .leading, spacing: 18) {
                    Text(t("Signing and installation")).font(.system(size: 16, weight: .medium))
                    Text(t("Xcode signs the port with the Apple account already configured on your Mac. You do not enter your Apple password here.")).foregroundStyle(StudioStyle.muted)
                    HStack(alignment: .top, spacing: 24) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(t("Apple Developer Team ID")).font(.system(size: 12)).foregroundStyle(StudioStyle.muted)
                            TextField("ABCDEFGHIJ", text: $model.teamID).textFieldStyle(.plain).font(.system(size: 14, design: .monospaced)).padding(10).background(StudioStyle.raised, in: RoundedRectangle(cornerRadius: 7)).frame(width: 200).disabled(model.isBusy)
                            Text(t("Xcode → Settings → Accounts → Team")).font(.system(size: 12)).foregroundStyle(StudioStyle.muted)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Text(t("Prepared project")).font(.system(size: 12)).foregroundStyle(StudioStyle.muted)
                            Text(model.projectURL?.path ?? t("Create a port with direct installation enabled, or choose an existing project.")).font(.system(size: 12)).foregroundStyle(StudioStyle.muted).lineLimit(3).truncationMode(.middle)
                            Button(t("Choose Xcode project")) { model.choosePreparedProject() }.buttonStyle(QuietButtonStyle()).disabled(model.isBusy)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    HStack {
                        Text(t("iOS / iPadOS 26 · iPhone 15 Pro or newer supported hardware · iPad M1 or later.")).font(.system(size: 12)).foregroundStyle(StudioStyle.muted)
                        Spacer()
                        Button { model.installPreparedProject() } label: { Label(t("Sign and install"), systemImage: "arrow.down.to.line").fontWeight(.semibold) }
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(model.isBusy || model.projectURL == nil || model.teamID.trimmingCharacters(in: .whitespacesAndNewlines).count != 10 || model.selectedDevice?.canInstall != true)
                    }
                }
            }
            Text(t("Provisioning, memory capabilities and Apple account limits depend on your team. Xcode reports any signing or entitlement issue in Activity.")).font(.system(size: 12)).foregroundStyle(StudioStyle.muted)
        }.task { await model.refreshDevices() }
    }
}

struct EnvironmentView: View {
    @Bindable var model: StudioModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(t("Build tools")).font(.system(size: 16, weight: .medium))
                    Text(t("Checks run locally. Python packages use a private environment.")).font(.system(size: 12)).foregroundStyle(StudioStyle.muted)
                }
                Spacer()
                if model.isChecking { ProgressView().controlSize(.small) }
                Button(t("Check again")) { Task { await model.checkEnvironment() } }.buttonStyle(QuietButtonStyle()).disabled(model.isChecking || model.isBusy)
                Button(t("Prepare environment")) { model.prepareEnvironment() }.buttonStyle(PrimaryButtonStyle()).disabled(model.isBusy || model.isPreparing)
            }
            StudioPanel {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.dependencies) { dependency in
                        HStack(alignment: .top, spacing: 14) {
                            Image(systemName: dependency.isAvailable ? "checkmark.circle" : "circle.dashed").foregroundStyle(dependency.isAvailable ? .white : StudioStyle.signal).font(.system(size: 16)).padding(.top, 2)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(dependency.name).fontWeight(.medium)
                                Text(dependency.isAvailable ? dependency.detail : dependency.remediation ?? dependency.detail).font(.system(size: 12)).foregroundStyle(StudioStyle.muted).textSelection(.enabled)
                            }
                            Spacer()
                            Text(t(dependency.isAvailable ? "Ready" : dependency.isRequired ? "Required" : "Optional")).font(.system(size: 12)).foregroundStyle(StudioStyle.muted)
                        }.padding(.vertical, 13)
                        if dependency.id != model.dependencies.last?.id { Divider().opacity(0.4) }
                    }
                    if model.dependencies.isEmpty { Text(t("Checking the local toolchain…")).foregroundStyle(StudioStyle.muted) }
                }
            }
            StudioPanel {
                VStack(alignment: .leading, spacing: 12) {
                    Text(t("Engine source")).font(.system(size: 16, weight: .medium))
                    Text(model.repositoryPath.isEmpty ? t("Preparing engine") : model.repositoryPath).font(.system(size: 12)).foregroundStyle(StudioStyle.muted).textSelection(.enabled)
                    HStack {
                        Button(t("Use another nxnative checkout")) { model.chooseRepository() }.buttonStyle(QuietButtonStyle()).disabled(model.isBusy)
                        Spacer()
                        Button(t("Install Xcode")) { model.openURL("https://apps.apple.com/app/xcode/id497799835") }.buttonStyle(.plain)
                        Button(t("Homebrew")) { model.openURL("https://brew.sh") }.buttonStyle(.plain)
                    }
                }
            }
            Text(t("Prepare environment installs missing command-line tools with Homebrew and Python packages from PyPI. Xcode, its license, Metal components and device pairing are managed by Apple tools.")).font(.system(size: 12)).foregroundStyle(StudioStyle.muted)
        }
    }
}

struct ActivityView: View {
    @Bindable var model: StudioModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(t("Build activity")).font(.system(size: 16, weight: .medium))
                Spacer()
                Text("\(model.logs.count) " + t("lines")).font(.system(size: 12)).foregroundStyle(StudioStyle.muted).monospacedDigit()
                Button(t("Export log")) { model.exportLog() }.buttonStyle(QuietButtonStyle()).disabled(model.logs.isEmpty)
            }
            StudioPanel {
                VStack(alignment: .leading, spacing: 12) {
                    if model.logs.isEmpty {
                        Text(t("The next build starts here.")).font(.system(size: 16, weight: .medium))
                        Text(t("Progress, tool output and actionable errors appear as nxnative works. Your key contents are never logged.")).foregroundStyle(StudioStyle.muted)
                    } else {
                        Text(model.logs.joined(separator: "\n")).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.frame(minHeight: 200, alignment: .topLeading)
            }
            HStack {
                Text(t("Detailed tool logs are also kept beside the game in its *_build/logs folder.")).font(.system(size: 12)).foregroundStyle(StudioStyle.muted)
                Spacer()
                if !model.gamePath.isEmpty { Button(t("Open game folder")) { NSWorkspace.shared.open(URL(fileURLWithPath: model.gamePath)) }.buttonStyle(.plain) }
            }
        }
    }
}
