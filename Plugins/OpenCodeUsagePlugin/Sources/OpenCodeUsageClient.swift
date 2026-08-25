import Foundation

// MARK: - HTTP 抓取（对应 dsh-opencode-usage 的 fetchUsage 编排）

enum OpenCodeUsageError: LocalizedError {
    case missingConfig
    case http(status: Int)
    case timedOut
    case network(String)
    /// 页面解析为空：cookie 失效被 302 到登录页时就是这种形态。
    case emptyParse

    var errorDescription: String? {
        switch self {
        case .missingConfig:
            return L("error.missingConfig")
        case .http(let status):
            return LF("error.http", status)
        case .timedOut:
            return L("error.timedOut")
        case .network(let message):
            return message
        case .emptyParse:
            return L("error.emptyParse")
        }
    }
}

enum OpenCodeUsageClient {
    /// 独立 ephemeral 会话：手动设置 Cookie 头，避免共享 cookie jar 干扰；
    /// 同时禁用 URL 缓存——用量页必须每次真实回源，否则手动刷新会命中本地缓存拿到旧数据。
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    /// 并发抓取 Go 用量页与 workspace（Zen）页，解析并合成快照。
    static func fetch(config: OpenCodeUsageConfig) async throws -> UsageSnapshot {
        guard OpenCodeUsageConfigLogic.isConfigured(config),
              let cookie = config.cookie,
              let workspaceID = config.workspaceID,
              let baseURL = OpenCodeUsageConfigLogic.effectiveBaseURL(config)
        else { throw OpenCodeUsageError.missingConfig }

        // workspace id 只出现在 path 段，做百分号转义防止拼 URL。
        let encodedWorkspace = workspaceID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? workspaceID
        guard let goURL = URL(string: baseURL.absoluteString + "/workspace/\(encodedWorkspace)/go"),
              let zenURL = URL(string: baseURL.absoluteString + "/workspace/\(encodedWorkspace)")
        else { throw OpenCodeUsageError.missingConfig }

        // 与参考实现的默认超时一致（15 s）。
        async let goHTML = fetchText(url: goURL, cookie: cookie, timeout: 15)
        async let zenHTML = fetchText(url: zenURL, cookie: cookie, timeout: 15)
        let (goPage, zenState) = try await (OpenCodeUsageParser.parseGoPage(goHTML), OpenCodeUsageParser.parseZenPage(zenHTML))

        let snapshot = UsageSnapshot(updatedAt: Date(), zen: zenState, windows: goPage.windows)
        // 空结果无法与"没有数据"区分，按登录页跳转处理报错。
        guard !snapshot.isEmpty else { throw OpenCodeUsageError.emptyParse }
        return snapshot
    }

    private static func fetchText(url: URL, cookie: String, timeout: TimeInterval) async throws -> String {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("text/html", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw OpenCodeUsageError.network("Non-HTTP response.")
            }
            guard (200..<300).contains(http.statusCode) else {
                throw OpenCodeUsageError.http(status: http.statusCode)
            }
            return String(data: data, encoding: .utf8) ?? ""
        } catch let error as OpenCodeUsageError {
            throw error
        } catch let urlError as URLError where urlError.code == .timedOut {
            throw OpenCodeUsageError.timedOut
        } catch {
            throw OpenCodeUsageError.network(error.localizedDescription)
        }
    }
}
