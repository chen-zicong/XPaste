import AppKit
import SwiftUI
import XPasteCore

struct ClipboardDetailView: View {
    @Bindable var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let item = model.selectedItem {
                VStack(spacing: 0) {
                    detailHeader(item)
                    Group {
                        switch item.kind {
                        case .text: TextDetailView(model: model, item: item)
                        case .image: ImageDetailView(model: model, item: item)
                        case .files: FilesDetailView(model: model, item: item)
                        }
                    }
                    .id(item.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .readingPaper()
                    .padding(.horizontal, 16)
                    detailFooter(item)
                }
            } else {
                ContentUnavailableView("没有可预览的内容", systemImage: "doc.text.magnifyingglass")
            }
        }
        .frame(minWidth: 480, minHeight: 340)
        .background(PanelTheme.paperSurround)
        .clipShape(RoundedRectangle(cornerRadius: PanelTheme.windowRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: PanelTheme.windowRadius).strokeBorder(PanelTheme.border))
        .tint(PanelTheme.accent)
        .modifier(PanelFeedback(model: model, isPreview: true))
        .ignoresSafeArea(.container, edges: .top)
    }

    private func detailHeader(_ item: ClipboardItem) -> some View {
        HStack(spacing: 10) {
            Button { model.isDetailVisible = false } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(PanelTheme.secondary)
                    .frame(width: 22, height: 22)
                    .background(PanelTheme.border, in: Circle())
            }
            .buttonStyle(.plain)
            .help("关闭明细（空格 / Esc）")
            .accessibilityLabel("关闭明细")
            Text("\(item.kind.displayName)预览")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(PanelTheme.secondary)
            Spacer(minLength: 8)
            Button { model.toggleFavorite(item) } label: {
                Image(systemName: item.isFavorite ? "star.fill" : "star")
            }
            .buttonStyle(PanelToolbarButtonStyle(isSelected: item.isFavorite, tint: PanelTheme.favorite))
            .help(item.isFavorite ? "取消收藏" : "收藏")
            .accessibilityLabel(item.isFavorite ? "取消收藏" : "收藏")
            if item.kind == .text {
                Button { model.isPreviewEditing.toggle() } label: {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(PanelToolbarButtonStyle(isSelected: model.isPreviewEditing))
                .help(model.isPreviewEditing ? "结束编辑（草稿会保留）" : "编辑文本")
                .accessibilityLabel(model.isPreviewEditing ? "结束编辑" : "编辑文本")
            } else if item.kind == .image {
                Button { model.imageEditorItem = item } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .buttonStyle(PanelToolbarButtonStyle())
                .help("编辑图片")
                .accessibilityLabel("编辑图片")
            }
        }
        .padding(.horizontal, 17)
        .frame(height: 58)
    }

    private func detailFooter(_ item: ClipboardItem) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                SourceAppBadge(bundleIdentifier: item.sourceAppBundleIdentifier)
                Text("·")
                Text(ClipboardTimestampFormatter.display(item.createdAt, relativeTo: model.timestampReferenceDate))
                    .help(ClipboardTimestampFormatter.full(item.createdAt))
            }
            .font(PanelTheme.captionFont)
            .foregroundStyle(PanelTheme.secondary)
            .lineLimit(1)
            Spacer(minLength: 4)
            if item.kind == .text, model.isPreviewEditing {
                Button("还原") { model.discardDraft(for: item) }
                    .buttonStyle(PanelToolbarButtonStyle())
                    .disabled(!hasDraft(item))
                Button("保存") { model.saveText(id: item.id, text: model.draftText(for: item)) }
                    .buttonStyle(PanelToolbarButtonStyle(isProminent: true))
                    .disabled(!hasDraft(item) || model.draftText(for: item).isEmpty)
                    .keyboardShortcut("s", modifiers: .command)
            } else {
                if item.kind == .text, hasDraft(item) {
                    Button("继续编辑") { model.isPreviewEditing = true }
                        .buttonStyle(PanelToolbarButtonStyle())
                }
                Button { model.copy(item, autoPaste: false) } label: {
                    Label("复制", systemImage: "doc.on.doc")
                }
                .buttonStyle(PanelToolbarButtonStyle())
                .help("仅复制（⌘C）")
                .accessibilityLabel("仅复制")
                Button { model.paste(item) } label: { Label("粘贴", systemImage: "return") }
                    .buttonStyle(PanelToolbarButtonStyle(isProminent: true))
                    .help("粘贴到原应用")
                    .accessibilityLabel("粘贴到原应用")
            }
        }
        .padding(.horizontal, 17)
        .frame(height: PanelTheme.previewFooterHeight)
        .animation(reduceMotion ? nil : PanelMotion.feedback, value: model.isPreviewEditing)
    }

    private func hasDraft(_ item: ClipboardItem) -> Bool {
        model.draftText(for: item) != (item.text ?? "")
    }
}

private struct TextDetailView: View {
    @Bindable var model: AppModel
    let item: ClipboardItem

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "text.alignleft")
                Text(model.isPreviewEditing ? "编辑文本" : "纯文本")
                Text("·")
                Text("\(displayedText.count.formatted()) 字符").monospacedDigit()
                Spacer(minLength: 4)
                if hasDraft {
                    Circle().fill(PanelTheme.favorite).frame(width: 5, height: 5)
                    Text("未保存").help("关闭明细后草稿仍会保留")
                }
            }
            .font(PanelTheme.captionFont)
            .foregroundStyle(PanelTheme.muted)
            .padding(.horizontal, PanelTheme.readingInset)
            .padding(.top, 26)
            .padding(.bottom, 18)
            PreviewTextSurface(text: Binding(
                get: { model.isPreviewEditing ? model.draftText(for: item) : item.text ?? "" },
                set: { model.updateDraft(id: item.id, text: $0) }
            ), isEditable: model.isPreviewEditing)
            .padding(.bottom, 24)
        }
    }

    private var displayedText: String { model.isPreviewEditing ? model.draftText(for: item) : item.text ?? "" }
    private var hasDraft: Bool { model.draftText(for: item) != (item.text ?? "") }
}

/// Reading and editing share one NSTextView so insets, wrapping and selection remain stable.
struct PreviewTextSurface: NSViewRepresentable {
    @Binding var text: String
    let isEditable: Bool

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        let view = NSTextView()
        view.delegate = context.coordinator
        view.textStorage?.delegate = context.coordinator
        context.coordinator.textView = view
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: PanelTheme.readingInset, height: 2)
        view.textContainer?.lineFragmentPadding = 0
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.font = .systemFont(ofSize: 15)
        view.textColor = PanelTheme.inkColor
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 6
        paragraph.paragraphSpacing = 2
        view.defaultParagraphStyle = paragraph
        view.typingAttributes = PreviewTextTypography.bodyAttributes
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        // Do not replace a live IME composition or reset the caret after ordinary typing.
        if view.string != text, !view.hasMarkedText() {
            context.coordinator.isUpdatingFromModel = true
            context.coordinator.changeGeneration += 1
            defer { context.coordinator.isUpdatingFromModel = false }
            let selection = view.selectedRange()
            let origin = scroll.contentView.bounds.origin
            view.string = text
            PreviewTextTypography.apply(to: view)
            let location = min(selection.location, view.string.utf16.count)
            view.setSelectedRange(NSRange(location: location, length: min(selection.length, view.string.utf16.count - location)))
            scroll.contentView.scroll(to: origin)
            scroll.reflectScrolledClipView(scroll.contentView)
            view.undoManager?.removeAllActions()
        }
        if view.isEditable != isEditable {
            view.isEditable = isEditable
            if isEditable {
                DispatchQueue.main.async { [weak view] in
                    guard let view, view.isEditable, view.window?.isKeyWindow == true else { return }
                    view.window?.makeFirstResponder(view)
                }
            }
        }
        if view.textColor != PanelTheme.inkColor { view.textColor = PanelTheme.inkColor }
        view.insertionPointColor = PanelTheme.accentColor
        view.setAccessibilityLabel(isEditable ? "文本编辑器" : "文本预览")
    }

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var parent: PreviewTextSurface
        weak var textView: NSTextView?
        var isUpdatingFromModel = false
        var changeGeneration = 0
        init(parent: PreviewTextSurface) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView, parent.isEditable else { return }
            if !view.hasMarkedText() { PreviewTextTypography.apply(to: view) }
            if parent.text != view.string { parent.text = view.string }
        }

        func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
            guard editedMask.contains(.editedCharacters), !isUpdatingFromModel, parent.isEditable else { return }
            changeGeneration += 1
            let generation = changeGeneration
            // NSTextStorage also reports undo/redo changes when NSTextView does not
            // send textDidChange. Publish after native editing finishes, outside render.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.changeGeneration == generation, self.parent.isEditable,
                      let view = self.textView, self.parent.text != view.string else { return }
                if !view.hasMarkedText() { PreviewTextTypography.apply(to: view) }
                self.parent.text = view.string
            }
        }
    }
}

/// Typography is presentation only: the full plain text stays selectable and editable.
enum PreviewTextTypography {
    static var bodyAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 6
        paragraph.paragraphSpacing = 2
        return [.font: NSFont.systemFont(ofSize: 15), .paragraphStyle: paragraph,
                .foregroundColor: PanelTheme.inkColor]
    }

    static func headingRange(in text: String) -> NSRange? {
        let string = text as NSString
        guard string.length > 0 else { return nil }
        let firstLine = string.lineRange(for: NSRange(location: 0, length: 0))
        guard NSMaxRange(firstLine) < string.length else { return nil }
        let title = string.substring(with: firstLine).trimmingCharacters(in: .newlines)
        let rest = string.substring(from: NSMaxRange(firstLine))
        guard (2...60).contains(title.count), rest.first?.isNewline == true,
              !title.hasPrefix(" "), !title.hasPrefix("\t"),
              !title.contains("://"), !title.contains("="), !title.contains("{"),
              !title.hasPrefix("#"), !title.hasPrefix("`"), !title.hasPrefix("$") else { return nil }
        return firstLine
    }

    static func apply(to view: NSTextView) {
        guard let storage = view.textStorage, !view.hasMarkedText() else { return }
        storage.beginEditing()
        storage.setAttributes(bodyAttributes, range: NSRange(location: 0, length: storage.length))
        if let heading = headingRange(in: view.string) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 2
            paragraph.paragraphSpacing = 8
            let font = NSFont.systemFont(ofSize: 21, weight: .medium)
            storage.addAttributes([.font: font, .paragraphStyle: paragraph], range: heading)
        }
        storage.endEditing()
        view.typingAttributes = bodyAttributes
    }
}

private struct ImageDetailView: View {
    let model: AppModel
    let item: ClipboardItem
    @State private var image: NSImage?
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                ImagePreviewCanvas()
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(24)
                } else if isLoading {
                    ProgressView("正在读取图片…")
                } else {
                    ContentUnavailableView("图片不可用", systemImage: "photo.badge.exclamationmark", description: Text("原始图片文件可能已丢失"))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: PanelTheme.radius))
            .overlay(RoundedRectangle(cornerRadius: PanelTheme.radius).strokeBorder(PanelTheme.border))
            .padding(.horizontal, PanelTheme.contentInset)
            .padding(.top, 16)
            .padding(.bottom, 16)
            PanelSeparator()
            HStack {
                if let image, let dimensions = image.previewPixelDimensions {
                    Label("\(dimensions.width) × \(dimensions.height) px", systemImage: "aspectratio")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: Int64(item.contentBytes), countStyle: .file))
                    .font(PanelTheme.captionFont)
                    .foregroundStyle(PanelTheme.muted)
            }
            .padding(.horizontal, PanelTheme.contentInset)
            .frame(height: PanelTheme.footerHeight)
        }
        .task(id: item.imageFileName) {
            isLoading = true
            image = nil
            guard let url = model.assetURL(for: item) else { isLoading = false; return }
            let loaded = await Task.detached(priority: .userInitiated) { NSImage(contentsOf: url) }.value
            guard !Task.isCancelled else { return }
            image = loaded
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
            PanelSeparator()
            ScrollView {
                LazyVStack(spacing: 8) {
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
                .padding(PanelTheme.contentInset)
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
                .foregroundStyle(report.unavailableCount == 0 ? PanelTheme.success : Color.orange)
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
            .buttonStyle(PanelToolbarButtonStyle())
            .disabled(isChecking)
            .help("重新检查文件状态")
            .accessibilityLabel("重新检查文件状态")
        }
        .font(.caption)
        .padding(.horizontal, PanelTheme.contentInset)
        .frame(height: PanelTheme.footerHeight)
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
                    .truncationMode(.middle)
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
                .buttonStyle(PanelToolbarButtonStyle())
                .help("在 Finder 中显示")
                .accessibilityLabel("在 Finder 中显示")
            } else {
                Button("重新定位…") { chooseReplacement(for: entry) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .background(PanelTheme.chrome, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(PanelTheme.border))
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
        case .available: PanelTheme.success
        case .missing: .red
        case .volumeUnavailable, .authorizationRequired: .orange
        }
    }
}
