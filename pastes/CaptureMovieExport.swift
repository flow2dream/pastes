import AVFoundation

/// The source is read-only. Export to a new file; the caller imports it only after success.
enum CaptureMovieExport {
    nonisolated static func trim(source: AVAsset, range: CMTimeRange, destination: URL) async throws {
        let duration = try await source.load(.duration)
        guard range.start.isNumeric, range.duration.isNumeric, range.start >= .zero,
              range.duration > .zero, CMTimeRangeGetEnd(range) <= duration,
              let export = AVAssetExportSession(asset: source, presetName: AVAssetExportPresetPassthrough) else {
            throw CaptureError.invalidTrim
        }
        export.timeRange = range
        do { try await export.export(to: destination, as: .mov) }
        catch { try? FileManager.default.removeItem(at: destination); throw error }
    }
}
