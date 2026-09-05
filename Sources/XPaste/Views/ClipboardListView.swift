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
                        LazyVStack(spacing: 4) {
                            ForEach(model.visibleItems) { item in
                                ClipboardRow(model: model, item: item, isSelected: model.selectedID == item.id)
                                    .id(item.id)
                            }
                        }
                        .padding(.horizontal, PanelTheme.rowInset)
                        .padding(.top, 1)
                        .padding(.bottom, 12)
                    }
                    .onAppear { reveal(model.selectedID, using: proxy) }
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
        VStack(spacing: 8) {
            Image(systemName: emptyIcon)
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(PanelTheme.accent)
                .frame(width: 48, height: 48)
                .background(PanelTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                .padding(.bottom, 4)
            Text(emptyTitle).font(.headline).lineLimit(2)
            Text(emptySubtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 240)
                .fixedSize(horizontal: false, vertical: true)
            if !model.query.isEmpty {
                Button("清除搜索") { model.query = "" }
            } else if model.page == .favorites {
                Button("返回历史") { model.show(page: .history) }
            }
        }
        .buttonStyle(PanelToolbarButtonStyle(isSelected: true))
        .padding(16)
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
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hovering = false
    @State private var isTrackingPrimaryPress = false

    var body: some View {
        HStack(spacing: 7) {
            HStack(spacing: 10) {
                ItemThumbnail(model: model, item: item, size: thumbnailSize, isSelected: usesAccentSelection)

                VStack(alignment: .leading, spacing: 3) {
                    rowContent
                    HStack(spacing: 5) {
                        SourceAppBadge(bundleIdentifier: item.sourceAppBundleIdentifier, showsIcon: false)
                        Text("·")
                        Text(item.kind.displayName)
                        if let usageTimestampLabel {
                            Text("· \(usageTimestampLabel)使用")
                                .help("最近使用于 \(fullUsageTimestamp)")
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(secondaryColor)
                    .lineLimit(1)
                }

                Spacer(minLength: 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { model.paste(item) }
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

            VStack(alignment: .trailing, spacing: 2) {
                Text(listTimestamp.primary)
                if let time = listTimestamp.secondary {
                    Text(time).foregroundStyle(PanelTheme.muted)
                }
            }
            .font(.system(size: 11))
            .lineLimit(1)
            .monospacedDigit()
            .foregroundStyle(secondaryColor)
            .fixedSize(horizontal: true, vertical: true)
            .frame(width: 76, alignment: .trailing)
            .help("记录于 \(fullTimestamp)")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("记录于 \(fullTimestamp)")

            HStack(spacing: 4) {
                Button { model.toggleFavorite(item) } label: {
                    Image(systemName: item.isFavorite ? "star.fill" : "star")
                        .foregroundStyle(item.isFavorite ? PanelTheme.favorite : secondaryColor)
                        .frame(width: 24, height: 28)
                }
                .buttonStyle(.plain)
                .opacity(showsFavoriteAction ? 1 : 0)
                .allowsHitTesting(showsFavoriteAction)
                .accessibilityHidden(!showsFavoriteAction)
                .help(item.isFavorite ? "取消收藏" : "收藏")
                .accessibilityLabel(item.isFavorite ? "取消收藏" : "收藏")


            }
            // Keep the trailing action width reserved at all times. Otherwise
            // selecting a long text item inserts a button, narrows its text
            // column and makes the row jump from one line to two.
            .frame(width: 28, alignment: .trailing)
        }
        .padding(.horizontal, PanelTheme.rowInset)
        .padding(.vertical, 8)
        .frame(height: PanelTheme.rowHeight)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isSelected ? (contrast == .increased ? Color.primary.opacity(0.4) : PanelTheme.selectionBorder) : Color.clear)
        }
        .contentShape(Rectangle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !isTrackingPrimaryPress else { return }
                    isTrackingPrimaryPress = true
                    model.select(item)
                }
                .onEnded { _ in
                    isTrackingPrimaryPress = false
                }
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        // Hover reveals actions without drawing a second, competing selection
        // or leaving an animated trail when the pointer crosses several rows.
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

    private var rowContent: some View {
        Text(item.kind == .text ? textDisplayValue : item.kind == .files && !item.previewText.isEmpty ? item.previewText : item.title)
            .font(.system(size: 13, weight: isSelected ? .medium : .regular))
            .foregroundStyle(PanelTheme.ink)
            .lineLimit(1)
            .truncationMode(.tail)
            .multilineTextAlignment(.leading)
    }

    private var usesAccentSelection: Bool { isSelected }

    private var secondaryColor: Color {
        PanelTheme.secondary
    }

    private var textDisplayValue: String {
        item.title
    }

    private var thumbnailSize: CGFloat {
        30
    }

    private var rowBackground: Color {
        if isSelected { return PanelTheme.selection }
        return .clear
    }

    private var showsFavoriteAction: Bool {
        item.isFavorite || hovering || isSelected
    }

    private var timestampLabel: String {
        ClipboardTimestampFormatter.display(item.createdAt, relativeTo: model.timestampReferenceDate)
    }

    private var listTimestamp: (primary: String, secondary: String?) {
        ClipboardTimestampFormatter.listLabel(item.createdAt, relativeTo: model.timestampReferenceDate)
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
    var isSelected = false
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.19, style: .continuous)
                .fill(item.kind == .image ? PanelTheme.chrome : Color.clear)
            if item.kind == .image, let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.19, style: .continuous))
            } else {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.48, weight: .regular))
                    .foregroundStyle(isSelected ? PanelTheme.accent : PanelTheme.muted)
            }
        }
        .frame(width: size, height: size)
        .task(id: item.thumbnailFileName) {
            guard item.kind == .image, let url = model.assetURL(for: item, thumbnail: true) else { return }
            image = await ThumbnailCache.shared.image(at: url)
        }
    }

    private var symbol: String {
        switch item.kind {
        case .text: "text.alignleft"
        case .image: "photo"
        case .files: "doc.on.doc"
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

struct SourceAppBadge: View {
    let bundleIdentifier: String?
    var showsIcon = true
    @State private var source: SourceApplication?

    var body: some View {
        HStack(spacing: 4) {
            if let source {
                if showsIcon {
                    Image(nsImage: source.icon)
                        .resizable()
                        .frame(width: 12, height: 12)
                } else {
                    Circle().fill(PanelTheme.muted.opacity(0.65)).frame(width: 4, height: 4)
                }
                Text(source.name)
                    .lineLimit(1)
            } else {
                if showsIcon {
                    Image(systemName: "app").frame(width: 12, height: 12)
                } else {
                    Circle().fill(PanelTheme.muted.opacity(0.65)).frame(width: 4, height: 4)
                }
                Text("应用")
            }
        }
        .help(source?.name ?? "来源应用")
        .task(id: bundleIdentifier) {
            source = SourceApplicationCache.application(for: bundleIdentifier)
        }
    }
}

private struct SourceApplication {
    let name: String
    let icon: NSImage
}

@MainActor
private enum SourceApplicationCache {
    private static var applications: [String: SourceApplication] = [:]

    static func application(for bundleIdentifier: String?) -> SourceApplication? {
        guard let bundleIdentifier else { return nil }
        if let cached = applications[bundleIdentifier] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return nil }
        let application = SourceApplication(
            name: FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""),
            icon: NSWorkspace.shared.icon(forFile: url.path)
        )
        if applications.count >= 100 { applications.removeAll() }
        applications[bundleIdentifier] = application
        return application
    }
}
