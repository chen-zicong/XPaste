import AppKit
import SwiftUI
import XPasteCore

struct ClipboardListView: View {
    @Bindable var model: AppModel
    @State private var revealTask: Task<Void, Never>?

    var body: some View {
        Group {
            if model.isLoading {
                ProgressView("正在加载历史…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.visibleItems.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 3) {
                            ForEach(model.visibleItems) { item in
                                ClipboardRow(model: model, item: item, isSelected: model.selectedID == item.id)
                                    .id(item.id)
                            }
                        }
                        .padding(6)
                    }
                    .onChange(of: model.selectedID) { _, id in
                        reveal(id, using: proxy)
                    }
                    .onChange(of: model.selectionRevealToken) { _, _ in
                        reveal(model.selectedID, using: proxy)
                    }
                    .onDisappear {
                        revealTask?.cancel()
                        revealTask = nil
                    }
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.34))
    }

    private func reveal(_ id: UUID?, using proxy: ScrollViewProxy) {
        guard let id else { return }
        // selectedID and selectionRevealToken often change in the same render
        // pass. Coalesce them into one minimal reveal instead of issuing two
        // competing centered animations that make arrow navigation jitter.
        revealTask?.cancel()
        revealTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            // With no anchor SwiftUI only scrolls as much as needed to reveal
            // an off-screen row. Avoid an explicit animation so rapid key
            // repeat cannot build up a queue of competing scroll animations.
            proxy.scrollTo(id)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: emptyIcon)
                .font(.system(size: 31, weight: .light))
                .foregroundStyle(.tertiary)
            Text(emptyTitle).font(.headline)
            Text(emptySubtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 220)
            if !model.query.isEmpty {
                Button("清除搜索") { model.query = "" }
            } else if model.page == .favorites {
                Button("返回历史") { model.show(page: .history) }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyIcon: String {
        if !model.query.isEmpty { return "magnifyingglass" }
        return model.page == .favorites ? "star" : "doc.on.clipboard"
    }

    private var emptyTitle: String {
        if !model.query.isEmpty { return "没有找到“\(model.query)”" }
        return model.page == .favorites ? "还没有收藏" : "剪贴板历史为空"
    }

    private var emptySubtitle: String {
        if !model.query.isEmpty { return "试试更短的关键词，或切换内容类型" }
        return model.page == .favorites ? "在历史记录中点亮星标，常用内容会一直保留" : "复制文本、图片或文件后，它们会自动出现在这里"
    }
}

private struct ClipboardRow: View {
    let model: AppModel
    let item: ClipboardItem
    let isSelected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            HStack(spacing: 10) {
                ItemThumbnail(model: model, item: item, size: thumbnailSize)

                VStack(alignment: .leading, spacing: 4) {
                    rowContent
                    HStack(spacing: 5) {
                        SourceAppBadge(bundleIdentifier: item.sourceAppBundleIdentifier)
                        if let usageTimestampLabel {
                            Text("\(usageTimestampLabel)使用")
                                .help("最近使用于 \(fullUsageTimestamp)")
                                .accessibilityLabel("最近使用于 \(fullUsageTimestamp)")
                            Text("·")
                        }
                        Text(timestampLabel)
                            .help("记录于 \(fullTimestamp)")
                            .accessibilityLabel("\(timestampLabel)；记录于 \(fullTimestamp)")
                        if item.kind != .text {
                            Text("·")
                            Text(ByteCountFormatter.string(fromByteCount: Int64(item.storageBytes), countStyle: .file))
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { model.paste(item) }
            .onTapGesture(count: 1) { model.select(item) }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("选择：\(item.kind.displayName)，\(item.title)")
            .accessibilityValue("\(item.previewText)，\(timestampLabel)，记录于 \(fullTimestamp)")
            .accessibilityAction { model.select(item) }
            .accessibilityAction(named: Text("粘贴到原应用")) {
                model.paste(item)
            }
            .accessibilityAction(named: Text("仅复制")) {
                model.copy(item, autoPaste: false)
            }
            .accessibilityAction(named: Text("显示详情")) {
                model.showDetails(for: item)
            }
            .accessibilityAction(named: Text(item.isFavorite ? "取消收藏" : "收藏")) {
                model.toggleFavorite(item)
            }

            HStack(spacing: 4) {
                Button { model.paste(item) } label: {
                    Image(systemName: "return")
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 24, height: 28)
                }
                .buttonStyle(.plain)
                .help("粘贴到原应用（Return / 双击）")
                .accessibilityLabel("粘贴到原应用")

                Button { model.toggleFavorite(item) } label: {
                    Image(systemName: item.isFavorite ? "star.fill" : "star")
                        .foregroundStyle(item.isFavorite ? .yellow : .secondary)
                        .frame(width: 24, height: 28)
                }
                .buttonStyle(.plain)
                .opacity(showsFavoriteAction ? 1 : 0)
                .allowsHitTesting(showsFavoriteAction)
                .accessibilityHidden(!showsFavoriteAction)
                .help(item.isFavorite ? "取消收藏" : "收藏")
                .accessibilityLabel(item.isFavorite ? "取消收藏" : "收藏")

                Button { model.showDetails(for: item) } label: {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 28)
                }
                .buttonStyle(.plain)
                .opacity(showsDetailAction ? 1 : 0)
                .allowsHitTesting(showsDetailAction)
                .accessibilityHidden(!showsDetailAction)
                .help("显示详情（空格 / ⌘I）")
                .accessibilityLabel("显示详情")
            }
            // Keep the trailing action width reserved at all times. Otherwise
            // selecting a long text item inserts two buttons, narrows its text
            // column and makes the row jump from one line to two.
            .frame(width: 84, alignment: .trailing)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, item.kind == .text ? 7 : 8)
        .frame(minHeight: item.kind == .text ? 48 : 62)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(alignment: .leading) {
            if isSelected {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 3)
                    .padding(.vertical, 8)
                    .padding(.leading, 2)
            }
        }
        .contentShape(Rectangle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .onHover { hovering = $0 }
        .contextMenu {
            Button("粘贴到原应用") { model.paste(item) }
            Button("仅复制") { model.copy(item, autoPaste: false) }
            Button("显示详情") { model.showDetails(for: item) }
            Divider()
            Button(item.isFavorite ? "取消收藏" : "收藏") { model.toggleFavorite(item) }
            if item.kind == .image { Button("编辑图片…") { model.imageEditorItem = item } }
            Divider()
            Button("删除", role: .destructive) { model.delete(item) }
        }
    }

    @ViewBuilder
    private var rowContent: some View {
        if item.kind == .text {
            Text(textDisplayValue)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .multilineTextAlignment(.leading)
        } else {
            Text(item.title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            if !item.previewText.isEmpty, item.previewText != item.title {
                Text(item.previewText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var textDisplayValue: String {
        let preview = item.previewText.trimmingCharacters(in: .whitespacesAndNewlines)
        return preview.isEmpty ? item.title : preview
    }

    private var thumbnailSize: CGFloat {
        item.kind == .text ? 30 : 42
    }

    private var rowBackground: Color {
        if isSelected { return Color.accentColor.opacity(0.11) }
        if hovering { return Color.primary.opacity(0.028) }
        return .clear
    }

    private var showsFavoriteAction: Bool {
        item.isFavorite || hovering || isSelected
    }

    private var showsDetailAction: Bool {
        hovering || isSelected
    }

    private var timestampLabel: String {
        ClipboardTimestampFormatter.display(item.createdAt, relativeTo: model.timestampReferenceDate)
    }

    private var fullTimestamp: String {
        ClipboardTimestampFormatter.full(item.createdAt)
    }

    private var usageTimestampLabel: String? {
        guard model.settings.promotePastedItems,
              item.lastUsedAt.timeIntervalSince(item.createdAt) >= 60 else { return nil }
        return ClipboardTimestampFormatter.display(
            item.lastUsedAt,
            relativeTo: model.timestampReferenceDate
        )
    }

    private var fullUsageTimestamp: String {
        ClipboardTimestampFormatter.full(item.lastUsedAt)
    }
}

struct ItemThumbnail: View {
    let model: AppModel
    let item: ClipboardItem
    let size: CGFloat
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.19, style: .continuous)
                .fill(backgroundColor)
            if item.kind == .image, let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.19, style: .continuous))
            } else {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.38, weight: .medium))
                    .foregroundStyle(foregroundColor)
            }
        }
        .frame(width: size, height: size)
        .overlay(RoundedRectangle(cornerRadius: size * 0.19).strokeBorder(Color.primary.opacity(0.07)))
        .task(id: item.thumbnailFileName) {
            guard item.kind == .image, let url = model.assetURL(for: item, thumbnail: true) else { return }
            image = await ThumbnailCache.shared.image(at: url)
        }
    }

    private var symbol: String {
        switch item.kind {
        case .text: "text.alignleft"
        case .image: "photo"
        case .files: "doc.on.doc.fill"
        }
    }

    private var backgroundColor: Color {
        switch item.kind {
        case .text: Color.primary.opacity(0.045)
        case .image: .purple.opacity(0.10)
        case .files: .orange.opacity(0.12)
        }
    }

    private var foregroundColor: Color {
        switch item.kind {
        case .text: .secondary
        case .image: .purple
        case .files: .orange
        }
    }
}

actor ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.totalCostLimit = 32 * 1_024 * 1_024
        cache.countLimit = 120
        return cache
    }()

    func image(at url: URL) -> NSImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        guard let image = NSImage(contentsOf: url) else { return nil }
        let cost = Int(max(1, image.size.width * image.size.height * 4))
        cache.setObject(image, forKey: url as NSURL, cost: cost)
        return image
    }

    func removeAll() {
        cache.removeAllObjects()
    }
}

private struct SourceAppBadge: View {
    let bundleIdentifier: String?

    var body: some View {
        if let bundleIdentifier, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 12, height: 12)
                .help(bundleIdentifier)
        } else {
            Image(systemName: "app")
                .frame(width: 12, height: 12)
        }
    }
}
