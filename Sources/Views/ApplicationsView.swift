//
//  ApplicationsView.swift — the Applications tab.
//
//  Left: every installed app, biggest first. Right: what uninstalling the
//  selected one would actually remove, itemised, with the risky parts
//  unticked by default.
//
//  Drawn entirely from Theme tokens, so it inherits either palette.
//

import SwiftUI
import AppKit

struct ApplicationsView: View {
    @ObservedObject var inventory: AppInventory

    var body: some View {
        HStack(spacing: 0) {
            appList
            Rectangle().fill(Theme.borderSoft).frame(width: Theme.ruleWidth)
            detailPane.frame(width: 340)
        }
        .background(Theme.canvasBG)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius(8)))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius(8))
            .strokeBorder(Theme.borderCanvas, lineWidth: Theme.ruleWidth))
        .onAppear { if !inventory.hasScanned { inventory.scan() } }
    }

    // MARK: - List

    private var appList: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(Theme.borderSoft).frame(height: Theme.ruleWidth)

            if inventory.isScanning && inventory.apps.isEmpty {
                centred {
                    ProgressView().controlSize(.large)
                    Text("Reading your applications…")
                        .font(Theme.font(13, .medium)).foregroundColor(Theme.textBody)
                    Text("Measuring each bundle takes a few seconds.")
                        .font(Theme.font(11.5)).foregroundColor(Theme.textFaint)
                }
            } else if inventory.visibleApps.isEmpty {
                centred {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 28, weight: .light)).foregroundColor(Theme.textFaint)
                    Text(inventory.hasScanned ? "No applications match." : "Nothing scanned yet.")
                        .font(Theme.font(13)).foregroundColor(Theme.textFaint)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(inventory.visibleApps) { app in
                            AppRow(app: app,
                                   maxBytes: inventory.visibleApps.first?.size ?? 1,
                                   selected: inventory.selected?.id == app.id) {
                                inventory.select(app)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: Theme.radius(7)).fill(Theme.inputBG)
                RoundedRectangle(cornerRadius: Theme.radius(7))
                    .strokeBorder(Theme.borderInput, lineWidth: Theme.ruleWidth)
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10, weight: .semibold)).foregroundColor(Theme.textDim)
                    TextField("Filter applications", text: $inventory.searchText)
                        .textFieldStyle(.plain)
                        .font(Theme.font(12.5))
                        .foregroundColor(Theme.textPrimary)
                }
                .padding(.horizontal, 9)
            }
            .frame(width: 210, height: 28)

            ForEach(AppSortOrder.allCases) { order in
                chip(order.title, active: inventory.sortOrder == order) {
                    inventory.sortOrder = order
                }
            }

            chip(inventory.hideProtected ? "System apps hidden" : "System apps shown",
                 active: !inventory.hideProtected) {
                inventory.hideProtected.toggle()
            }

            Spacer(minLength: 8)

            Button { inventory.scan() } label: {
                HStack(spacing: 6) {
                    if inventory.isScanning {
                        ProgressView().controlSize(.small).scaleEffect(0.55)
                    } else {
                        Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .semibold))
                    }
                    Text("Rescan").font(Theme.font(12))
                }
                .foregroundColor(Theme.textControl)
                .frame(height: 28).padding(.horizontal, 11)
                .background(RoundedRectangle(cornerRadius: Theme.radius(7)).fill(Theme.chipBG))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius(7))
                    .strokeBorder(Theme.borderChip, lineWidth: Theme.ruleWidth))
            }
            .buttonStyle(FlatButtonStyle())
            .disabled(inventory.isScanning)
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
    }

    private func chip(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.font(11.5, active ? .semibold : .regular))
                .foregroundColor(active ? Theme.accentSoft : Theme.textMuted)
                .frame(height: 28).padding(.horizontal, 10)
                .background(RoundedRectangle(cornerRadius: Theme.radius(7))
                    .fill(active ? Theme.accent.opacity(0.16) : Theme.chipBG))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius(7))
                    .strokeBorder(active ? Theme.accent.opacity(0.5) : Theme.borderChip,
                                  lineWidth: Theme.ruleWidth))
        }
        .buttonStyle(FlatButtonStyle())
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailPane: some View {
        if let app = inventory.selected {
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        appHeader(app)
                        if let reason = app.protectionReason {
                            note(reason, tone: Theme.warning, icon: "lock.fill")
                        }
                        if app.isRunning {
                            note("This app is running. DrivePurge will offer to quit it first.",
                                 tone: Theme.amber, icon: "bolt.horizontal.fill")
                        }
                        leftoverSection
                    }
                    .padding(16)
                }
                Rectangle().fill(Theme.borderSoft).frame(height: Theme.ruleWidth)
                uninstallBar(app)
            }
            .background(Theme.sidebarBG)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "hand.point.left")
                    .font(.system(size: 24, weight: .light)).foregroundColor(Theme.textFaint)
                Text("Pick an application")
                    .font(Theme.font(13, .semibold)).foregroundColor(Theme.textBody)
                Text("You will see everything it left behind before anything is removed.")
                    .font(Theme.font(11.5)).foregroundColor(Theme.textFaint)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 26)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.sidebarBG)
        }
    }

    private func appHeader(_ app: InstalledApp) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(nsImage: app.icon)
                    .resizable().frame(width: 46, height: 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.name)
                        .font(Theme.font(15, .semibold)).foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                    Text([app.version.map { "Version \($0)" }, app.lastUsedLabel]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(Theme.font(11.5)).foregroundColor(Theme.textMuted)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                detailRow("Application", Bytes.format(app.size))
                detailRow("Leftovers", inventory.isLoadingLeftovers
                          ? "checking…" : Bytes.format(inventory.leftoverBytes))
                if let id = app.bundleID { detailRow("Bundle", id) }
                detailRow("Location", app.displayPath)
            }

            Button { inventory.revealInFinder(app) } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.forward.app").font(.system(size: 10))
                    Text("Show in Finder").font(Theme.font(11.5))
                }
                .foregroundColor(Theme.textMuted)
            }
            .buttonStyle(FlatButtonStyle())
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(Theme.font(11.5)).foregroundColor(Theme.textFaint)
                .frame(width: 78, alignment: .leading)
            Text(value).font(Theme.mono(11.5)).foregroundColor(Theme.textBody)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var leftoverSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                SectionLabel(text: "ALSO LEFT BEHIND")
                Spacer()
                if !inventory.leftovers.isEmpty {
                    Button { inventory.selectSafeLeftovers() } label: {
                        Text("Safe").font(Theme.font(11)).foregroundColor(Theme.textMuted)
                    }.buttonStyle(FlatButtonStyle())
                    Button { inventory.selectAllLeftovers() } label: {
                        Text("All").font(Theme.font(11)).foregroundColor(Theme.textMuted)
                    }.buttonStyle(FlatButtonStyle())
                    Button { inventory.selectNoLeftovers() } label: {
                        Text("None").font(Theme.font(11)).foregroundColor(Theme.textMuted)
                    }.buttonStyle(FlatButtonStyle())
                }
            }

            if inventory.isLoadingLeftovers {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                    Text("Looking through your Library…")
                        .font(Theme.font(11.5)).foregroundColor(Theme.textFaint)
                }
            } else if inventory.leftovers.isEmpty {
                Text("Nothing else found. This app keeps to itself.")
                    .font(Theme.font(11.5)).foregroundColor(Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(inventory.leftovers) { item in
                    LeftoverRow(item: item,
                                checked: inventory.chosenLeftovers.contains(item.id)) {
                        inventory.toggle(item)
                    } reveal: {
                        inventory.revealInFinder(item)
                    }
                }
            }
        }
    }

    private func note(_ text: String, tone: Color, icon: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).font(.system(size: 10)).foregroundColor(tone)
            Text(text).font(Theme.font(11.5)).foregroundColor(tone)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.radius(6)).fill(tone.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius(6))
            .strokeBorder(tone.opacity(0.32), lineWidth: Theme.ruleWidth))
    }

    private func uninstallBar(_ app: InstalledApp) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(Bytes.format(inventory.reclaimableBytes))
                    .font(Theme.mono(14, .bold)).foregroundColor(Theme.textPrimary)
                Text("would be freed").font(Theme.font(10.5)).foregroundColor(Theme.textFaint)
            }
            Spacer()
            Button { inventory.uninstallSelected() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "trash").font(.system(size: 11, weight: .semibold))
                    Text("Uninstall").font(Theme.font(12.5, .semibold))
                }
                .foregroundColor(app.isProtected ? Theme.textFaint : Theme.onAccent)
                .frame(height: 32).padding(.horizontal, 16)
                .background(RoundedRectangle(cornerRadius: Theme.radius(8))
                    .fill(app.isProtected ? Theme.chipBG : Theme.danger))
            }
            .buttonStyle(FlatButtonStyle())
            .disabled(app.isProtected)
            .help(app.protectionReason ?? "Move this app and the ticked items to the Trash")
        }
        .padding(.horizontal, 16)
        .frame(height: 60)
        .background(Theme.statusBarBG)
    }

    private func centred<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 10) { content() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Rows

private struct AppRow: View {
    let app: InstalledApp
    let maxBytes: Int64
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(nsImage: app.icon).resizable().frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(app.name)
                            .font(Theme.font(13, .medium)).foregroundColor(Theme.textStrong)
                            .lineLimit(1)
                        if app.isProtected {
                            tag("system", Theme.textFaint)
                        } else if app.isRunning {
                            tag("running", Theme.success)
                        } else if app.isStale {
                            tag("unused", Theme.amber)
                        }
                        Spacer(minLength: 0)
                        Text(Bytes.format(app.size))
                            .font(Theme.mono(12, .semibold)).foregroundColor(Theme.textBody)
                    }
                    HStack(spacing: 7) {
                        MiniBar(fraction: Double(app.size) / Double(max(1, maxBytes)),
                                color: app.isStale ? Theme.amber : Theme.accent, height: 4)
                            .frame(maxWidth: 160)
                        Text(app.lastUsedLabel)
                            .font(Theme.font(11)).foregroundColor(Theme.textFaint)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(selected ? Theme.rowSelectedBG : (hovering ? Theme.rowHoverBG : .clear))
            .overlay(alignment: .leading) {
                Rectangle().fill(selected ? Theme.accent : .clear).frame(width: 3)
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.borderRow).frame(height: Theme.ruleWidth)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(FlatButtonStyle())
        .onHover { hovering = $0 }
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(Theme.font(9.5, .semibold)).kerning(0.4)
            .foregroundColor(color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: Theme.radius(4)).fill(color.opacity(0.14)))
    }
}

private struct LeftoverRow: View {
    let item: LeftoverItem
    let checked: Bool
    let toggle: () -> Void
    let reveal: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Button(action: toggle) {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13))
                    .foregroundColor(checked ? Theme.accent : Theme.textDim)
            }
            .buttonStyle(FlatButtonStyle())

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.kind.rawValue)
                        .font(Theme.font(11.5, .semibold)).foregroundColor(Theme.textBody)
                    if item.needsAdmin {
                        Text("needs admin")
                            .font(Theme.font(9.5, .semibold)).foregroundColor(Theme.amber)
                    }
                    Spacer(minLength: 0)
                    Text(Bytes.format(item.size))
                        .font(Theme.mono(11)).foregroundColor(Theme.textMuted)
                }
                Text(item.displayPath)
                    .font(Theme.font(10.5)).foregroundColor(Theme.textFaint)
                    .lineLimit(1).truncationMode(.middle)
                if hovering {
                    Text(item.kind.explanation)
                        .font(Theme.font(10.5)).foregroundColor(Theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: Theme.radius(6))
            .fill(hovering ? Theme.rowHoverBG : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: reveal)
    }
}
