import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    @Bindable var settings: AppSettings
    @Bindable var accessibilityPermission: AccessibilityPermissionController
    @State private var selectedTab = SettingsTab.general
    @State private var serviceError: String?
    @State private var confirmCleanup = false

    init(model: AppModel, accessibilityPermission: AccessibilityPermissionController) {
        self.model = model
        self.settings = model.settings
        self.accessibilityPermission = accessibilityPermission
    }

    enum SettingsTab: String, CaseIterable, Identifiable {
        case general
        case shortcuts
        case history
        case privacy

        var id: String { rawValue }
        var title: String {
            switch self {
            case .general: "通用"
            case .shortcuts: "快捷键"
            case .history: "历史"
            case .privacy: "隐私"
            }
        }
        var icon: String {
            switch self {
            case .general: "gearshape"
            case .shortcuts: "command"
            case .history: "clock.arrow.circlepath"
            case .privacy: "hand.raised"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(SettingsTab.allCases) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                        ZStack {
                            RoundedRectangle(cornerRadius: 9)
                                .fill(selectedTab == tab ? Color.accentColor.opacity(0.14) : .clear)
                                .padding(.horizontal, 2.5)
                            VStack(spacing: 4) {
                                Image(systemName: tab.icon).font(.system(size: 17))
                                Text(tab.title).font(.caption)
                            }
                        }
                        .frame(width: 76, height: 48)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(selectedTab == tab ? Color.accentColor : Color.primary)
                    .accessibilityLabel("\(tab.title)设置")
                    .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
                }
            }
            .padding(10)

            Divider()

            Form {
                switch selectedTab {
                case .general: generalSettings
                case .shortcuts: shortcutSettings
                case .history: historySettings
                case .privacy: privacySettings
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .frame(width: 560, height: 430)
        .alert("无法更新登录项", isPresented: Binding(
            get: { serviceError != nil },
            set: { if !$0 { serviceError = nil } }
        )) {
            Button("好") { serviceError = nil }
        } message: {
            Text(serviceError ?? "未知错误")
        }
        .confirmationDialog("清理所有非收藏历史？", isPresented: $confirmCleanup) {
            Button("清理非收藏内容", role: .destructive) { model.clearUnfavorited() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("文本、图片原图和缩略图都会删除；收藏内容会保留。")
        }
    }

    @ViewBuilder
    private var generalSettings: some View {
        Section("运行") {
            Toggle("记录剪贴板变化", isOn: $settings.isMonitoringEnabled)
            Toggle("登录时自动启动", isOn: Binding(
                get: { model.settings.launchAtLogin },
                set: updateLaunchAtLogin
            ))
            Toggle("仅复制后关闭面板", isOn: $settings.closeAfterCopy)
        }
        Section("快速粘贴") {
            Label("双击历史条目、点右侧粘贴按钮或按 Return，会粘贴到唤起前的应用。", systemImage: "return")
            Text("单击只选择条目；按空格可展开或收起详情。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("首次使用会请求辅助功能权限；拒绝授权时仍会把内容复制到剪贴板。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var shortcutSettings: some View {
        Section("全局快捷键") {
            LabeledContent("打开历史") {
                ShortcutRecorderView(
                    shortcut: $settings.historyShortcut,
                    accessibilityLabel: "打开历史快捷键"
                )
            }
            LabeledContent("打开收藏") {
                ShortcutRecorderView(
                    shortcut: $settings.favoritesShortcut,
                    accessibilityLabel: "打开收藏快捷键"
                )
            }
            HStack {
                Text("点击快捷键后直接按下新的组合键；Esc 取消。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("恢复默认") {
                    settings.historyShortcut = .defaultHistory
                    settings.favoritesShortcut = .defaultFavorites
                }
            }
            if let message = model.shortcutConflictMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Text("面板内还可用 ← / → 或 ⌘1 / ⌘2 切换历史和收藏，⌘F 搜索，⌘D 收藏。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var historySettings: some View {
        Section("排序") {
            Toggle("自动粘贴后移到顶部", isOn: $settings.promotePastedItems)
            Text("开启后按最近使用顺序排列历史、收藏和搜索结果；原始复制时间不会改变。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Section("保留策略") {
            Picker("最多保留", selection: $settings.maxItems) {
                ForEach([200, 500, 1_000, 2_000, 5_000], id: \.self) { Text("\($0) 条").tag($0) }
            }
            Picker("单项大小上限", selection: $settings.maxCaptureMegabytes) {
                ForEach([5, 10, 30, 50, 100], id: \.self) { Text("\($0) MB").tag($0) }
            }
            Picker("检测间隔", selection: $settings.pollInterval) {
                Text("极速 · 0.25 秒").tag(0.25)
                Text("平衡 · 0.45 秒").tag(0.45)
                Text("省电 · 0.75 秒").tag(0.75)
                Text("最低功耗 · 1 秒").tag(1.0)
            }
            Text("收藏内容永不被数量限制自动清理。图片只在需要时从磁盘读取。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var privacySettings: some View {
        Section("本地与权限") {
            Label("历史内容只保存在这台 Mac 的 Application Support/XPaste 中。", systemImage: "externaldrive.badge.checkmark")
            Label("带有 transient / concealed 标记的密码类剪贴板内容会被跳过。", systemImage: "key.horizontal")
            if model.pasteboardAccessDenied {
                Label("macOS 当前禁止 XPaste 读取剪贴板。请在系统设置的隐私与安全性中允许。", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            HStack {
                VStack(alignment: .leading) {
                    Text("辅助功能")
                    Text(accessibilityPermission.isAuthorized ? "已授权，可自动粘贴" : "未授权；复制和记录仍可使用")
                        .font(.caption)
                        .foregroundStyle(accessibilityPermission.isAuthorized ? Color.green : Color.secondary)
                }
                Spacer()
                if accessibilityPermission.isAuthorized {
                    Button("重新检查") { accessibilityPermission.refresh() }
                } else {
                    Button("请求权限") { accessibilityPermission.requestAuthorization() }
                    Button("打开系统设置") { accessibilityPermission.openSystemSettings() }
                }
            }
            if !accessibilityPermission.isAuthorized {
                Text("如果系统设置中已经打开 XPaste，请返回这里重新检查。若仍未识别，请移除列表里的旧 XPaste，再添加“应用程序”中的当前版本并重新启动。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        Section("数据维护") {
            HStack {
                Text("非收藏内容")
                Spacer()
                Button("清理非收藏历史…", role: .destructive) { confirmCleanup = true }
                    .disabled(model.items.allSatisfy(\.isFavorite))
            }
        }
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            model.settings.launchAtLogin = enabled
        } catch {
            model.settings.launchAtLogin = false
            serviceError = error.localizedDescription
        }
    }
}
