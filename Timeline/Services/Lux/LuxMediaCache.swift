import Foundation
import CryptoKit
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Disk + memory caches for Lux thumbs, strip previews, and a small LRU of full originals.
actor LuxMediaCache {
    static let shared = LuxMediaCache()

    private var thumbMemory: [String: Data] = [:]
    private var previewMemory: [String: Data] = [:]
    private var originalMemory: [String: Data] = [:]
    private var originalOrder: [String] = []
    private let thumbFolder: URL
    private let previewFolder: URL
    private let originalFolder: URL

    private let maxOriginals = 24
    private let maxOriginalBytes = 120 * 1024 * 1024
    /// Longest edge for strip/sheet interim previews (retina-friendly).
    private let previewMaxEdge: CGFloat = 720

    private init() {
        let paths = Self.folderURLs()
        thumbFolder = paths.thumbs
        previewFolder = paths.previews
        originalFolder = paths.originals
        for folder in [thumbFolder, previewFolder, originalFolder] {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let legacy = base.appendingPathComponent("LuxThumbnails", isDirectory: true)
        if FileManager.default.fileExists(atPath: legacy.path) {
            if let files = try? FileManager.default.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil) {
                for file in files where file.pathExtension == "jpg" || file.pathExtension == "bin" {
                    let dest = thumbFolder.appendingPathComponent(file.lastPathComponent)
                    try? FileManager.default.moveItem(at: file, to: dest)
                }
            }
            try? FileManager.default.removeItem(at: legacy)
        }
    }

    private static func folderURLs() -> (thumbs: URL, previews: URL, originals: URL) {
        folderURLsForSync()
    }

    fileprivate nonisolated static func folderURLsForSync() -> (thumbs: URL, previews: URL, originals: URL) {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let root = base.appendingPathComponent("LuxMedia", isDirectory: true)
        return (
            root.appendingPathComponent("thumbs", isDirectory: true),
            root.appendingPathComponent("previews", isDirectory: true),
            root.appendingPathComponent("originals", isDirectory: true)
        )
    }

    /// Main-thread-safe lookup for instant strip paint (no actor hop).
    nonisolated static func syncDisplayThumbnail(forKey key: String) -> Data? {
        SyncThumbIndex.shared.display(forKey: key)
    }

    nonisolated static func syncDisplayThumbnails(forKeys keys: [String]) -> [String: Data] {
        SyncThumbIndex.shared.display(forKeys: keys)
    }

    /// Best available bytes for a strip tile: preview (from original) > Lux thumb.
    func displayThumbnail(forKey key: String) -> Data? {
        if let preview = preview(forKey: key) { return preview }
        return thumbnail(forKey: key)
    }

    /// Batch lookup — one actor hop for many strip tiles.
    func displayThumbnails(forKeys keys: [String]) -> [String: Data] {
        var result: [String: Data] = [:]
        result.reserveCapacity(keys.count)
        for key in keys {
            if let data = displayThumbnail(forKey: key) {
                result[key] = data
            }
        }
        return result
    }

    func thumbnail(forKey key: String) -> Data? {
        if let hit = thumbMemory[key] { return hit }
        guard let data = try? Data(contentsOf: fileURL(in: thumbFolder, key: key)) else { return nil }
        thumbMemory[key] = data
        SyncThumbIndex.shared.storeThumbnail(data, forKey: key)
        return data
    }

    func storeThumbnail(_ data: Data, forKey key: String) {
        thumbMemory[key] = data
        SyncThumbIndex.shared.storeThumbnail(data, forKey: key)
        try? data.write(to: fileURL(in: thumbFolder, key: key), options: .atomic)
    }

    func preview(forKey key: String) -> Data? {
        if let hit = previewMemory[key] { return hit }
        guard let data = try? Data(contentsOf: fileURL(in: previewFolder, key: key)) else { return nil }
        previewMemory[key] = data
        SyncThumbIndex.shared.storePreview(data, forKey: key)
        return data
    }

    func original(forKey key: String) -> Data? {
        if let hit = originalMemory[key] {
            touchOriginal(key)
            return hit
        }
        guard let data = try? Data(contentsOf: fileURL(in: originalFolder, key: key)) else { return nil }
        insertOriginal(data, forKey: key, writeDisk: false)
        return data
    }

    func storeOriginal(_ data: Data, forKey key: String) {
        insertOriginal(data, forKey: key, writeDisk: true)
        if let preview = Self.downscaledJPEG(from: data, maxEdge: previewMaxEdge) {
            previewMemory[key] = preview
            SyncThumbIndex.shared.storePreview(preview, forKey: key)
            try? preview.write(to: fileURL(in: previewFolder, key: key), options: .atomic)
        }
    }

    private func insertOriginal(_ data: Data, forKey key: String, writeDisk: Bool) {
        originalMemory[key] = data
        touchOriginal(key)
        if writeDisk {
            try? data.write(to: fileURL(in: originalFolder, key: key), options: .atomic)
        }
        trimOriginalsIfNeeded()
    }

    private func touchOriginal(_ key: String) {
        originalOrder.removeAll { $0 == key }
        originalOrder.append(key)
    }

    private func trimOriginalsIfNeeded() {
        var total = originalMemory.values.reduce(0) { $0 + $1.count }
        while originalOrder.count > maxOriginals || total > maxOriginalBytes, let oldest = originalOrder.first {
            originalOrder.removeFirst()
            if let data = originalMemory.removeValue(forKey: oldest) {
                total -= data.count
            }
            try? FileManager.default.removeItem(at: fileURL(in: originalFolder, key: oldest))
            // Keep previews — they're small and make strips sharp after originals age out.
        }
    }

    private func fileURL(in folder: URL, key: String) -> URL {
        Self.fileURL(in: folder, key: key)
    }

    fileprivate nonisolated static func fileURL(in folder: URL, key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return folder.appendingPathComponent(digest).appendingPathExtension("bin")
    }

    private static func downscaledJPEG(from data: Data, maxEdge: CGFloat) -> Data? {
        #if os(iOS)
        guard let image = UIImage(data: data) else { return nil }
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > maxEdge else {
            return image.jpegData(compressionQuality: 0.86)
        }
        let scale = maxEdge / longest
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let rendered = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return rendered.jpegData(compressionQuality: 0.86)
        #else
        guard let image = NSImage(data: data) else { return nil }
        let size = image.size
        let longest = max(size.width, size.height)
        let target: NSSize
        if longest > maxEdge {
            let scale = maxEdge / longest
            target = NSSize(width: size.width * scale, height: size.height * scale)
        } else {
            target = size
        }
        let output = NSImage(size: target)
        output.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(origin: .zero, size: target),
            from: NSRect(origin: .zero, size: size),
            operation: .copy,
            fraction: 1
        )
        output.unlockFocus()
        guard let tiff = output.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.86])
        #endif
    }
}

/// Lock-based thumb index so day switches can paint strips without awaiting the actor.
private final class SyncThumbIndex: @unchecked Sendable {
    static let shared = SyncThumbIndex()

    private let lock = NSLock()
    private var thumbMemory: [String: Data] = [:]
    private var previewMemory: [String: Data] = [:]
    private let thumbFolder: URL
    private let previewFolder: URL

    private init() {
        let paths = LuxMediaCache.folderURLsForSync()
        thumbFolder = paths.thumbs
        previewFolder = paths.previews
    }

    func storeThumbnail(_ data: Data, forKey key: String) {
        lock.lock()
        thumbMemory[key] = data
        lock.unlock()
    }

    func storePreview(_ data: Data, forKey key: String) {
        lock.lock()
        previewMemory[key] = data
        lock.unlock()
    }

    func display(forKey key: String) -> Data? {
        lock.lock()
        if let preview = previewMemory[key] {
            lock.unlock()
            return preview
        }
        if let thumb = thumbMemory[key] {
            lock.unlock()
            return thumb
        }
        lock.unlock()

        let previewURL = LuxMediaCache.fileURL(in: previewFolder, key: key)
        if let data = try? Data(contentsOf: previewURL) {
            lock.lock()
            previewMemory[key] = data
            lock.unlock()
            return data
        }
        let thumbURL = LuxMediaCache.fileURL(in: thumbFolder, key: key)
        if let data = try? Data(contentsOf: thumbURL) {
            lock.lock()
            thumbMemory[key] = data
            lock.unlock()
            return data
        }
        return nil
    }

    func display(forKeys keys: [String]) -> [String: Data] {
        var result: [String: Data] = [:]
        result.reserveCapacity(keys.count)
        for key in keys {
            if let data = display(forKey: key) {
                result[key] = data
            }
        }
        return result
    }
}
