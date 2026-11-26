import CoreVideo
import Foundation

/// Glare detection for camera frames. Displays sit behind glossy plastic or glass, and a
/// reflection shows up as a patch of blown-out, near-white pixels that can hide segments.
enum FrameQuality {

    /// Share (0...1) of near-white pixels in the middle 70% of the frame, where the display
    /// usually is. Samples every 4th pixel in each direction, so it costs well under a
    /// millisecond on a 1080p frame.
    static func glareFraction(_ buffer: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        let format = CVPixelBufferGetPixelFormatType(buffer)
        let isBiPlanarYUV = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let isBGRA = format == kCVPixelFormatType_32BGRA
        guard isBiPlanarYUV || isBGRA else { return 0 }

        let base = isBiPlanarYUV ? CVPixelBufferGetBaseAddressOfPlane(buffer, 0) : CVPixelBufferGetBaseAddress(buffer)
        guard let base else { return 0 }
        let width = isBiPlanarYUV ? CVPixelBufferGetWidthOfPlane(buffer, 0) : CVPixelBufferGetWidth(buffer)
        let height = isBiPlanarYUV ? CVPixelBufferGetHeightOfPlane(buffer, 0) : CVPixelBufferGetHeight(buffer)
        let rowBytes = isBiPlanarYUV ? CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) : CVPixelBufferGetBytesPerRow(buffer)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        // Video-range luma tops out at 235, full range at 255.
        let threshold: UInt8 = format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ? 230 : 248

        let x0 = width * 15 / 100, x1 = width * 85 / 100
        let y0 = height * 15 / 100, y1 = height * 85 / 100
        var bright = 0, total = 0
        for y in stride(from: y0, to: y1, by: 4) {
            let row = pixels + y * rowBytes
            for x in stride(from: x0, to: x1, by: 4) {
                let luma: UInt8
                if isBGRA {
                    let p = row + x * 4  // B, G, R: near-white means all three are high
                    luma = min(p[0], min(p[1], p[2]))
                } else {
                    luma = row[x]
                }
                if luma >= threshold { bright += 1 }
                total += 1
            }
        }
        return total == 0 ? 0 : Double(bright) / Double(total)
    }

    /// Above this share of near-white pixels, the hint asks the person to tilt the phone.
    /// A first guess; reading analytics carry the score so it can be tuned.
    static let glareHintThreshold = 0.03
}

/// The last half second of scored frames, so the shutter can use the one with the least
/// glare instead of whichever frame happened to be newest. Keeps only a few frames so the
/// camera's buffer pool isn't starved.
final class RecentFrames {
    private struct Entry {
        let frame: CVPixelBuffer
        let glare: Double
        let time: TimeInterval
    }

    private var entries: [Entry] = []
    private let lock = NSLock()
    private let window: TimeInterval = 0.5
    private let capacity = 4

    func add(_ frame: CVPixelBuffer, glare: Double) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock(); defer { lock.unlock() }
        entries.append(Entry(frame: frame, glare: glare, time: now))
        entries.removeAll { now - $0.time > window }
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    }

    /// The least glary recent frame and its glare score.
    func best() -> (frame: CVPixelBuffer, glare: Double)? {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock(); defer { lock.unlock() }
        return entries
            .filter { now - $0.time <= window }
            .min { $0.glare < $1.glare }
            .map { ($0.frame, $0.glare) }
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll()
    }
}
