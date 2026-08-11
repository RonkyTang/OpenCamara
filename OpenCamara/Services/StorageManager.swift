import AppKit
import Foundation

@MainActor
final class StorageManager: ObservableObject {
    @Published private(set) var baseURL: URL?
    @Published private(set) var items: [MediaItem] = []
    @Published var errorMessage: String?

    private let bookmarkKey = "OpenCamara.saveFolderBookmark"
    private var isAccessingSecurityScopedURL = false

    var hasSaveLocation: Bool { baseURL != nil }
    var locationDisplayName: String { baseURL?.path(percentEncoded: false) ?? L10n.string("尚未设置") }

    init() {
        restoreSavedLocation()
    }

    @discardableResult
    func chooseSaveFolder() -> Bool {
        let panel = NSOpenPanel()
        panel.title = L10n.string("选择照片和录像的保存位置")
        panel.prompt = L10n.string("选择此文件夹")
        panel.message = L10n.string("OpenCamara 会在这里按日期创建文件夹。")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return false }

        do {
            try saveLocation(url)
            return true
        } catch {
            errorMessage = L10n.format("无法保存这个位置：%@", error.localizedDescription)
            return false
        }
    }

    func restoreSavedLocation() {
        guard let bookmarkData = UserDefaults.standard.data(forKey: bookmarkKey) else { return }

        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )

            beginAccessing(url)
            baseURL = url

            if isStale {
                try persistBookmark(for: url)
            }
            refreshItems()
        } catch {
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
            baseURL = nil
            errorMessage = L10n.string("原保存位置已失效，请重新选择。")
        }
    }

    func makeDestinationURL(for kind: MediaKind, date: Date = Date()) throws -> URL {
        guard let baseURL else { throw StorageError.locationNotSet }

        let dateFolder = Self.folderFormatter.string(from: date)
        let directoryURL = baseURL.appendingPathComponent(dateFolder, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let prefix = kind == .photo ? "Photo" : "Video"
        let timestamp = Self.filenameFormatter.string(from: date)
        return directoryURL
            .appendingPathComponent("\(prefix)_\(timestamp)")
            .appendingPathExtension(kind.fileExtension)
    }

    func refreshItems() {
        guard let baseURL else {
            items = []
            return
        }

        let keys: Set<URLResourceKey> = [.isRegularFileKey, .creationDateKey, .contentModificationDateKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: baseURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            items = []
            return
        }

        var discovered: [MediaItem] = []
        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            guard ext == "jpg" || ext == "mp4" else { continue }
            guard isManagedCaptureURL(url, kindExtension: ext) else { continue }

            do {
                let values = try url.resourceValues(forKeys: keys)
                guard values.isRegularFile == true else { continue }
                let kind: MediaKind = ext == "jpg" ? .photo : .video
                discovered.append(
                    MediaItem(
                        url: url,
                        kind: kind,
                        createdAt: values.creationDate ?? values.contentModificationDate ?? Date.distantPast,
                        byteCount: Int64(values.fileSize ?? 0)
                    )
                )
            } catch {
                continue
            }
        }

        items = discovered.sorted { $0.createdAt > $1.createdAt }
    }

    func delete(_ item: MediaItem) {
        guard isInsideSaveLocation(item.url) else {
            errorMessage = L10n.string("无法删除保存位置之外的文件。")
            return
        }

        do {
            try FileManager.default.removeItem(at: item.url)
            removeFolderIfEmpty(item.url.deletingLastPathComponent())
            items.removeAll { $0.id == item.id }
        } catch {
            errorMessage = L10n.format("删除失败：%@", error.localizedDescription)
        }
    }

    func deleteAll() {
        let existingItems = items
        var firstError: Error?

        for item in existingItems where isInsideSaveLocation(item.url) {
            do {
                try FileManager.default.removeItem(at: item.url)
                removeFolderIfEmpty(item.url.deletingLastPathComponent())
            } catch {
                firstError = firstError ?? error
            }
        }

        refreshItems()
        if let firstError {
            errorMessage = L10n.format("部分文件未能删除：%@", firstError.localizedDescription)
        }
    }

    func reveal(_ item: MediaItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    private func saveLocation(_ url: URL) throws {
        if isAccessingSecurityScopedURL {
            baseURL?.stopAccessingSecurityScopedResource()
            isAccessingSecurityScopedURL = false
        }

        beginAccessing(url)
        try persistBookmark(for: url)
        baseURL = url
        refreshItems()
    }

    private func persistBookmark(for url: URL) throws {
        let bookmark = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
    }

    private func beginAccessing(_ url: URL) {
        isAccessingSecurityScopedURL = url.startAccessingSecurityScopedResource()
    }

    private func isInsideSaveLocation(_ url: URL) -> Bool {
        guard let baseURL else { return false }
        let basePath = baseURL.standardizedFileURL.path + "/"
        return url.standardizedFileURL.path.hasPrefix(basePath)
    }

    private func isManagedCaptureURL(_ url: URL, kindExtension: String) -> Bool {
        guard let baseURL else { return false }
        let expectedPrefix = kindExtension == "jpg" ? "Photo_" : "Video_"
        guard url.deletingPathExtension().lastPathComponent.hasPrefix(expectedPrefix) else { return false }

        let dateFolderURL = url.deletingLastPathComponent()
        guard dateFolderURL.deletingLastPathComponent().standardizedFileURL == baseURL.standardizedFileURL else {
            return false
        }

        let folderName = dateFolderURL.lastPathComponent
        guard folderName.count == 10,
              let date = Self.folderFormatter.date(from: folderName),
              Self.folderFormatter.string(from: date) == folderName else {
            return false
        }
        return true
    }

    private func removeFolderIfEmpty(_ directory: URL) {
        guard let baseURL, directory.standardizedFileURL != baseURL.standardizedFileURL else { return }
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: directory.path), contents.isEmpty else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    private static let folderFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let filenameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss_SSS"
        return formatter
    }()
}

private enum StorageError: LocalizedError {
    case locationNotSet

    var errorDescription: String? {
        L10n.string("请先设置保存位置。")
    }
}
