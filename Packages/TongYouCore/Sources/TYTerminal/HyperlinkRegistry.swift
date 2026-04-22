import Foundation

/// Manages OSC 8 hyperlink ID-to-URL mappings.
///
/// OSC 8 allows applications to assign text regions as hyperlinks
/// using the sequence: `\033]8;params;URL\033\\`
/// followed by display text and closed with `\033]8;;\033\\`.
///
/// The registry assigns numeric IDs to hyperlink strings so that
/// `CellAttributes` can store them compactly (UInt16).
public final class HyperlinkRegistry: @unchecked Sendable {
    /// Next available hyperlink ID (starts at 1; 0 means "no hyperlink").
    private var nextId: UInt16 = 1
    /// Maps numeric ID to URL string.
    private var idToURL: [UInt16: String] = [:]
    /// Maps URL string to numeric ID for deduplication.
    private var urlToId: [String: UInt16] = [:]
    /// Maps explicit OSC 8 `id` parameter values to numeric IDs.
    /// This allows applications to reuse hyperlink IDs across multiple OSC 8 sequences.
    private var explicitIdToNumericId: [String: UInt16] = [:]

    public init() {}

    /// Register a URL and return its numeric ID.
    /// If the same URL was already registered, returns the existing ID.
    /// If an explicitId is provided, it maps to the same numeric ID.
    public func register(url: String, explicitId: String? = nil) -> UInt16 {
        // If explicitId is provided, check if we've seen it before
        if let explicitId {
            if let existing = explicitIdToNumericId[explicitId] {
                // Update the URL mapping if it changed
                idToURL[existing] = url
                urlToId[url] = existing
                return existing
            }
        }

        // Check if URL already registered
        if let existingId = urlToId[url] {
            if let explicitId {
                explicitIdToNumericId[explicitId] = existingId
            }
            return existingId
        }

        // Assign new ID
        let id = nextId
        nextId += 1
        idToURL[id] = url
        urlToId[url] = id
        if let explicitId {
            explicitIdToNumericId[explicitId] = id
        }
        return id
    }

    /// Look up the URL for a given numeric ID.
    public func url(for id: UInt16) -> String? {
        idToURL[id]
    }

    /// Remove all registrations.
    public func clear() {
        nextId = 1
        idToURL.removeAll()
        urlToId.removeAll()
        explicitIdToNumericId.removeAll()
    }
}
