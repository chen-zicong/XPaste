import AppKit
import SwiftUI
import XPasteCore

struct MainPanelView: View {
    @Bindable var model: AppModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.pasteboardAccessDenied {
                accessDeniedBanner
            } else if !model.settings.isMonitoringEnabled {
                pausedBanner
            }
            if model.page == .statistics {
                StatisticsView(model: model)
            } else {
                listCaption
                content
                keyboardFooter
            }
        }
        .background(PanelTheme.canvas)
        .frame(minWidth: minimumPanelWidth, minHeight: 360)
        .tint(PanelTheme.accent)
        .clipShape(RoundedRectangle(cornerRadius: PanelTheme.windowRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: PanelTheme.windowRadius).strokeBorder(PanelTheme.border))
        .onChange(of: model.searchFocusToken) { _, _ in searchFocused = true }
        .modifier(PanelFeedback(model: model, isPreview: false))
        .ignoresSafeArea(.container, edges: .top)
    }

    private var header: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if model.page == .statistics {
                    Button { model.show(page: .history) } label: {
                        Image(systemName: "arrow.left")
                    }
                    .buttonStyle(PanelToolbarButtonStyle())
                    .help("返回历史")
                    .accessibilityLabel("返回历史")
                    Text("存储统计").font(.system(size: 17, weight: .medium))
                    Spacer()
                } else {
                    searchField
                }
                Button { model.togglePanelPinned() } label: {
                    Image(systemName: model.isPanelPinned ? "pin.fill" : "pin")
                }
                .buttonStyle(PanelToolbarButtonStyle(isSelected: model.isPanelPinned))
                .help(model.isPanelPinned ? "取消固定窗口" : "固定窗口")
                .accessibilityLabel(model.isPanelPinned ? "取消固定窗口" : "固定窗口")
                .accessibilityValue(model.isPanelPinned ? "已固定" : "未固定")
                if model.page != .statistics {
                    Button { model.toggleDetails() } label: {
                        Image(systemName: "rectangle.topthird.inset.filled")
                    }
                    .buttonStyle(PanelToolbarButtonStyle(isSelected: model.isDetailVisible))
                    .disabled(model.selectedItem == nil)
                    .help(model.isDetailVisible ? "收起明细（空格 / ⌘I）" : "显示明细（空格 / ⌘I）")
                    .accessibilityLabel(model.isDetailVisible ? "收起明细" : "显示明细")
                } else {
                    moreMenu
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 60)

            if model.page != .statistics {
                HStack(spacing: 4) {
                    scopeButton("全部", isSelected: model.page == .history && model.filter == .all) {
                        showHistory(filter: .all)
                    }
                    scopeButton("收藏", icon: "star", isSelected: model.page == .favorites) {
                        model.filter = .all
                        model.show(page: .favorites)
                    }
                    Divider().frame(height: 13).padding(.horizontal, 5)
                    ForEach([ClipboardFilter.text, .image, .files], id: \.rawValue) { filter in
                        scopeButton(filter.displayName, isSelected: model.page == .history && model.filter == filter) {
                            showHistory(filter: filter)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .frame(height: 28)
                .padding(.bottom, 14)
            }
            PanelSeparator()
        }
        .background(PanelTheme.canvas)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .regular))
                .frame(width: 18)
                .foregroundStyle(searchFocused ? PanelTheme.accent : PanelTheme.secondary)
            TextField(model.page == .favorites ? "搜索收藏…" : "搜索剪贴板…", text: $model.query)
                .font(.system(size: 16, weight: .regular))
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .accessibilityLabel(model.page == .favorites ? "搜索收藏" : "搜索剪贴板历史")
            if !model.query.isEmpty {
                Button { model.query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(PanelToolbarButtonStyle())
                .accessibilityLabel("清除搜索")
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var moreMenu: some View {
        Menu {
            Button { model.show(page: .statistics) } label: {
                Label("存储统计", systemImage: "chart.pie")
            }
            Divider()
            ForegroundSettingsButton(beforeOpen: { model.onHideRequest?() }) {
                Label("设置…", systemImage: "gearshape")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .medium))
                .frame(width: 32, height: 32)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .tint(.secondary)
        .fixedSize()
        .help("更多操作")
        .accessibilityLabel("更多操作")
    }

    private func scopeButton(_ title: String, icon: String? = nil, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon).font(.system(size: 11, weight: .medium)) }
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 9)
            .frame(height: 28)
        }
        .buttonStyle(PanelScopeButtonStyle(isSelected: isSelected))
        .accessibilityLabel(title)
        .accessibilityValue(isSelected ? "已选择" : "未选择")
    }

    private func showHistory(filter: ClipboardFilter) {
        model.filter = filter
        model.show(page: .history)
    }

    private var content: some View {
        ClipboardListView(model: model)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var listCaption: some View {
        HStack {
            Text(!model.query.isEmpty ? "搜索结果" : model.page == .favorites ? "已收藏" : "最近复制")
            Spacer()
            Text("\(model.visibleItems.count) 条").monospacedDigit()
        }
        .font(PanelTheme.captionFont)
        .foregroundStyle(PanelTheme.muted)
        .padding(.horizontal, 22)
        .padding(.top, 14)
        .padding(.bottom, 7)
    }

    private var keyboardFooter: some View {
        VStack(spacing: 0) {
            PanelSeparator()
            HStack(spacing: 12) {
                keyboardHint("↵", label: "粘贴")
                keyboardHint("空格", label: "预览")
                Spacer()
                Button { model.copySelected(autoPaste: false) } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(PanelToolbarButtonStyle())
                .disabled(model.selectedItem == nil)
                .help("仅复制（⌘C）")
                .accessibilityLabel("仅复制")
                moreMenu
            }
            .font(PanelTheme.captionFont)
            .foregroundStyle(PanelTheme.muted)
            .padding(.horizontal, 16)
            .frame(height: PanelTheme.footerHeight)
        }
        .background(PanelTheme.chrome)
    }

    private func keyboardHint(_ key: String, label: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(size: 10))
                .padding(.horizontal, 3)
                .frame(minWidth: 17, minHeight: 17)
                .background(PanelTheme.canvas, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(PanelTheme.border))
            Text(label)
        }
        .accessibilityElement(children: .combine)
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
        .padding(.horizontal, PanelTheme.contentInset)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.09))
    }

    private var accessDeniedBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.raised.fill")
            Text("macOS 已阻止读取剪贴板，历史记录暂时无法更新")
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("打开系统设置") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.borderless)
            .fixedSize()
        }
        .font(.callout)
        .foregroundStyle(.orange)
        .padding(.horizontal, PanelTheme.contentInset)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.09))
    }

    private var minimumPanelWidth: CGFloat {
        model.page == .statistics ? 760 : 440
    }
}
