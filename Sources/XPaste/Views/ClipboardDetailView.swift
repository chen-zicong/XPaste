import AppKit
import SwiftUI
import XPasteCore

struct ClipboardDetailView: View {
    @Bindable var model: AppModel

    var body: some View {
        if let item = model.selectedItem {
            VStack(spacing: 0) {
                detailHeader(item)
                Divider().opacity(0.55)
                switch item.kind {
                case .text:
                    TextDetailView(model: model, item: item)
                case .image:
                    ImageDetailView(model: model, item: item)
                case .files:
                    FilesDetailView(model: model, item: item)
                }
            }
            .id(item.id)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "rectangle.on.rectangle.slash")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("选择一条记录查看详情")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func detailHeader(_ item: ClipboardItem) -> some View {
        HStack(spacing: 9) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.kind.displayName)
                    .font(.headline)
                HStack(spacing: 5) {
                    if model.settings.promotePastedItems,
                       item.lastUsedAt.timeIntervalSince(item.createdAt) >= 60 {
                        Text("\(ClipboardTimestampFormatter.display(item.lastUsedAt, relativeTo: model.timestampReferenceDate))使用")
                            .help("最近使用于 \(ClipboardTimestampFormatter.full(item.lastUsedAt))")
                            .accessibilityLabel("最近使用于 \(ClipboardTimestampFormatter.full(item.lastUsedAt))")
                        Text("·")
                    }
                    Text(ClipboardTimestampFormatter.display(
                        item.createdAt,
                        relativeTo: model.timestampReferenceDate
                    ))
                    .help("记录于 \(ClipboardTimestampFormatter.full(item.createdAt))")
                    .accessibilityLabel(
                        "\(ClipboardTimestampFormatter.display(item.createdAt, relativeTo: model.timestampReferenceDate))；记录于 \(ClipboardTimestampFormatter.full(item.createdAt))"
                    )
                    Text("·")
                    Text(ByteCountFormatter.string(fromByteCount: Int64(item.storageBytes), countStyle: .file))
                    if item.editCount > 0 {
                        Text("· 已编辑 \(item.editCount) 次")
                    }
                    if item.captureCount > 1 {
                        Text("· 复制 \(item.captureCount) 次")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .layoutPriority(1)

            Spacer()

            ControlGroup {
                Button { model.toggleFavorite(item) } label: {
                    Image(systemName: item.isFavorite ? "star.fill" : "star")
                        .foregroundStyle(item.isFavorite ? .yellow : .primary)
                }
                .help(item.isFavorite ? "取消收藏" : "收藏")
                .accessibilityLabel(item.isFavorite ? "取消收藏" : "收藏")

                Button { model.copy(item, autoPaste: false) } label: {
                    Image(systemName: "doc.on.doc")
                }
                .help("仅复制")
                .accessibilityLabel("仅复制")

                Button { model.paste(item) } label: {
                    Image(systemName: "arrow.down.doc.fill")
                }
                .help("粘贴到原应用")
                .accessibilityLabel("粘贴到原应用")
            }
            .controlSize(.regular)

            Button(role: .destructive) { model.delete(item) } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("删除")
            .accessibilityLabel("删除")
        }
        .padding(.horizontal, 18)
        .frame(height: 62)
    }
}

private struct TextDetailView: View {
    @Bindable var model: AppModel
    let item: ClipboardItem

    var body: some View {
        VStack(spacing: 10) {
            TextEditor(text: Binding(
                get: { model.draftText(for: item) },
                set: { model.updateDraft(id: item.id, text: $0) }
            ))
                .font(.system(size: 14, design: .default))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.78), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
                .accessibilityLabel("文本编辑器")

            HStack {
                Label("\(model.draftText(for: item).count) 个字符", systemImage: "character.cursor.ibeam")
                if model.draftText(for: item) != (item.text ?? "") {
                    Text("有未保存的更改").foregroundStyle(.orange)
                }
                Spacer()
                Button("还原") { model.discardDraft(for: item) }
                    .disabled(model.draftText(for: item) == (item.text ?? ""))
                Button("保存编辑") { model.saveText(id: item.id, text: model.draftText(for: item)) }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.draftText(for: item).isEmpty || model.draftText(for: item) == (item.text ?? ""))
                    .keyboardShortcut("s", modifiers: .command)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(16)
    }
}

private struct ImageDetailView: View {
    let model: AppModel
    let item: ClipboardItem
    @State private var image: NSImage?
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.primary.opacity(0.035))
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(18)
                } else if isLoading {
                    ProgressView("正在读取图片…")
                } else {
                    ContentUnavailableView("图片不可用", systemImage: "photo.badge.exclamationmark", description: Text("原始图片文件可能已丢失"))
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.07)))

            HStack {
                if let image {
                    Label("\(Int(image.size.width)) × \(Int(image.size.height)) pt", systemImage: "aspectratio")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.imageEditorItem = item } label: {
                    Label("编辑图片", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(16)
        .task(id: item.imageFileName) {
            isLoading = true
            guard let url = model.assetURL(for: item) else { isLoading = false; return }
            image = await Task.detached(priority: .userInitiated) { NSImage(contentsOf: url) }.value
            isLoading = false
        }
        .onDisappear { image = nil }
    }
}

private struct FilesDetailView: View {
    let model: AppModel
    let item: ClipboardItem
    @State private var report: FileResolutionReport?
    @State private var isChecking = false

    var body: some View {
        VStack(spacing: 0) {
            statusHeader
            Divider().opacity(0.45)
            ScrollView {
                LazyVStack(spacing: 7) {
                    if let report {
                        ForEach(report.entries, id: \.index) { entry in
                            fileRow(entry)
                        }
                    } else {
                        ProgressView("正在检查文件…")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 36)
                    }
                }
                .padding(16)
            }
            Spacer(minLength: 0)
        }
        .task(id: item.contentHash) { await refresh() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            Task { await refresh() }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            Task { await refresh() }
        }
    }

    private var statusHeader: some View {
        HStack(spacing: 8) {
            if let report {
                let availableCount = report.availableURLs.count
                Label(
                    "\(availableCount)/\(report.entries.count) 个文件可用",
                    systemImage: report.unavailableCount == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                )
                .foregroundStyle(report.unavailableCount == 0 ? Color.green : Color.orange)
                if report.unavailableCount > 0, availableCount > 0 {
                    Text("粘贴时会跳过不可用项")
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("正在检查文件状态")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isChecking {
                ProgressView().controlSize(.small)
            }
            Button { Task { await refresh() } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(isChecking)
            .help("重新检查文件状态")
            .accessibilityLabel("重新检查文件状态")
        }
        .font(.caption)
        .padding(.horizontal, 16)
        .frame(height: 42)
    }

    private func fileRow(_ entry: ResolvedFileReference) -> some View {
        let displayURL = entry.resolvedURL ?? URL(fileURLWithPath: entry.storedPath)
        return HStack(spacing: 11) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: displayURL.path))
                .resizable()
                .frame(width: 34, height: 34)
                .opacity(entry.availability == .available ? 1 : 0.55)
            VStack(alignment: .leading, spacing: 4) {
                Text(displayURL.lastPathComponent)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(displayURL.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Label(statusText(entry.availability), systemImage: statusIcon(entry.availability))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(statusColor(entry.availability))
            }
            Spacer()
            if entry.availability == .available {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([displayURL])
                } label: {
                    Image(systemName: "arrow.forward.circle")
                }
                .buttonStyle(.borderless)
                .help("在 Finder 中显示")
                .accessibilityLabel("在 Finder 中显示")
            } else {
                Button("重新定位…") { chooseReplacement(for: entry) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
    }

    private func refresh() async {
        guard !isChecking else { return }
        isChecking = true
        report = await model.fileResolutionReport(for: item)
        isChecking = false
    }

    private func chooseReplacement(for entry: ResolvedFileReference) {
        let panel = NSOpenPanel()
        panel.title = "重新定位“\(URL(fileURLWithPath: entry.storedPath).lastPathComponent)”"
        panel.prompt = "重新定位"
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        let parent = URL(fileURLWithPath: entry.storedPath).deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: parent.path) {
            panel.directoryURL = parent
        }
        guard panel.runModal() == .OK, let URL = panel.url else { return }
        Task {
            if await model.replaceFileReference(itemID: item.id, index: entry.index, with: URL) {
                await refresh()
            }
        }
    }

    private func statusText(_ availability: FileReferenceAvailability) -> String {
        switch availability {
        case .available: "可用"
        case .missing: "文件已删除或移动"
        case .volumeUnavailable: "所在磁盘未连接"
        case .authorizationRequired: "需要重新授权"
        }
    }

    private func statusIcon(_ availability: FileReferenceAvailability) -> String {
        switch availability {
        case .available: "checkmark.circle.fill"
        case .missing: "questionmark.folder.fill"
        case .volumeUnavailable: "externaldrive.badge.exclamationmark"
        case .authorizationRequired: "lock.trianglebadge.exclamationmark"
        }
    }

    private func statusColor(_ availability: FileReferenceAvailability) -> Color {
        switch availability {
        case .available: .green
        case .missing: .red
        case .volumeUnavailable, .authorizationRequired: .orange
        }
    }
}
