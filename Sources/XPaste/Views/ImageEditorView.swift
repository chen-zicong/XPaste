import AppKit
import SwiftUI
import XPasteCore

struct ImageEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let model: AppModel
    let item: ClipboardItem
    @State private var originalData: Data?
    @State private var previewImage: NSImage?
    @State private var operations: [ImageEditOperation] = []
    @State private var isRendering = true
    @State private var isSaving = false
    @State private var previewTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("编辑图片").font(.title3.weight(.semibold))
                    Text("旋转、翻转或居中裁剪；保存后会更新当前记录。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(PanelToolbarButtonStyle())
                Button("保存") { save() }
                    .buttonStyle(PanelToolbarButtonStyle(isProminent: true))
                    .disabled(operations.isEmpty || isSaving || isRendering)
            }
            .padding(.horizontal, PanelTheme.contentInset)
            .padding(.vertical, 16)

            PanelSeparator()

            ZStack {
                ImagePreviewCanvas()
                if let previewImage {
                    Image(nsImage: previewImage)
                        .resizable()
                        .scaledToFit()
                        .padding(24)
                } else if isRendering {
                    ProgressView("正在准备预览…")
                } else {
                    ContentUnavailableView("无法打开图片", systemImage: "photo.badge.exclamationmark")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            PanelSeparator()

            HStack(spacing: 10) {
                EditButton(title: "左转", icon: "rotate.left") { add(.rotateLeft) }
                EditButton(title: "右转", icon: "rotate.right") { add(.rotateRight) }
                EditButton(title: "水平翻转", icon: "arrow.left.and.right.righttriangle.left.righttriangle.right") { add(.flipHorizontal) }
                EditButton(title: "正方形裁剪", icon: "crop") { add(.cropSquare) }

                Divider().frame(height: 22)

                Button { undo() } label: { Label("撤销", systemImage: "arrow.uturn.backward") }
                    .disabled(operations.isEmpty || isRendering)
                Button("还原") { operations = []; renderPreview() }
                    .disabled(operations.isEmpty || isRendering)

                Spacer()

                if !operations.isEmpty {
                    Text("\(operations.count) 步编辑")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if isRendering || isSaving { ProgressView().controlSize(.small) }
            }
            .buttonStyle(PanelToolbarButtonStyle())
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 720, height: 530)
        .background(PanelTheme.canvas)
        .tint(PanelTheme.accent)
        .task { await load() }
        .onDisappear { previewTask?.cancel() }
    }

    private func load() async {
        guard let url = model.assetURL(for: item),
              let data = try? await Task.detached(priority: .userInitiated, operation: {
                  try Data(contentsOf: url, options: .mappedIfSafe)
              }).value, !Task.isCancelled else {
            isRendering = false
            return
        }
        originalData = data
        previewImage = NSImage(data: data)
        isRendering = false
    }

    private func add(_ operation: ImageEditOperation) {
        operations.append(operation)
        renderPreview()
    }

    private func undo() {
        guard !operations.isEmpty else { return }
        operations.removeLast()
        renderPreview()
    }

    private func renderPreview() {
        previewTask?.cancel()
        guard let originalData else { return }
        if operations.isEmpty {
            previewImage = NSImage(data: originalData)
            isRendering = false
            return
        }
        let requested = operations
        isRendering = true
        previewTask = Task {
            do {
                let result = try await ImageProcessor.edit(originalData, operations: requested)
                guard !Task.isCancelled, requested == operations else { return }
                previewImage = NSImage(data: result.pngData)
                isRendering = false
            } catch is CancellationError {
                // A newer preview owns the loading state.
            } catch {
                guard !Task.isCancelled, requested == operations else { return }
                isRendering = false
                model.showToast(error.localizedDescription)
            }
        }
    }

    private func save() {
        guard !operations.isEmpty else { return }
        isSaving = true
        Task {
            if await model.saveImageEdits(item: item, operations: operations) { dismiss() }
            isSaving = false
        }
    }
}

private struct EditButton: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
        }
        .help(title)
    }
}
