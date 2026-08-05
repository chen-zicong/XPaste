import AppKit
import SwiftUI
import XPasteCore

struct MainPanelView: View {
    @Bindable var model: AppModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header
                if model.pasteboardAccessDenied {
                    accessDeniedBanner
                } else if !model.settings.isMonitoringEnabled {
                    pausedBanner
                }
                Divider().opacity(0.55)

                if model.page == .statistics {
                    StatisticsView(model: model)
                } else {
                    content
                }

                Divider().opacity(0.55)
                footer
            }
            .background(.ultraThinMaterial)

            if let toast = model.toastMessage {
                VStack {
                    Spacer()
                    HStack(spacing: 10) {
                        Text(toast)
                            .font(.callout.weight(.medium))
                        if model.pendingDeletion != nil {
                            Button("撤销") { model.undoDeletion() }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                        }
                    }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(.regularMaterial, in: Capsule())
                        .shadow(color: .black.opacity(0.16), radius: 12, y: 5)
                        .padding(.bottom, 52)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(minWidth: minimumPanelWidth, minHeight: 500)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .animation(.easeInOut(duration: 0.18), value: model.isDetailVisible)
        .onChange(of: model.searchFocusToken) { _, _ in searchFocused = true }
        .sheet(item: $model.imageEditorItem) { item in
            ImageEditorView(model: model, item: item)
        }
        .alert("XPaste", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("好") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "发生未知错误")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            pageSwitcher

            if model.page == .statistics {
                Label("存储统计", systemImage: "chart.pie.fill")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                searchField
                    .frame(maxWidth: .infinity)
                    .layoutPriority(1)
            }

            if model.page != .statistics {
                Button {
                    model.toggleDetails()
                } label: {
                    Image(systemName: model.isDetailVisible ? "rectangle.righthalf.inset.filled" : "sidebar.right")
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(PanelIconButtonStyle(isSelected: model.isDetailVisible))
                .disabled(model.selectedItem == nil)
                .help(model.isDetailVisible ? "收起详情（空格 / ⌘I）" : "显示详情（空格 / ⌘I）")
                .accessibilityLabel(model.isDetailVisible ? "收起详情" : "显示详情")
            }

            Button {
                model.togglePanelPinned()
            } label: {
                Image(systemName: model.isPanelPinned ? "pin.fill" : "pin")
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(PanelIconButtonStyle(isSelected: model.isPanelPinned))
            .help(model.isPanelPinned ? "取消固定窗口" : "固定窗口")
            .accessibilityLabel(model.isPanelPinned ? "取消固定窗口" : "固定窗口")
            .accessibilityValue(model.isPanelPinned ? "已固定" : "未固定")

            Menu {
                Button {
                    model.show(page: .statistics)
                } label: {
                    Label("存储统计", systemImage: "chart.pie")
                }

                Divider()

                ForegroundSettingsButton(beforeOpen: { model.onHideRequest?() }) {
                    Label("设置…", systemImage: "gearshape")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: 32, height: 32)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("更多")
            .accessibilityLabel("更多操作")
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    private var pageSwitcher: some View {
        HStack(spacing: 2) {
            ForEach([PanelPage.history, .favorites]) { page in
                Button {
                    model.show(page: page)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: pageIcon(for: page))
                            .font(.system(size: 13, weight: .medium))
                        Text(page.title)
                            .font(.callout.weight(.medium))
                    }
                    .frame(minWidth: 62, minHeight: 30)
                    .contentShape(Rectangle())
                    .background(
                        model.page == page ? Color.accentColor.opacity(0.16) : .clear,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.page == page ? Color.accentColor : Color.primary)
                .help(page.title)
                .accessibilityLabel(page.title)
                .accessibilityValue(model.page == page ? "已选择" : "未选择")
            }
        }
        .padding(3)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
    }

    private func pageIcon(for page: PanelPage) -> String {
        switch page {
        case .history:
            "clock.arrow.circlepath"
        case .favorites:
            model.page == .favorites ? "star.fill" : "star"
        case .statistics:
            "chart.pie"
        }
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索剪贴板", text: $model.query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .accessibilityLabel("搜索剪贴板历史")
            if !model.query.isEmpty {
                Button { model.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            Text("⌘F")
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.72), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.08)))
    }

    private var pausedBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "pause.circle.fill")
            Text("剪贴板记录已暂停")
            Spacer()
            Button("继续记录") { model.settings.isMonitoringEnabled = true }
                .buttonStyle(.borderless)
        }
        .font(.callout)
        .foregroundStyle(.orange)
        .padding(.horizontal, 18)
        .frame(height: 34)
        .background(Color.orange.opacity(0.09))
    }

    private var accessDeniedBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.raised.fill")
            Text("macOS 已阻止读取剪贴板，历史记录暂时无法更新")
            Spacer()
            Button("打开系统设置") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.borderless)
        }
        .font(.callout)
        .foregroundStyle(.orange)
        .padding(.horizontal, 18)
        .frame(height: 34)
        .background(Color.orange.opacity(0.09))
    }

    private var content: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Menu {
                        ForEach(ClipboardFilter.allCases, id: \.rawValue) { filter in
                            Button {
                                model.filter = filter
                            } label: {
                                if model.filter == filter {
                                    Label(filter.displayName, systemImage: "checkmark")
                                } else {
                                    Text(filter.displayName)
                                }
                            }
                        }
                    } label: {
                        Label(model.filter.displayName, systemImage: filterIcon)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel("内容类型：\(model.filter.displayName)")

                    Spacer()

                    Text("\(model.visibleItems.count) 条")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .frame(height: 38)

                Divider().opacity(0.55)
                ClipboardListView(model: model)
            }
            .frame(
                minWidth: model.isDetailVisible ? 285 : 420,
                idealWidth: model.isDetailVisible ? 320 : 620,
                maxWidth: model.isDetailVisible ? 350 : .infinity
            )

            if model.isDetailVisible {
                Divider().opacity(0.55)
                ClipboardDetailView(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if model.page == .statistics {
                Text("存储占用与内容类型统计")
            } else {
                Text("↑↓ 选择  ·  空格 详情  ·  ↩ 粘贴  ·  ←→ 切换  ·  \(escapeHint)")
                    .lineLimit(1)
                    .minimumScaleFactor(0.86)
            }
            Spacer()
            Button {
                model.show(page: .statistics)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: model.page == .statistics ? "chart.pie.fill" : "chart.pie")
                    Text(ByteCountFormatter.string(fromByteCount: Int64(model.stats.totalBytes), countStyle: .file))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.page == .statistics ? Color.accentColor : Color.secondary)
            .help("查看存储统计")
            .accessibilityLabel("存储统计，当前占用 \(ByteCountFormatter.string(fromByteCount: Int64(model.stats.totalBytes), countStyle: .file))")
            if model.isProcessingCapture {
                ProgressView().controlSize(.small)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .frame(height: 32)
    }

    private var escapeHint: String {
        if model.isDetailVisible {
            return "Esc 收起详情"
        }
        if !model.query.isEmpty {
            return "Esc 清除搜索"
        }
        return "Esc 关闭"
    }

    private var filterIcon: String {
        switch model.filter {
        case .all: "line.3.horizontal.decrease.circle"
        case .text: "text.alignleft"
        case .image: "photo"
        case .files: "doc.on.doc"
        }
    }

    private var minimumPanelWidth: CGFloat {
        model.page == .statistics || model.isDetailVisible ? 760 : 560
    }
}

private struct PanelIconButtonStyle: ButtonStyle {
    var isSelected = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(minWidth: 32, minHeight: 32)
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            .background(
                (isSelected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(configuration.isPressed ? 0.08 : 0.001)),
                in: RoundedRectangle(cornerRadius: 7)
            )
            .contentShape(Rectangle())
    }
}
