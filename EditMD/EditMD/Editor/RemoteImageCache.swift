import AppKit

/// Refuse absurdly large payloads so one bad URL can't balloon memory.
private let remoteImageMaxBytes = 20_000_000

/// Session in-memory cache + fetch coordinator for remote (`http(s)`) images
/// shown in the Visual editor. Downloads run off-main; decode and delivery are
/// on main. Concurrent requests for the same URL share one download. Matches
/// Preview, which already loads remote images (its CSP allows `img-src http(s)`).
@MainActor
final class RemoteImageCache {
    static let shared = RemoteImageCache()

    private var cache: [URL: NSImage] = [:]
    private var inFlight: [URL: [(NSImage?) -> Void]] = [:]
    /// Failures remembered for `failureRetryInterval`: a presentation rebuild
    /// re-requests every visible src, and without negative caching a dead URL
    /// re-downloads (with its full timeout) on every theme/mode switch.
    private var failedAt: [URL: Date] = [:]
    private let failureRetryInterval: TimeInterval = 300

    /// Cached image for `url`, if already downloaded this session.
    func cached(_ url: URL) -> NSImage? { cache[url] }

    /// Delivers the image for `url` on the main thread — immediately from cache,
    /// or once the shared download finishes. `nil` on any failure (network,
    /// non-2xx, undecodable, oversized). Failures are answered from a cooldown
    /// map without hitting the network again for a few minutes.
    func load(_ url: URL, completion: @escaping (NSImage?) -> Void) {
        if let image = cache[url] { completion(image); return }
        if let failed = failedAt[url] {
            if Date().timeIntervalSince(failed) < failureRetryInterval {
                completion(nil)
                return
            }
            failedAt.removeValue(forKey: url)
        }
        if inFlight[url] != nil { inFlight[url]?.append(completion); return }
        inFlight[url] = [completion]
        Task { [weak self] in
            let data = await Self.fetchData(url)
            // Decode on main (NSImage isn't Sendable); Data crosses the boundary.
            let image = data.flatMap { NSImage(data: $0) }
            guard let self else { return }
            let delivered = (image?.size.width ?? 0) > 0 ? image : nil
            if let delivered {
                self.cache[url] = delivered
            } else {
                self.failedAt[url] = Date()
            }
            let waiters = self.inFlight.removeValue(forKey: url) ?? []
            for waiter in waiters { waiter(delivered) }
        }
    }

    /// Off-main download. Returns the raw bytes (Sendable) so the caller decodes
    /// on the main actor.
    nonisolated private static func fetchData(_ url: URL) async -> Data? {
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              !data.isEmpty, data.count <= remoteImageMaxBytes
        else { return nil }
        return data
    }
}
