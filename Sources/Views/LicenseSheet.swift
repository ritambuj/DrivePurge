//
//  LicenseSheet.swift — the licence panel.
//
//  Drawn entirely from Theme tokens, so it inherits whichever palette is
//  active (Apple's dark chrome or Modernist paper) with no branching.
//

import SwiftUI
import AppKit

struct LicenseSheet: View {
    @ObservedObject var store: LicenseStore
    @Environment(\.dismiss) private var dismiss
    @State private var keyInput = ""
    @FocusState private var keyFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Theme.borderSoft).frame(height: Theme.ruleWidth)

            VStack(alignment: .leading, spacing: 18) {
                if store.isLicensed {
                    licensedBody
                } else {
                    activationBody
                }

                if let message = store.message {
                    Text(message)
                        .font(Theme.font(12.5))
                        .foregroundColor(Theme.dangerSoft)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 11).padding(.vertical, 9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: Theme.radius(6))
                            .fill(Theme.danger.opacity(0.10)))
                        .overlay(RoundedRectangle(cornerRadius: Theme.radius(6))
                            .strokeBorder(Theme.danger.opacity(0.35), lineWidth: Theme.ruleWidth))
                }
            }
            .padding(20)

            Spacer(minLength: 0)
            Rectangle().fill(Theme.borderSoft).frame(height: Theme.ruleWidth)
            footer
        }
        .frame(width: 460)
        .frame(minHeight: 380)
        .background(Theme.windowBG)
        .onAppear { keyFocused = !store.isLicensed }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            brandMark
            Text(store.isLicensed ? "Your licence" : "Unlock cleaning")
                .font(Theme.font(15, .semibold))
                .foregroundColor(Theme.textPrimary)
            Spacer()
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
    }

    /// Brand mark from Bundle.module Resources; SF Symbol fallback if missing.
    @ViewBuilder
    private var brandMark: some View {
        if let image = Self.loadBrandMarkImage() {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
        } else {
            Image(systemName: store.canClean ? "checkmark.seal.fill" : "lock")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(store.canClean ? Theme.accent : Theme.textMuted)
                .frame(width: 22, height: 22)
        }
    }

    private static func loadBrandMarkImage() -> NSImage? {
        let candidates: [(name: String, ext: String)] = [
            ("Mark", "svg"),
            ("AppIcon", "png"),
        ]
        for c in candidates {
            let urls = [
                Bundle.module.url(forResource: c.name, withExtension: c.ext, subdirectory: "Resources"),
                Bundle.module.url(forResource: c.name, withExtension: c.ext),
            ]
            for url in urls.compactMap({ $0 }) {
                if let image = NSImage(contentsOf: url) { return image }
            }
        }
        return nil
    }

    // MARK: - Not yet licensed

    private var activationBody: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Scanning is free and always will be. A one-time licence unlocks cleaning on up to three Macs you own.")
                .font(Theme.font(13))
                .foregroundColor(Theme.textBody)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("LICENCE KEY")
                    .font(Theme.font(10.5, .semibold))
                    .kerning(1.3)
                    .foregroundColor(Theme.textLabel)

                ZStack {
                    RoundedRectangle(cornerRadius: Theme.radius(8)).fill(Theme.inputBG)
                    RoundedRectangle(cornerRadius: Theme.radius(8)).strokeBorder(
                        keyFocused ? Theme.accent.opacity(0.7) : Theme.borderInput,
                        lineWidth: Theme.ruleWidth)
                    TextField("DP1-XXXX-XXXX-XXXX-XXXX", text: $keyInput)
                        .textFieldStyle(.plain)
                        .font(Theme.mono(13))
                        .foregroundColor(Theme.textPrimary)
                        .focused($keyFocused)
                        .onSubmit(activate)
                        .padding(.horizontal, 11)
                        .disabled(store.isWorking)
                }
                .frame(height: 36)

                Text("It was emailed to you when you bought DrivePurge.")
                    .font(Theme.font(11.5))
                    .foregroundColor(Theme.textFaint)
            }

            HStack(spacing: 8) {
                Button(action: activate) {
                    HStack(spacing: 7) {
                        if store.isWorking { ProgressView().controlSize(.small).scaleEffect(0.6) }
                        Text(store.isWorking ? "Activating…" : "Activate")
                            .font(Theme.font(13, .semibold))
                    }
                    .foregroundColor(Theme.onAccent)
                    .frame(height: 34)
                    .padding(.horizontal, 16)
                    .background(RoundedRectangle(cornerRadius: Theme.radius(8))
                        .fill(Theme.accent))
                }
                .buttonStyle(FlatButtonStyle())
                .disabled(store.isWorking || keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                .opacity(keyInput.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)

                Button { NSWorkspace.shared.open(LicenseStore.purchaseURL) } label: {
                    Text("Buy a licence — $9.90")
                        .font(Theme.font(13))
                        .foregroundColor(Theme.textControl)
                        .frame(height: 34)
                        .padding(.horizontal, 14)
                        .background(RoundedRectangle(cornerRadius: Theme.radius(8)).fill(Theme.chipBG))
                        .overlay(RoundedRectangle(cornerRadius: Theme.radius(8))
                            .strokeBorder(Theme.borderChip, lineWidth: Theme.ruleWidth))
                }
                .buttonStyle(FlatButtonStyle())
            }
        }
    }

    // MARK: - Licensed

    private var licensedBody: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(store.statusSummary)
                    .font(Theme.font(13, .medium))
                    .foregroundColor(store.canClean ? Theme.textBody : Theme.dangerSoft)
                    .fixedSize(horizontal: false, vertical: true)
                if let token = store.state.token {
                    Text("Rechecks after \(token.expiresAt.formatted(date: .abbreviated, time: .omitted))")
                        .font(Theme.font(11.5))
                        .foregroundColor(Theme.textFaint)
                }
            }

            if !store.seats.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text("MACS USING THIS LICENCE")
                        .font(Theme.font(10.5, .semibold))
                        .kerning(1.3)
                        .foregroundColor(Theme.textLabel)

                    VStack(spacing: 0) {
                        ForEach(store.seats) { seat in
                            HStack(spacing: 9) {
                                Image(systemName: seat.isThisMac ? "laptopcomputer" : "desktopcomputer")
                                    .font(.system(size: 11))
                                    .foregroundColor(seat.isThisMac ? Theme.accent : Theme.textMuted)
                                Text(seat.deviceName ?? "Unnamed Mac")
                                    .font(Theme.font(12.5))
                                    .foregroundColor(Theme.textBody)
                                    .lineLimit(1)
                                if seat.isThisMac {
                                    Text("this Mac")
                                        .font(Theme.font(10, .semibold))
                                        .foregroundColor(Theme.accent)
                                }
                                Spacer()
                                Text(seat.lastSeenDate.formatted(date: .abbreviated, time: .omitted))
                                    .font(Theme.mono(11))
                                    .foregroundColor(Theme.textFaint)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .overlay(alignment: .bottom) {
                                if seat.id != store.seats.last?.id {
                                    Rectangle().fill(Theme.borderRow).frame(height: Theme.ruleWidth)
                                }
                            }
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: Theme.radius(8)).fill(Theme.chipBG))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius(8))
                        .strokeBorder(Theme.borderChip, lineWidth: Theme.ruleWidth))
                }
            }

            Text("Replacing this Mac? Release it here and the slot is free immediately.")
                .font(Theme.font(11.5))
                .foregroundColor(Theme.textFaint)
                .fixedSize(horizontal: false, vertical: true)

            Button { Task { await store.deactivateThisMac() } } label: {
                Text(store.isWorking ? "Releasing…" : "Release this Mac")
                    .font(Theme.font(12.5, .semibold))
                    .foregroundColor(Theme.dangerSoft)
                    .frame(height: 32)
                    .padding(.horizontal, 14)
                    .background(RoundedRectangle(cornerRadius: Theme.radius(7))
                        .fill(Theme.danger.opacity(0.12)))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius(7))
                        .strokeBorder(Theme.danger.opacity(0.35), lineWidth: Theme.ruleWidth))
            }
            .buttonStyle(FlatButtonStyle())
            .disabled(store.isWorking)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 14) {
            Button { NSWorkspace.shared.open(URL(string: "https://drivepurge.com/legal/terms/")!) } label: {
                Text("Licence terms").font(Theme.font(11.5)).foregroundColor(Theme.textFaint)
            }
            .buttonStyle(FlatButtonStyle())

            Button { NSWorkspace.shared.open(URL(string: "https://drivepurge.com/legal/refunds/")!) } label: {
                Text("Refunds").font(Theme.font(11.5)).foregroundColor(Theme.textFaint)
            }
            .buttonStyle(FlatButtonStyle())

            Spacer()

            Button { dismiss() } label: {
                Text("Done")
                    .font(Theme.font(12.5, .medium))
                    .foregroundColor(Theme.textControl)
                    .frame(height: 28)
                    .padding(.horizontal, 16)
                    .background(RoundedRectangle(cornerRadius: Theme.radius(7)).fill(Theme.chipBG))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius(7))
                        .strokeBorder(Theme.borderChip, lineWidth: Theme.ruleWidth))
            }
            .buttonStyle(FlatButtonStyle())
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
        .background(Theme.statusBarBG)
    }

    private func activate() {
        let key = keyInput
        Task { await store.activate(key: key) }
    }
}
