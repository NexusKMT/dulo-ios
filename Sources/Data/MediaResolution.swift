/// Outcome of resolving one catalog identity into a temporary media lease.
enum MediaResolution {
    case ready(Lease<ResolvedMedia>)
    case notFound
    case httpFailure(statusCode: Int)
    case networkFailure
    case invalidResponse
    case internalFailure
}

/// Retry one failed network request before the feed advances past the item.
func shouldRetryResolution(_ result: MediaResolution, retries: Int) -> Bool {
    if case .networkFailure = result { return retries < 1 }
    return false
}
