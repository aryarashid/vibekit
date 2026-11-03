import SwiftUI
import VibeKitCore

/// A dev server that stopped. Click to start it again with the same command in the same folder.
struct RecentRow: View {
    let recent: RecentServer
    let store: ServerStore
    let isSelected: Bool
    let onHover: () -> Void

    private var starting: Bool { store.pending[recent.id] == .starting }

    private var crashCode: Int32? {
        if case .crashed(let code) = recent.reason { return code }
        return nil
    }

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                StatusLight(state: crashCode == nil ? .stopped : .crashed, diameter: 7).sized()
                Text(verbatim: "\(recent.port)")
                    .font(Theme.portFont)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            .frame(width: Theme.portColumn, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(recent.title)
                    .font(Theme.titleFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(recent.frameworkName)
                        .foregroundStyle(Theme.tint(recent.frameworkColor))
                        .fontWeight(.medium)
                    Text("·").foregroundStyle(.tertiary)
                    Text(recent.launch.displayCommandShort)
                        .font(Theme.monoSmall)
                        .foregroundStyle(.tertiary)
                        .truncationMode(.middle)
                }
                .font(Theme.metaFont)
                .lineLimit(1)
            }
            Spacer(minLength: 4)

            if starting {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                    Text("Starting").font(Theme.metaFont).foregroundStyle(.secondary)
                }
            } else if isSelected {
                HStack(spacing: 2) {
                    PillButton(title: "Start", symbol: "play.fill") { store.start(recent) }
                    IconButton(symbol: "xmark", help: "Remove from list") { store.forget(recent) }
                }
            } else if let crashCode {
                Text("crashed · exit \(crashCode)")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.danger)
                    .help("Ended with exit code \(crashCode) \(Format.ago(recent.stoppedAt)). Its log has the details.")
            } else {
                Text((recent.reason == .exited ? "exited " : "") + Format.ago(recent.stoppedAt))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .help(recent.reason == .exited ? "It stopped outside Vibe Kit, for example with Ctrl-C." : "Stopped from Vibe Kit")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
        .contentShape(Rectangle())
        .onTapGesture { store.start(recent) }
        .background(RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous)
            .fill(Color.primary.opacity(isSelected ? 0.075 : 0)))
        .padding(.horizontal, 6)
        .onHover { if $0 { onHover() } }
        .contextMenu {
            Button("Start") { store.start(recent) }
            Button("Copy Command") { store.copy(recent.launch.displayCommand, label: "command") }
            Button("Reveal in Finder") {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: recent.launch.directory)
            }
            if let log = recent.log, FileManager.default.fileExists(atPath: log.path) {
                Button("Open Log") { NSWorkspace.shared.open(log) }
            }
            Divider()
            Button("Remove from List") { store.forget(recent) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(crashCode == nil ? "Stopped" : "Crashed"): \(recent.title), port \(recent.port)")
        .accessibilityAction(named: "Start") { store.start(recent) }
    }
}

extension LaunchSpec {
    /// The command shortened for a one-line label.
    var displayCommandShort: String {
        viaShell ? displayCommand : VibeKitCore.CommandLine.friendly(arguments)
    }
}
