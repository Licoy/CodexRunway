import Foundation

/// Shared URLSession with a hard total-time bound. `URLSession.shared` only gets
/// the per-request idle timeout (reset by every received byte) and a 7-day
/// resource timeout, so a trickling response could pin refresh spinners for ages.
public enum RunwayNetwork {
    public static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration)
    }()
}
