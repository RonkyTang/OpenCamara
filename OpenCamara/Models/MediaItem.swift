import Foundation

enum MediaKind: String, CaseIterable, Identifiable {
    case photo
    case video

    var id: String { rawValue }

    var title: String {
        switch self {
        case .photo: return L10n.string("拍照")
        case .video: return L10n.string("录像")
        }
    }

    var fileExtension: String {
        switch self {
        case .photo: return "jpg"
        case .video: return "mp4"
        }
    }

    var systemImage: String {
        switch self {
        case .photo: return "photo.fill"
        case .video: return "video.fill"
        }
    }
}

struct MediaItem: Identifiable, Hashable {
    let url: URL
    let kind: MediaKind
    let createdAt: Date
    let byteCount: Int64

    var id: String { url.standardizedFileURL.path }
    var filename: String { url.lastPathComponent }

    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.dateStyle = .long
        formatter.timeStyle = .medium
        return formatter.string(from: createdAt)
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }

}
