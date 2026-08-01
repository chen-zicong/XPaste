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
                Button("保存") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(operations.isEmpty || isSaving || isRendering)
            }
            .padding(16)

            Divider()

            ZStack {
                Color(nsColor: .windowBackgroundColor)
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

            Divider()

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
            .buttonStyle(.bordered)
            .padding(14)
        }
        .frame(width: 720, height: 530)
        .task { load() }
    }

    private func load() {
        guard let url = model.assetURL(for: item), let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
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
        guard let originalData else { return }
        if operations.isEmpty {
            previewImage = NSImage(data: originalData)
            isRendering = false
            return
        }
        let requested = operations
        isRendering = true
        Task {
            let result = try? await ImageProcessor.edit(originalData, operations: requested)
            guard requested == operations else { return }
            previewImage = result.flatMap { NSImage(data: $0.pngData) }
            isRendering = false
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
