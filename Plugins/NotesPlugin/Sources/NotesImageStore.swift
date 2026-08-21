import AppKit
import Foundation
import MarkdownEngine
import NotchCenterKit

/// 笔记内嵌图片存储（官方 NotesPlugin）。
/// 图片文件存放在该插件的数据根目录下的 `Images/` 子目录（经 StateStore.resourceDirectory 获取），
/// manifest 记录在同一目录的 manifest.json 中。媒体文件不适合键值存储，
/// 键值 API 仍用于普通状态（文档 §4.6）。
final class NotesImageStore: EmbeddedImageFileProvider, @unchecked Sendable {
    private struct ImageAssetRecord: Codable {
        var id: String
        var displayName: String
        var storedFilename: String
        var originalPath: String?
        var sourceKind: String
        var createdAt: Date
    }

    private let directoryURL: URL
    private let manifestURL: URL
    private let lock = NSLock()
    private var records: [String: ImageAssetRecord]
    private var version = 0
    private let imageExtension = "png"

    /// 仅在主线程创建（由 NotesModel.resolve 调用）。
    init(stateStore: StateStore) throws {
        directoryURL = try MainActor.assumeIsolated {
            try stateStore.resourceDirectory(named: "Images")
        }
        manifestURL = directoryURL.appendingPathComponent("manifest.json")
        records = Self.loadRecords(from: manifestURL)
    }

    func saveImage(from pasteboard: NSPasteboard) -> String? {
        if let fileURL = PasteboardImageReader.imageFileURL(from: pasteboard),
           let data = try? Data(contentsOf: fileURL),
           NSImage(data: data) != nil {
            return save(
                data: pngData(fromImageData: data) ?? data,
                originalName: fileURL.deletingPathExtension().lastPathComponent,
                originalFileURL: fileURL,
                sourceKind: "file"
            )
        }

        guard let pngData = PasteboardImageReader.imageData(from: pasteboard) else {
            return nil
        }

        return save(
            data: pngData,
            originalName: "pasted-image",
            originalFileURL: nil,
            sourceKind: "clipboardImage"
        )
    }

    func image(for reference: EmbeddedImageRequest) -> NSImage? {
        let candidateNames = [reference.id, reference.name].compactMap { $0 }

        for candidateName in candidateNames {
            let url = imageURL(for: candidateName)
            if let image = NSImage(contentsOf: url) {
                return image
            }
        }

        return nil
    }

    func storedFileURL(for reference: EmbeddedImageRequest) -> URL? {
        guard let candidateName = recordCandidateNames(for: reference).first(where: { !$0.isEmpty }) else {
            return nil
        }

        lock.lock()
        let record = records[candidateName]
        lock.unlock()

        if let record {
            let url = directoryURL.appendingPathComponent(record.storedFilename)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }

        let fallbackURL = imageURL(for: candidateName)
        return FileManager.default.fileExists(atPath: fallbackURL.path) ? fallbackURL : nil
    }

    func originalFileURL(for reference: EmbeddedImageRequest) -> URL? {
        guard let candidateName = recordCandidateNames(for: reference).first(where: { !$0.isEmpty }) else {
            return nil
        }

        lock.lock()
        let path = records[candidateName]?.originalPath
        lock.unlock()

        guard let path else { return nil }
        let url = URL(fileURLWithPath: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func fingerprint() -> AnyHashable {
        lock.lock()
        defer { lock.unlock() }
        return version
    }

    private func save(data: Data, originalName: String, originalFileURL: URL?, sourceKind: String) -> String? {
        let displayName = sanitizedDisplayName(originalName)
        let id = UUID()
        let storedFilename = "\(id.uuidString).\(imageExtension)"
        let url = imageURL(for: id.uuidString)

        do {
            try data.write(to: url, options: .atomic)
            let record = ImageAssetRecord(
                id: id.uuidString,
                displayName: displayName,
                storedFilename: storedFilename,
                originalPath: originalFileURL?.path,
                sourceKind: sourceKind,
                createdAt: Date()
            )
            lock.lock()
            records[id.uuidString] = record
            let recordsToSave = records
            version += 1
            lock.unlock()
            saveRecords(recordsToSave)
            return "![[\(displayName)|\(id.uuidString)]]"
        } catch {
            return nil
        }
    }

    private func recordCandidateNames(for reference: EmbeddedImageRequest) -> [String] {
        [reference.id, reference.name].compactMap { $0 }
    }

    private func imageURL(for idOrName: String) -> URL {
        if idOrName.lowercased().hasSuffix(".\(imageExtension)") {
            return directoryURL.appendingPathComponent(idOrName)
        }

        return directoryURL.appendingPathComponent("\(idOrName).\(imageExtension)")
    }

    private func sanitizedDisplayName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = trimmed.isEmpty ? "pasted-image" : trimmed
        return fallback
            .replacingOccurrences(of: "|", with: "-")
            .replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private func pngData(fromImageData data: Data) -> Data? {
        guard let image = NSImage(data: data),
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }

        return bitmap.representation(using: .png, properties: [:])
    }

    private func saveRecords(_ records: [String: ImageAssetRecord]) {
        let sortedRecords = records.values.sorted { $0.createdAt < $1.createdAt }
        guard let data = try? JSONEncoder().encode(sortedRecords) else { return }
        try? data.write(to: manifestURL, options: .atomic)
    }

    private static func loadRecords(from url: URL) -> [String: ImageAssetRecord] {
        guard let data = try? Data(contentsOf: url),
              let records = try? JSONDecoder().decode([ImageAssetRecord].self, from: data) else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
    }
}
