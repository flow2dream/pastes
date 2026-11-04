import Foundation
import UniformTypeIdentifiers
import ImageIO
import AVFoundation

/// Pure stability tracker: requires unchanged size/mtime across scans before importing.
struct CaptureStabilityTracker {
    struct Stamp: Equatable { var size: Int; var modified: Date }
    private var pending: [URL: Stamp] = [:]
    private var delivered: [URL: Stamp] = [:]
    mutating func candidates(_ files: [URL: Stamp]) -> [URL] {
        pending = pending.filter { files[$0.key] != nil }
        delivered = delivered.filter { files[$0.key] != nil }
        var result: [URL] = []
        for (url, stamp) in files where stamp.size > 0 && delivered[url] != stamp {
            if pending[url] == stamp { result.append(url) }
            pending[url] = stamp
        }
        return result
    }
    mutating func acknowledge(_ url: URL) { delivered[url] = pending[url] }
}

@MainActor
final class CaptureWatcher {
    private var task: Task<Void, Never>?
    func start(folder: URL, acceptsAllMedia: Bool, onFile: @escaping (URL) async throws -> Void,
               onError: @escaping (Error) -> Void) {
        stop()
        let started = Date()
        task = Task {
            var tracker = CaptureStabilityTracker()
            var reportedError = false
            while !Task.isCancelled {
                do {
                    let files = try await Task.detached(priority: .utility) {
                        try Self.scan(folder, since: started, acceptsAllMedia: acceptsAllMedia)
                    }.value
                    guard !Task.isCancelled else { return }
                    for url in tracker.candidates(files) {
                        let ready = await Self.isReady(url)
                        guard !Task.isCancelled else { return }
                        if ready {
                            do { try await onFile(url); tracker.acknowledge(url); reportedError = false }
                            catch { if !reportedError { onError(error); reportedError = true } }
                        }
                    }
                } catch {
                    if !reportedError { onError(error); reportedError = true }
                }
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }
    func stop() { task?.cancel(); task = nil }
    deinit { task?.cancel() }

    nonisolated private static func scan(_ folder: URL, since: Date, acceptsAllMedia: Bool) throws -> [URL: CaptureStabilityTracker.Stamp] {
        let urls = try FileManager.default.contentsOfDirectory(at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
        var result: [URL: CaptureStabilityTracker.Stamp] = [:]
        for url in urls {
            guard let type = UTType(filenameExtension: url.pathExtension),
                  type.conforms(to: .image) || (acceptsAllMedia && type.conforms(to: .movie)),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let created = values.creationDate, created >= since,
                  let modified = values.contentModificationDate, let size = values.fileSize else { continue }
            if !acceptsAllMedia {
                let tagged = url.withUnsafeFileSystemRepresentation { path in
                    guard let path else { return false }
                    return getxattr(path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0) > 0
                }
                guard tagged else { continue }
            }
            result[url] = .init(size: size, modified: modified)
        }
        return result
    }
    nonisolated private static func isReady(_ url: URL) async -> Bool {
        if UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true {
            let asset = AVURLAsset(url: url)
            return (try? await asset.load(.isPlayable)) == true
        }
        return await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  CGImageSourceGetStatus(source) == .statusComplete else { return false }
            return CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
        }.value
    }
}
