// The window frame and the pieces every page uses: sidebar, toolbar, cards, status dots, path fields.
import AppKit
import SwiftUI

let helpURL = URL(string: "https://github.com/gnosticgeek/nxnative/blob/main/app/README.md")!

struct RootView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(Page.allCases, selection: Binding(get: { model.page }, set: { if let p = $0 { model.page = p } })) { p in
                Label(p.rawValue, systemImage: p.symbol).font(.title3).padding(.vertical, 3).tag(p)
            }
            .navigationSplitViewColumnWidth(min: 250, ideal: 265, max: 300)
            .safeAreaInset(edge: .bottom) { ToolchainFooter(model: model) }
        } detail: {
            Group {
                switch model.page {
                case .convert: ScrollView { ConvertPage(model: model).padding(24) }
                case .builds: BuildsPage(model: model)
                case .toolchain: ScrollView { ToolchainPage(model: model).padding(24) }
                case .settings: SettingsPage(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .navigationTitle("NxNative Converter")
            .toolbar {
                if model.page == .builds {
                    ToolbarItem {
                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                            TextField("Search builds", text: $model.buildSearch).textFieldStyle(.plain).frame(width: 200)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5)
                    }
                }
                ToolbarItem {
                    Button { NSWorkspace.shared.open(helpURL) } label: { Image(systemName: "questionmark") }.help("NxNative Converter help")
                }
            }
        }
    }
}

/// The page title and its one-line subtitle, with optional trailing controls.
struct PageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 30, weight: .bold))
                Text(subtitle).font(.title3).foregroundStyle(.secondary)
            }
            Spacer()
            trailing
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String) { self.init(title: title, subtitle: subtitle) { EmptyView() } }
}

/// A green, red, grey or blue dot with its word: the status column of every table.
struct StatusDot: View {
    let color: Color
    var text: String? = nil

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 10, height: 10)
            if let text { Text(text).foregroundStyle(color == .gray ? Color.secondary : color) }
        }
    }
}

/// A filled check, cross or dash: the larger summary marks.
struct StatusIcon: View {
    /// true = tick, false = cross, nil = not run / optional
    let ok: Bool?
    var size: CGFloat = 18

    var body: some View {
        Image(systemName: ok == true ? "checkmark.circle.fill" : ok == false ? "xmark.circle.fill" : "minus.circle.fill")
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, ok == true ? Color.green : ok == false ? Color.red : Color.gray)
            .font(.system(size: size))
    }
}

struct Card<Content: View>: View {
    var title = ""
    var subtitle = ""
    var padding: CGFloat = 18
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !title.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.title2.weight(.semibold))
                    if !subtitle.isEmpty { Text(subtitle).foregroundStyle(.secondary) }
                }
            }
            content
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.background.secondary.opacity(0.7), in: .rect(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.separator.opacity(0.7)))
    }
}

/// A bordered inner table: rows separated by hairlines.
struct InsetTable<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(.background.opacity(0.35), in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator.opacity(0.8)))
            .clipShape(.rect(cornerRadius: 10))
    }
}

/// A path shown like a text field, with its icon and a Change button.
struct PathField: View {
    let label: String
    var labelWidth: CGFloat = 110
    let symbol: String
    let value: String?
    var button = "Change…"
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(label).frame(width: labelWidth, alignment: .leading)
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundStyle(.blue)
                Text(value ?? "Not chosen").foregroundStyle(value == nil ? .secondary : .primary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).frame(height: 30)
            .background(.background.opacity(0.5), in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
            .help(value ?? "")
            Button(button, action: action).buttonStyle(.glass)
        }
    }
}

struct ToolchainFooter: View {
    let model: AppModel

    var body: some View {
        Button { model.page = .toolchain } label: {
            HStack(spacing: 10) {
                if model.checking { ProgressView().controlSize(.small).frame(width: 22) } else { StatusIcon(ok: model.allOK, size: 22) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.checking ? "Checking toolchain…" : model.allOK ? "Toolchain ready" : "Toolchain incomplete").font(.headline).lineLimit(1)
                    Text("\(model.passed) of \(model.checks?.count ?? 0) checks passed").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
            .padding(12)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .padding(12)
    }
}

/// An app's own icon, as Finder shows it.
struct AppIcon: View {
    let path: String
    var size: CGFloat = 96

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().interpolation(.high)
            .frame(width: size, height: size)
    }
}

/// The game's icon from its extracted control data, or a placeholder.
struct GameIcon: View {
    let url: URL?
    var size: CGFloat = 120

    var body: some View {
        Group {
            if let url, let img = NSImage(contentsOf: url) {
                Image(nsImage: img).resizable().interpolation(.high)
            } else {
                ZStack { Color.gray.opacity(0.25); Image(systemName: "gamecontroller").font(.system(size: size * 0.35)).foregroundStyle(.secondary) }
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: size * 0.2))
        .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
    }
}

func reveal(_ path: String) { NSWorkspace.shared.activateFileViewerSelecting([path.url]) }

func copyToClipboard(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}
