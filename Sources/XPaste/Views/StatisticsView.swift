import Darwin.Mach
import SwiftUI
import XPasteCore

struct StatisticsView: View {
    @Bindable var model: AppModel
    @State private var confirmCleanup = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("了解历史记录的存储与占用；文件引用不计入原文件体积。")
                    .font(PanelTheme.bodyFont)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    MetricCard(title: "应用数据", value: bytes(model.stats.totalBytes), icon: "internaldrive", tint: PanelTheme.accent)
                    MetricCard(title: "历史条目", value: "\(model.stats.totalItems)", icon: "clock", tint: PanelTheme.accent)
                    MetricCard(title: "收藏", value: "\(model.stats.favoriteItems)", icon: "star.fill", tint: PanelTheme.favorite)
                    MetricCard(title: "当前内存", value: bytes(residentMemory()), icon: "memorychip", tint: .secondary)
                }

                HStack(alignment: .top, spacing: 14) {
                    storageBreakdown
                    largestItems
                }

                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("清理非收藏历史").font(.headline)
                        Text("收藏内容不受清理和数量上限影响。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("清理…", role: .destructive) { confirmCleanup = true }
                        .disabled(model.items.allSatisfy(\.isFavorite))
                }
                .padding(16)
                .panelSurface()
            }
            .padding(PanelTheme.contentInset)
        }
        .background(PanelTheme.canvas)
        .confirmationDialog("清理所有非收藏历史？", isPresented: $confirmCleanup) {
            Button("清理非收藏内容", role: .destructive) { model.clearUnfavorited() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("文本、图片缩略图与原图都会从 XPaste 数据目录中删除，收藏内容会保留。")
        }
    }

    private var storageBreakdown: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("内容构成").font(.headline)
            StorageBar(label: "图片与缩略图", value: model.stats.imageBytes, total: model.stats.totalBytes, color: PanelTheme.imageTint, count: model.stats.imageItems)
            StorageBar(label: "文本", value: model.stats.textBytes, total: model.stats.totalBytes, color: PanelTheme.accent, count: model.stats.textItems)
            StorageBar(label: "文件引用", value: model.stats.fileReferenceBytes, total: model.stats.totalBytes, color: PanelTheme.fileTint, count: model.stats.fileItems)
            StorageBar(label: "SQLite 数据库", value: model.stats.databaseBytes, total: model.stats.totalBytes, color: .gray, count: nil)
            if model.stats.databaseSidecarBytes > 0 {
                StorageBar(label: "WAL / SHM", value: model.stats.databaseSidecarBytes, total: model.stats.totalBytes, color: .secondary, count: nil)
            }
            if model.stats.archiveBytes > 0 {
                StorageBar(label: "迁移 / 恢复备份", value: model.stats.archiveBytes, total: model.stats.totalBytes, color: .brown, count: nil)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSurface()
    }

    private var largestItems: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("占用最大的内容").font(.headline)
            ForEach(model.items.sorted { $0.storageBytes > $1.storageBytes }.prefix(5)) { item in
                HStack(spacing: 8) {
                    Image(systemName: item.kind == .image ? "photo" : item.kind == .text ? "text.alignleft" : "doc")
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text(item.title).lineLimit(1)
                    Spacer()
                    Text(bytes(item.storageBytes)).foregroundStyle(.secondary)
                }
                .font(.caption)
            }
            if model.items.isEmpty {
                Text("暂无内容").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSurface()
    }

    private func bytes(_ value: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
    }

    private func residentMemory() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.resident_size) : 0
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let icon: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
            Text(value).font(.system(size: 24, weight: .semibold)).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSurface()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title)，\(value)")
    }
}

private struct StorageBar: View {
    let label: String
    let value: Int
    let total: Int
    let color: Color
    let count: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label)
                if let count { Text("\(count) 条").foregroundStyle(.tertiary) }
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file))
            }
            .font(.caption)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.07))
                    Capsule().fill(color.gradient)
                        .frame(width: geometry.size.width * max(0.015, CGFloat(value) / CGFloat(max(1, total))))
                }
            }
            .frame(height: 7)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label)，\(count.map { "\($0) 条，" } ?? "")\(ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file))")
    }
}
