import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var storage: StorageManager
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var localization: LocalizationManager
    @State private var itemPendingDeletion: MediaItem?
    @State private var isConfirmingDeleteAll = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    languageSection
                    saveLocationSection
                    recordsSection
                }
                .padding(24)
            }
        }
        .frame(minWidth: 720, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { storage.refreshItems() }
        .confirmationDialog(
            localization.string("删除这条记录和对应文件？"),
            isPresented: Binding(
                get: { itemPendingDeletion != nil },
                set: { if !$0 { itemPendingDeletion = nil } }
            )
        ) {
            Button(localization.string("删除"), role: .destructive) {
                if let itemPendingDeletion { storage.delete(itemPendingDeletion) }
                itemPendingDeletion = nil
            }
            Button(localization.string("取消"), role: .cancel) { itemPendingDeletion = nil }
        } message: {
            Text(itemPendingDeletion?.filename ?? "")
        }
        .confirmationDialog(localization.string("清空所有拍摄记录？"), isPresented: $isConfirmingDeleteAll) {
            Button(localization.string("全部删除"), role: .destructive) { storage.deleteAll() }
            Button(localization.string("取消"), role: .cancel) {}
        } message: {
            Text(localization.string("这会删除列表中的所有 JPG 和 MP4 文件，操作无法撤销。"))
        }
    }

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("界面语言")
            HStack(spacing: 14) {
                Image(systemName: "globe")
                    .font(.title2)
                    .foregroundStyle(.purple)
                    .frame(width: 42, height: 42)
                    .background(.purple.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 4) {
                    Text(localization.string("语言"))
                        .font(.body.weight(.medium))
                    Text(localization.string("默认跟随系统语言，也可以单独为 OpenCamara 选择语言。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker(localization.string("语言"), selection: $localization.language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .labelsHidden()
                .frame(width: 150)
            }
            .padding(16)
            .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(localization.string("设置"))
                    .font(.title2.weight(.semibold))
                Text(localization.string("管理保存位置和拍摄记录"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(localization.string("完成")) { dismiss() }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
        }
        .padding(24)
    }

    private var saveLocationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("保存位置")
            HStack(spacing: 14) {
                Image(systemName: "folder.fill")
                    .font(.title2)
                    .foregroundStyle(.blue)
                    .frame(width: 42, height: 42)
                    .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 4) {
                    Text(storage.baseURL?.lastPathComponent ?? localization.string("尚未设置"))
                        .font(.body.weight(.medium))
                    Text(storage.locationDisplayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button(localization.string("更改…")) { storage.chooseSaveFolder() }
            }
            .padding(16)
            .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
            Text(localization.string("每次拍摄会自动保存到“年-月-日”子文件夹；这个选择会被记住。"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var recordsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle(verbatim: localization.format("拍摄记录 · %d", storage.items.count))
                Spacer()
                Button(localization.string("清空全部"), role: .destructive) { isConfirmingDeleteAll = true }
                    .disabled(storage.items.isEmpty)
            }

            if storage.items.isEmpty {
                ContentUnavailableView(
                    localization.string("还没有拍摄记录"),
                    systemImage: "photo.on.rectangle.angled",
                    description: Text(localization.string("拍摄的照片和录像会显示在这里。"))
                )
                .frame(maxWidth: .infinity, minHeight: 220)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(storage.items) { item in
                        recordRow(item)
                        if item.id != storage.items.last?.id { Divider().padding(.leading, 60) }
                    }
                }
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    private func recordRow(_ item: MediaItem) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(item.kind == .photo ? Color.blue.opacity(0.12) : Color.red.opacity(0.12))
                Image(systemName: item.kind.systemImage)
                    .foregroundStyle(item.kind == .photo ? .blue : .red)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.filename)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text("\(item.formattedDate) · \(item.formattedSize)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                storage.reveal(item)
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help(localization.string("在访达中显示"))

            Button(role: .destructive) {
                itemPendingDeletion = item
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help(localization.string("删除记录和文件"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func sectionTitle(_ key: String) -> some View {
        Text(localization.string(key))
            .font(.headline)
    }

    private func sectionTitle(verbatim title: String) -> some View {
        Text(title)
            .font(.headline)
    }
}
