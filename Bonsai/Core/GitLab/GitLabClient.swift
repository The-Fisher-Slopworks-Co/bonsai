import Foundation

enum GitLabError: Error, Equatable {
    case badToken
    case unreachable
    case certificate(fingerprint: String?)
    case http(status: Int)
    case decoding
}

struct GitLabUser: Codable, Equatable, Sendable {
    var id: Int
    var username: String
    var name: String
    var avatarURL: URL?
    var email: String?
    var commitEmail: String?

    enum CodingKeys: String, CodingKey {
        case id, username, name, email
        case avatarURL = "avatar_url"
        case commitEmail = "commit_email"
    }
}

final class GitLabClient: Sendable {
    let server: URL
    private let token: String
    private let session: URLSession
    private let trust: TrustDelegate

    init(
        server: URL, token: String, trustedFingerprint: String? = nil,
        configuration: URLSessionConfiguration = .ephemeral
    ) {
        self.server = server
        self.token = token
        configuration.timeoutIntervalForRequest = 20
        configuration.httpAdditionalHeaders = ["Accept": "application/json"]
        trust = TrustDelegate(host: server.host() ?? "", pinned: trustedFingerprint)
        session = URLSession(configuration: configuration, delegate: trust, delegateQueue: nil)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    var acceptedCertificate: Data? { trust.acceptedCertificate }

    func user() async throws -> GitLabUser {
        try await get("user")
    }

    func tokenExpiry() async throws -> Date? {
        struct Token: Decodable {
            var expiresAt: Date?
            enum CodingKeys: String, CodingKey { case expiresAt = "expires_at" }
        }
        let token: Token = try await get("personal_access_tokens/self")
        return token.expiresAt
    }

    func projects(search: String) async throws -> [GitLabProject] {
        var query = ["membership": "true", "simple": "true", "order_by": "last_activity_at", "per_page": "20"]
        let term = search.trimmingCharacters(in: .whitespaces)
        if !term.isEmpty {
            query["search"] = term
            query["search_namespaces"] = "true"
        }
        return try await get("projects", query: query)
    }

    static let branchPageSize = 100
    static let branchPageLimit = 10

    func branches(project: Int, defaultBranch: String? = nil) async throws -> [GitLabBranch] {
        var all: [GitLabBranch] = []
        for page in 1...Self.branchPageLimit {
            let batch: [GitLabBranch] = try await get(
                "projects/\(project)/repository/branches",
                query: ["per_page": "\(Self.branchPageSize)", "page": "\(page)"])
            all += batch
            if batch.count < Self.branchPageSize { break }
        }
        if !all.contains(where: \.isDefault), let defaultBranch,
            let branch: GitLabBranch = try? await get(
                "projects/\(project)/repository/branches/\(Self.segment(defaultBranch))")
        {
            all.removeAll { $0.name == branch.name }
            all.insert(GitLabBranch(name: branch.name, isDefault: true), at: 0)
        }
        return all.filter(\.isDefault) + all.filter { !$0.isDefault }
    }

    func rootFiles(project: Int, ref: String) async throws -> [String] {
        let entries: [GitLabTreeEntry] = try await get(
            "projects/\(project)/repository/tree", query: ["ref": ref, "per_page": "100"])
        return entries.filter { $0.type == "blob" }.map(\.name)
    }

    func file(project: Int, path: String, ref: String) async throws -> String? {
        do {
            let data = try await send(
                request("projects/\(project)/repository/files/\(Self.segment(path))/raw", query: ["ref": ref]))
            return String(decoding: data, as: UTF8.self)
        } catch GitLabError.http(status: 404) {
            return nil
        }
    }

    func mergeRequests(project: Int, scope: MRScope) async throws -> [MergeRequest] {
        let query = [
            "state": "opened", "scope": scope == .mine ? "created_by_me" : "all", "per_page": "100",
            "order_by": "updated_at",
        ]
        let all: [GitLabMergeRequest] = try await get("projects/\(project)/merge_requests", query: query)
        return all.filter { ($0.sourceProjectID ?? project) == project }.map(\.model)
    }

    func latestPipeline(project: Int, sha: String) async throws -> GitLabPipeline? {
        let list: [GitLabPipeline] = try await get(
            "projects/\(project)/pipelines",
            query: ["sha": sha, "order_by": "id", "sort": "desc", "per_page": "1"])
        return list.first
    }

    func failedJobs(project: Int, pipeline: Int) async throws -> [GitLabJob] {
        try await get(
            "projects/\(project)/pipelines/\(pipeline)/jobs", query: ["scope[]": "failed", "per_page": "100"])
    }

    func retryPipeline(project: Int, pipeline: Int) async throws {
        _ = try await send(request("projects/\(project)/pipelines/\(pipeline)/retry", method: "POST"))
    }

    func jobLog(project: Int, job: Int) async throws -> String {
        String(decoding: try await send(request("projects/\(project)/jobs/\(job)/trace")), as: UTF8.self)
    }

    func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        let data = try await send(request(path, query: query))
        return try decode(data)
    }

    func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw map(error)
        }
        guard let http = response as? HTTPURLResponse else { throw GitLabError.unreachable }
        switch http.statusCode {
        case 200..<300: return data
        case 401, 403: throw GitLabError.badToken
        default: throw GitLabError.http(status: http.statusCode)
        }
    }

    func request(_ path: String, query: [String: String] = [:], method: String = "GET") -> URLRequest {
        var components = URLComponents(string: apiBase.absoluteString + "/" + path)!
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue(token, forHTTPHeaderField: "PRIVATE-TOKEN")
        return request
    }

    var apiBase: URL { URL(string: server.absoluteString + "/api/v4")! }

    static func segment(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#%")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try GitLabClient.decoder.decode(T.self, from: data)
        } catch {
            throw GitLabError.decoding
        }
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = ISO8601DateFormatter.withFractions.date(from: text)
                ?? ISO8601DateFormatter.plain.date(from: text)
            {
                return date
            }
            let day = DateFormatter()
            day.locale = Locale(identifier: "en_US_POSIX")
            day.timeZone = TimeZone(identifier: "UTC")
            day.dateFormat = "yyyy-MM-dd"
            if let date = day.date(from: text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: text))
        }
        return decoder
    }()

    private func map(_ error: URLError) -> GitLabError {
        switch error.code {
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
            .serverCertificateHasUnknownRoot:
            return .certificate(fingerprint: trust.lastFailedFingerprint)
        case .secureConnectionFailed:
            return trust.lastFailedFingerprint == nil
                ? .unreachable : .certificate(fingerprint: trust.lastFailedFingerprint)
        case .cancelled where trust.lastFailedFingerprint != nil:
            return .certificate(fingerprint: trust.lastFailedFingerprint)
        default:
            return .unreachable
        }
    }

    static func normalize(_ text: String) -> URL? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if !value.contains("://") { value = "https://" + value }
        while value.hasSuffix("/") { value.removeLast() }
        if value.hasSuffix("/api/v4") { value.removeLast("/api/v4".count) }
        guard let url = URL(string: value), let scheme = url.scheme, ["http", "https"].contains(scheme),
            url.host() != nil
        else { return nil }
        return url
    }

    static func tokenPageURL(server text: String) -> URL {
        var base = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = "https://gitlab.com" }
        let url = normalize(base) ?? URL(string: "https://gitlab.com")!
        return URL(string: url.absoluteString + "/-/profile/personal_access_tokens?name=Bonsai&scopes=api")!
    }
}

extension ISO8601DateFormatter {
    nonisolated(unsafe) static let withFractions: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) static let plain = ISO8601DateFormatter()
}
