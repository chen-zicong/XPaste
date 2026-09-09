import AppKit
import Foundation
import Observation
import XPasteCore

enum PanelPage: String, CaseIterable, Identifiable {
    case history
    case favorites
    case statistics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .history: "历史"
        case .favorites: "收藏"
        case .statistics: "统计"
        }
    }
}

@MainActor
@Observable
final class AppModel {
    let settings: AppSettings
    let repository: HistoryRepository

    var items: [ClipboardItem] = []
    private(set) var visibleItems: [ClipboardItem] = []
    var selectedID: UUID? {
        didSet {
            if oldValue != selectedID { isPreviewEditing = false }
            if selectedID == nil { isDetailVisible = false }
        }
    }
    var isPreviewEditing = false
    private(set) var selectionRevealToken = UUID()
    var query = "" { didSet { scheduleVisibleRefresh() } }
    var filter: ClipboardFilter = .all { didSet { scheduleVisibleRefresh(debounce: false) } }
    var page: PanelPage = .history {
        didSet {
            scheduleVisibleRefresh(
                debounce: false,
                resetSelection: oldValue != page,
                revealSelection: page != .statistics
            )
            if page == .statistics { isDetailVisible = false }
            if oldValue != page { onPanelLayoutChange?(page, isDetailVisible) }
        }
    }
    var isDetailVisible = false {
        didSet {
            if !isDetailVisible { isPreviewEditing = false }
            if oldValue != isDetailVisible { onPreviewVisibilityChange?() }
        }
    }
    var isPanelPinned = false {
        didSet {
            if oldValue != isPanelPinned { onPanelPinChange?(isPanelPinned) }
        }
    }
    var timestampReferenceDate = Date()
    var metadataBytes = 0
    var storageStatsSnapshot = StorageStats(items: [])
    var isLoading = true
    var isProcessingCapture = false
    var toastMessage: String?
    var errorMessage: String?
    var shortcutConflictMessage: String?
    var pasteboardAccessDenied = false
    var searchFocusToken = UUID()
    var imageEditorItem: ClipboardItem?
    var textDrafts: [UUID: String] = [:]
    var pendingDeletion: ClipboardItem?

    @ObservationIgnored var onCopyRequest: ((ClipboardItem, Bool) -> Void)?
    @ObservationIgnored var onHideRequest: (() -> Void)?
    @ObservationIgnored var onShowSettingsRequest: (() -> Void)?
    @ObservationIgnored var onPanelLayoutChange: ((PanelPage, Bool) -> Void)?
    @ObservationIgnored var onPreviewVisibilityChange: (() -> Void)?
    @ObservationIgnored var onPanelPinChange: ((Bool) -> Void)?

    @ObservationIgnored private var activeCaptures = 0
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var deletionTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var searchGeneration = 0
    @ObservationIgnored private var timestampTask: Task<Void, Never>?

    init(settings: AppSettings, repository: HistoryRepository) {
        self.settings = settings
        self.repository = repository
    }

    var selectedItem: ClipboardItem? {
        guard let selectedID else { return visibleItems.first }
        return visibleItems.first { $0.id == selectedID } ?? visibleItems.first
    }

    var stats: StorageStats {
        storageStatsSnapshot
    }

    func start(seedDemoData: Bool = false) async {
        startTimestampClock()
        do {
            let state = try await repository.load()
            apply(state)
            if seedDemoData, state.items.isEmpty {
                try await seedDemo()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func show(page: PanelPage, resetSelection: Bool = false) {
        timestampReferenceDate = Date()
        if self.page == page {
            scheduleVisibleRefresh(
                debounce: false,
                resetSelection: resetSelection,
                revealSelection: page != .statistics
            )
        } else {
            // The page observer resets selection to the destination's first
            // item. Keeping that rule in one place prevents left/right followed
            // by up/down from briefly navigating the previous page's list.
            self.page = page
        }
    }

    func focusSearch() {
        searchFocusToken = UUID()
    }

    func paste(_ item: ClipboardItem) {
        selectedID = item.id
        copy(item, autoPaste: true)
    }

    func select(_ item: ClipboardItem) {
        selectedID = item.id
    }

    func showDetails(for item: ClipboardItem? = nil) {
        if let item { selectedID = item.id }
        guard page != .statistics, selectedItem != nil else { return }
        isDetailVisible = true
    }

    func toggleDetails() {
        guard page != .statistics, selectedItem != nil else { return }
        isDetailVisible.toggle()
    }

    func togglePanelPinned() {
        isPanelPinned.toggle()
    }

    func selectNext(offset: Int) {
        let list = visibleItems
        guard !list.isEmpty else {
            selectedID = nil
            requestSelectionReveal()
            return
        }
        guard let selectedID, let current = list.firstIndex(where: { $0.id == selectedID }) else {
            self.selectedID = list[0].id
            return
        }
        let destination = list[min(max(0, current + offset), list.count - 1)].id
        if destination == selectedID {
            // At a boundary selectedID does not change. A dedicated reveal
            // request still brings the current row back after manual scrolling.
            requestSelectionReveal()
        } else {
            // A changed ID is already observed by the list. Do not emit a
            // second reveal request for the same key press.
            self.selectedID = destination
        }
    }

    func record(_ capture: ClipboardCapture) {
        let maxBytes = settings.maxCaptureMegabytes * 1_024 * 1_024
        let maxItems = settings.maxItems
        let capturedAt = Date()
        activeCaptures += 1
        isProcessingCapture = true
        Task {
            defer {
                activeCaptures -= 1
                isProcessingCapture = activeCaptures > 0
            }
            do {
                let payload: CapturePayload
                switch capture {
                case .text(let text, let sourceApp):
                    guard text.utf8.count <= maxBytes else {
                        showToast("文本超过 \(settings.maxCaptureMegabytes) MB，已跳过")
                        return
                    }
                    payload = CapturePayload(
                        kind: .text,
                        text: text,
                        contentHash: await Task.detached(priority: .utility) { ContentHasher.text(text) }.value,
                        sourceAppBundleIdentifier: sourceApp,
                        capturedAt: capturedAt
                    )
                case .files(let references, let sourceApp):
                    let paths = references.map(\.path)
                    payload = CapturePayload(
                        kind: .files,
                        filePaths: paths,
                        fileBookmarks: references.map(\.bookmarkData),
                        contentHash: await Task.detached(priority: .utility) { ContentHasher.files(paths) }.value,
                        sourceAppBundleIdentifier: sourceApp,
                        capturedAt: capturedAt
                    )
                case .image(let data, let sourceApp):
                    guard data.count <= maxBytes else {
                        showToast("图片超过 \(settings.maxCaptureMegabytes) MB，已跳过")
                        return
                    }
                    let processed = try await ImageProcessor.process(data)
                    guard processed.pngData.count <= maxBytes else {
                        showToast("图片编码后超过大小上限，已跳过")
                        return
                    }
                    payload = CapturePayload(
                        kind: .image,
                        imageData: processed.pngData,
                        thumbnailData: processed.thumbnailData,
                        imageUTI: "public.png",
                        contentHash: processed.contentHash,
                        sourceAppBundleIdentifier: sourceApp,
                        capturedAt: capturedAt
                    )
                }
                let state = try await repository.record(payload, maxItems: maxItems)
                apply(state, selectNewest: true)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func toggleFavorite(_ item: ClipboardItem) {
        Task {
            do {
                apply(try await repository.setFavorite(id: item.id, value: !item.isFavorite))
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func saveText(id: UUID, text: String) {
        guard !text.isEmpty else { return }
        Task {
            do {
                apply(try await repository.updateText(id: id, text: text))
                textDrafts[id] = nil
                if selectedID == id { isPreviewEditing = false }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func draftText(for item: ClipboardItem) -> String {
        textDrafts[item.id] ?? item.text ?? ""
    }

    func updateDraft(id: UUID, text: String) {
        textDrafts[id] = text
    }

    func discardDraft(for item: ClipboardItem) {
        textDrafts[item.id] = nil
    }

    func saveImageEdits(item: ClipboardItem, operations: [ImageEditOperation]) async -> Bool {
        guard let fileName = item.imageFileName else { return false }
        do {
            let url = repository.assetURL(fileName: fileName)
            let sourceData = try await Task.detached(priority: .userInitiated) {
                try Data(contentsOf: url, options: .mappedIfSafe)
            }.value
            let processed = try await ImageProcessor.edit(sourceData, operations: operations)
            let state = try await repository.updateImage(
                id: item.id,
                imageData: processed.pngData,
                thumbnailData: processed.thumbnailData,
                contentHash: processed.contentHash
            )
            apply(state)
            showToast("图片编辑已保存")
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func delete(_ item: ClipboardItem) {
        deletionTask?.cancel()
        if let previous = pendingDeletion, previous.id != item.id {
            Task { await permanentlyDelete(previous.id) }
        }
        pendingDeletion = item
        scheduleVisibleRefresh(debounce: false)
        showToast("已移到待删除", duration: 5)
        deletionTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            await permanentlyDelete(item.id)
        }
    }

    func undoDeletion() {
        guard let item = pendingDeletion else { return }
        deletionTask?.cancel()
        pendingDeletion = nil
        scheduleVisibleRefresh(debounce: false)
        selectedID = item.id
        showToast("已撤销删除")
    }

    func clearUnfavorited() {
        Task {
            do {
                apply(try await repository.clearUnfavorited())
                showToast("非收藏历史已清理")
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func enforceCurrentLimit() {
        Task {
            do { apply(try await repository.enforceLimit(settings.maxItems)) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func copy(_ item: ClipboardItem, autoPaste: Bool) {
        if isPreviewEditing, selectedID == item.id, draftText(for: item) != (item.text ?? "") {
            showToast("请先保存编辑，再复制或粘贴")
            return
        }
        onCopyRequest?(item, autoPaste)
    }

    func recordPasteEventSent(id: UUID) async {
        do {
            let state = try await repository.markUsed(id: id)
            apply(state)
            selectedID = id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshVisibleItemsForSettings() {
        scheduleVisibleRefresh(debounce: false)
    }

    func copySelected(autoPaste: Bool) {
        guard let selectedItem else { return }
        copy(selectedItem, autoPaste: autoPaste)
    }

    func assetURL(for item: ClipboardItem, thumbnail: Bool = false) -> URL? {
        let fileName = thumbnail ? item.thumbnailFileName : item.imageFileName
        return fileName.map(repository.assetURL(fileName:))
    }

    func fileResolutionReport(for item: ClipboardItem) async -> FileResolutionReport? {
        guard item.kind == .files else { return nil }
        do {
            let report = try await repository.resolveFileReferences(id: item.id)
            apply(try await repository.load())
            return report
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func replaceFileReference(itemID: UUID, index: Int, with URL: URL) async -> Bool {
        do {
            apply(try await repository.replaceFileReference(id: itemID, index: index, with: URL))
            selectedID = itemID
            showToast("文件引用已更新")
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func showToast(_ message: String, duration: Double = 2.2) {
        toastTask?.cancel()
        toastMessage = message
        toastTask = Task {
            try? await Task.sleep(for: .seconds(duration))
            if !Task.isCancelled { toastMessage = nil }
        }
    }

    private func apply(_ state: RepositoryState, selectNewest: Bool = false) {
        items = state.items
        metadataBytes = state.metadataBytes
        storageStatsSnapshot = state.storageStats
        searchGeneration += 1
        if selectNewest { selectedID = items.first?.id }
        scheduleVisibleRefresh(debounce: false)
    }

    private func ensureSelection() {
        let list = visibleItems
        if let selectedID, list.contains(where: { $0.id == selectedID }) { return }
        selectedID = list.first?.id
    }

    private func scheduleVisibleRefresh(
        debounce: Bool = true,
        resetSelection: Bool = false,
        revealSelection: Bool = false
    ) {
        searchTask?.cancel()
        let snapshot = items
        let query = query
        let filter = filter
        let favoritesOnly = page == .favorites
        let pendingID = pendingDeletion?.id
        let generation = searchGeneration

        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            visibleItems = orderedForDisplay(snapshot.filter {
                $0.id != pendingID && (!favoritesOnly || $0.isFavorite) && filter.includes($0)
            })
            updateSelection(resetToFirst: resetSelection)
            if revealSelection { requestSelectionReveal() }
            return
        }

        searchTask = Task {
            if debounce { try? await Task.sleep(for: .milliseconds(60)) }
            guard !Task.isCancelled else { return }
            let results = (try? await repository.search(
                query: query,
                favoritesOnly: favoritesOnly,
                filter: filter,
                sortOrder: settings.promotePastedItems ? .recentUse : .captureTime,
                limit: settings.maxItems
            )) ?? []
            guard !Task.isCancelled, generation == searchGeneration,
                  query == self.query, filter == self.filter,
                  favoritesOnly == (self.page == .favorites) else { return }
            visibleItems = orderedForDisplay(results.filter { $0.id != pendingID })
            updateSelection(resetToFirst: resetSelection)
            if revealSelection { requestSelectionReveal() }
        }
    }

    private func updateSelection(resetToFirst: Bool) {
        if resetToFirst {
            selectedID = visibleItems.first?.id
        } else {
            ensureSelection()
        }
    }

    private func requestSelectionReveal() {
        selectionRevealToken = UUID()
    }

    private func orderedForDisplay(_ items: [ClipboardItem]) -> [ClipboardItem] {
        ClipboardItemSorter.sorted(
            items,
            by: settings.promotePastedItems ? .recentUse : .captureTime
        )
    }

    private func startTimestampClock() {
        guard timestampTask == nil else { return }
        timestampTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, let self else { return }
                self.timestampReferenceDate = Date()
            }
        }
    }

    private func permanentlyDelete(_ id: UUID) async {
        do {
            let state = try await repository.delete(id: id)
            let wasCurrentPendingDeletion = pendingDeletion?.id == id
            if wasCurrentPendingDeletion { pendingDeletion = nil }
            textDrafts[id] = nil
            apply(state)
            if wasCurrentPendingDeletion { showToast("已删除") }
        } catch {
            if pendingDeletion?.id == id { pendingDeletion = nil }
            errorMessage = error.localizedDescription
            scheduleVisibleRefresh(debounce: false)
        }
    }

    private func seedDemo() async throws {
        let samples = [
            "欢迎使用 XPaste\n所有内容都只保存在这台 Mac 上。",
            "⌃⌥V 随时打开剪贴板历史，⌃⌥F 直接进入收藏。",
            "SwiftUI + AppKit · 原生、高效、低内存"
        ]
        for (index, text) in samples.enumerated() {
            let payload = CapturePayload(
                kind: .text,
                text: text,
                contentHash: ContentHasher.text(text),
                sourceAppBundleIdentifier: index == 0 ? "com.apple.Safari" : "com.apple.TextEdit",
                capturedAt: Date().addingTimeInterval(TimeInterval(-index * 180))
            )
            _ = try await repository.record(payload, maxItems: settings.maxItems)
        }
        let files = ["/Users/demo/Documents/项目提案.pdf", "/Users/demo/Desktop/灵感.png"]
        _ = try await repository.record(
            CapturePayload(kind: .files, filePaths: files, contentHash: ContentHasher.files(files), sourceAppBundleIdentifier: "com.apple.finder"),
            maxItems: settings.maxItems
        )
        apply(try await repository.load())
    }
}
