import Foundation
import Combine

/// 仅接受可选的小写 v 前缀和 ASCII 数字段；尾随零不影响比较。
struct UpdateVersion: Comparable {
    private let components: [String]

    init?(_ text: String) {
        let digits = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let parts = digits.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({
            !$0.isEmpty && $0.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
        }) else { return nil }
        var normalized = parts.map { part -> String in
            let value = part.drop(while: { $0 == "0" })
            return value.isEmpty ? "0" : String(value)
        }
        while normalized.count > 1 && normalized.last == "0" { normalized.removeLast() }
        components = normalized
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        for index in 0..<max(lhs.components.count, rhs.components.count) {
            let left = index < lhs.components.count ? lhs.components[index] : "0"
            let right = index < rhs.components.count ? rhs.components[index] : "0"
            if left.count != right.count { return left.count < right.count }
            if left != right { return left < right }
        }
        return false
    }
}

private final class UpdateRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // 元数据请求不跟随重定向，避免越过固定的官方 API 边界。
        completionHandler(nil)
    }
}

@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    struct Release {
        let tag: String
        let version: UpdateVersion
        let pageURL: URL
        let downloadURL: URL?
        let notes: String
    }

    enum Status: Equatable {
        case idle, checking, upToDate, available, skipped, noPackage
        case rateLimited, notPublished, invalidRelease, invalidCurrentVersion
        case networkError, serviceError(Int)
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var release: Release?
    @Published private(set) var lastAttempt: Date?
    @Published private(set) var networkFailureCode: Int?

    static func networkFailureKey(_ code: Int) -> String {
        switch code {
        case NSURLErrorTimedOut: return "连接 GitHub 超时，请检查代理或稍后重试。"
        case NSURLErrorNotConnectedToInternet: return "当前没有可用的网络连接。"
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return "无法解析 GitHub 地址，请检查 DNS 或代理设置。"
        case NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost: return "无法连接 GitHub，或连接已中断。"
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateHasUnknownRoot,
             NSURLErrorServerCertificateNotYetValid:
            return "GitHub 安全连接校验失败，请检查系统时间、证书和代理；不会跳过证书验证。"
        default: return "更新检查失败，请检查网络后重试。"
        }
    }
    @Published var autoCheck: Bool {
        didSet {
            defaults.set(autoCheck, forKey: Keys.auto)
            scheduleAutomaticCheck()
        }
    }

    let currentVersion: String
    private let defaults: UserDefaults
    private let session: URLSession
    private var timer: Timer?
    private let interval: TimeInterval = 24 * 60 * 60

    private enum Keys {
        static let auto = "update.autoCheck"
        static let attempt = "update.lastAttempt"
        static let skip = "update.skippedVersion"
    }

    private struct Payload: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
        }
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
        let html_url: String
        let body: String?
        let assets: [Asset]
    }

    private init() {
        defaults = .standard
        autoCheck = defaults.bool(forKey: Keys.auto)
        lastAttempt = defaults.object(forKey: Keys.attempt) as? Date
        currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        configuration.httpShouldSetCookies = false
        session = URLSession(configuration: configuration, delegate: UpdateRedirectPolicy(), delegateQueue: nil)
        scheduleAutomaticCheck()
    }

    /// 手动检查不受 24 小时与跳过版本限制；自动检查必须先明确启用。
    func check(manual: Bool = true) {
        guard status != .checking else { return }
        if !manual {
            guard autoCheck else { return }
            if let lastAttempt, Date().timeIntervalSince(lastAttempt) < interval {
                scheduleAutomaticCheck()
                return
            }
        }
        guard let installed = UpdateVersion(currentVersion) else {
            status = .invalidCurrentVersion
            return
        }
        timer?.invalidate()
        let attempt = Date()
        lastAttempt = attempt
        defaults.set(attempt, forKey: Keys.attempt)
        release = nil
        networkFailureCode = nil
        status = .checking

        Task { @MainActor in
            defer { scheduleAutomaticCheck() }
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/stevenjx/InfiniCal/releases/latest")!)
            request.timeoutInterval = 15
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("InfiniCal-UpdateChecker", forHTTPHeaderField: "User-Agent")
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    status = .invalidRelease
                    return
                }
                if http.statusCode == 429 || (http.statusCode == 403 &&
                    (http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" ||
                     http.value(forHTTPHeaderField: "Retry-After") != nil ||
                     String(data: data, encoding: .utf8)?.lowercased().contains("rate limit") == true)) {
                    status = .rateLimited
                    return
                }
                guard http.statusCode == 200 else {
                    status = http.statusCode == 404 ? .notPublished : .serviceError(http.statusCode)
                    return
                }
                guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
                      !payload.draft, !payload.prerelease,
                      let version = UpdateVersion(payload.tag_name),
                      let page = Self.officialURL(payload.html_url, tag: payload.tag_name, asset: false) else {
                    status = .invalidRelease
                    return
                }
                guard version > installed else {
                    status = .upToDate
                    return
                }
                let download = payload.assets.lazy.filter { $0.name.lowercased().hasSuffix(".dmg") }
                    .compactMap { Self.officialURL($0.browser_download_url, tag: payload.tag_name, asset: true) }.first
                release = Release(tag: payload.tag_name, version: version, pageURL: page,
                                  downloadURL: download, notes: payload.body ?? "")
                if !manual, let skipped = defaults.string(forKey: Keys.skip), UpdateVersion(skipped) == version {
                    status = .skipped
                } else {
                    status = download == nil ? .noPackage : .available
                }
            } catch {
                let failure = error as NSError
                networkFailureCode = failure.domain == NSURLErrorDomain ? failure.code : nil
                status = .networkError
            }
        }
    }

    func skip() {
        guard let release else { return }
        defaults.set(release.tag, forKey: Keys.skip)
        status = .skipped
    }

    private func scheduleAutomaticCheck() {
        timer?.invalidate()
        timer = nil
        guard autoCheck else { return }
        let delay = max(1, (lastAttempt?.addingTimeInterval(interval).timeIntervalSinceNow ?? 0))
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.check(manual: false) }
        }
    }

    /// 只接受对应版本的官方 release 页面或同仓库的 DMG 资产直链。
    private static func officialURL(_ raw: String, tag: String, asset: Bool) -> URL? {
        guard let parts = URLComponents(string: raw),
              parts.scheme == "https", parts.host?.lowercased() == "github.com",
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.query == nil, parts.fragment == nil,
              let url = parts.url else { return nil }
        let segments = parts.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let prefix = ["", "stevenjx", "InfiniCal", "releases", asset ? "download" : "tag", tag]
        if asset {
            guard segments.count == 7, Array(segments.prefix(6)) == prefix,
                  segments[6].lowercased().hasSuffix(".dmg"),
                  !segments[6].contains("\\"), !segments[6].contains("%") else { return nil }
        } else {
            guard segments == prefix else { return nil }
        }
        return url
    }
}
