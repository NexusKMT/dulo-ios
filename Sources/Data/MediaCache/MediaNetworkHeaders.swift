import Foundation

/// Standard CDN request headers required by Douyin video CDN.
public enum MediaNetworkHeaders {
    public static let douyinUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/158.0.0.0 Safari/537.36"
    public static let douyinReferer = "https://www.douyin.com/"

    public static let httpHeaders = [
        "User-Agent": douyinUA,
        "Referer": douyinReferer,
    ]
}
