import Foundation
import MusicKit

// Apple Music API calls for main.m (MusicKit's data request is Swift-only).
@objc public class Catalog: NSObject {
    // Raw JSON for `url`, where "{sf}" is replaced by the user's storefront. Code -1 means the request threw.
    @objc(get:done:)
    public static func get(_ url: String, done: @escaping (Int, String) -> Void) {
        Task {
            do {
                if MusicAuthorization.currentStatus != .authorized { _ = await MusicAuthorization.request() }
                let sf = try await MusicDataRequest.currentCountryCode
                let u = URL(string: url.replacingOccurrences(of: "{sf}", with: sf))!
                let r = try await MusicDataRequest(urlRequest: URLRequest(url: u)).response()
                let body = String(decoding: r.data, as: UTF8.self)
                await MainActor.run { done(r.urlResponse.statusCode, body) }
            } catch {
                await MainActor.run { done(-1, "\(error)") }
            }
        }
    }
}
