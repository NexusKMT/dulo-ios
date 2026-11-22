/// Outcome of resolving one catalog identity into a temporary media lease.
enum MediaResolution {
    case ready(Lease<ResolvedMedia>)
    case notFound
    case httpFailure(statusCode: Int)
    case networkFailure
    case invalidResponse
    case internalFailure
    case cancelled
}
