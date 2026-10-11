// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 The Fisher Slopworks Co

import Foundation
import Testing

@testable import Bonsai

struct GitLabClientTests {
    func client(_ handler: @escaping MockURLProtocol.Handler) -> (GitLabClient, URL) {
        let server = MockURLProtocol.server(handler)
        return (
            GitLabClient(server: server, token: "glpat-abc", configuration: MockURLProtocol.configuration()), server
        )
    }

    @Test func userSuccessSendsTokenHeader() async throws {
        let (gitlab, server) = client { _ in
            (200, json(#"{"id": 3, "username": "eugene", "name": "Eugene", "avatar_url": "https://x/a.png"}"#))
        }
        let user = try await gitlab.user()
        #expect(
            user == GitLabUser(id: 3, username: "eugene", name: "Eugene", avatarURL: URL(string: "https://x/a.png")))
        let request = try #require(MockURLProtocol.recorded(server).first)
        #expect(request.url?.path() == "/api/v4/user")
        #expect(request.value(forHTTPHeaderField: "PRIVATE-TOKEN") == "glpat-abc")
        #expect(request.url?.absoluteString.contains("glpat") == false)
    }

    @Test(arguments: [401, 403])
    func rejectedToken(status: Int) async {
        let (gitlab, _) = client { _ in (status, json(#"{"message": "401 Unauthorized"}"#)) }
        await #expect(throws: GitLabError.badToken) { try await gitlab.user() }
    }

    @Test(arguments: [URLError.Code.cannotFindHost, .cannotConnectToHost, .timedOut, .notConnectedToInternet])
    func networkErrorsAreUnreachable(code: URLError.Code) async {
        let (gitlab, _) = client { _ in throw URLError(code) }
        await #expect(throws: GitLabError.unreachable) { try await gitlab.user() }
    }

    @Test(arguments: [
        URLError.Code.serverCertificateUntrusted, .serverCertificateHasUnknownRoot, .serverCertificateHasBadDate,
    ])
    func tlsErrorsAreCertificate(code: URLError.Code) async {
        let (gitlab, _) = client { _ in throw URLError(code) }
        await #expect(throws: GitLabError.certificate(fingerprint: nil)) { try await gitlab.user() }
    }

    @Test func notGitLabIsDecodingError() async {
        let (gitlab, _) = client { _ in (200, json("<html>hello</html>")) }
        await #expect(throws: GitLabError.decoding) { try await gitlab.user() }
    }

    @Test func serverErrorStatus() async {
        let (gitlab, _) = client { _ in (502, Data()) }
        await #expect(throws: GitLabError.http(status: 502)) { try await gitlab.user() }
    }

    @Test(arguments: [
        ("gitlab.example.com", "https://gitlab.example.com"),
        ("  https://gitlab.example.com/  ", "https://gitlab.example.com"),
        ("http://localhost:8929", "http://localhost:8929"),
        ("https://example.com/gitlab/api/v4/", "https://example.com/gitlab"),
    ])
    func normalizesServer(input: String, expected: String) {
        #expect(GitLabClient.normalize(input)?.absoluteString == expected)
    }

    @Test(arguments: ["", "   ", "ftp://x", "https://"])
    func rejectsBadServer(input: String) {
        #expect(GitLabClient.normalize(input) == nil)
    }

    @Test func tokenPageLink() {
        #expect(
            GitLabClient.tokenPageURL(server: "https://git.corp/").absoluteString
                == "https://git.corp/-/profile/personal_access_tokens?name=Bonsai&scopes=api")
        #expect(
            GitLabClient.tokenPageURL(server: "").absoluteString
                == "https://gitlab.com/-/profile/personal_access_tokens?name=Bonsai&scopes=api")
    }

    @Test func subpathServerBuildsApiPath() async throws {
        let base = MockURLProtocol.server { _ in
            (200, json(#"{"id": 1, "username": "u", "name": "U", "avatar_url": null}"#))
        }
        let server = URL(string: base.absoluteString + "/gitlab")!
        let gitlab = GitLabClient(server: server, token: "t", configuration: MockURLProtocol.configuration())
        _ = try await gitlab.user()
        #expect(MockURLProtocol.recorded(base).first?.url?.path() == "/gitlab/api/v4/user")
    }

    @Test func segmentEncodesSlashes() {
        #expect(GitLabClient.segment("group/sub/app") == "group%2Fsub%2Fapp")
        #expect(GitLabClient.segment("feature/x y") == "feature%2Fx%20y")
    }
}

struct TrustTests {
    @Test func acceptsOnlyPinnedFingerprintForSameHost() {
        #expect(TrustDelegate.accepts(challengeHost: "git.corp", host: "git.corp", pinned: "AA:BB", presented: "AA:BB"))
        #expect(TrustDelegate.accepts(challengeHost: "GIT.corp", host: "git.corp", pinned: "AA:BB", presented: "AA:BB"))
        #expect(
            !TrustDelegate.accepts(challengeHost: "evil.corp", host: "git.corp", pinned: "AA:BB", presented: "AA:BB"))
        #expect(
            !TrustDelegate.accepts(challengeHost: "git.corp", host: "git.corp", pinned: "AA:BB", presented: "CC:DD"))
        #expect(!TrustDelegate.accepts(challengeHost: "git.corp", host: "git.corp", pinned: nil, presented: "AA:BB"))
    }

    @Test func fingerprintFormat() {
        let fp = TrustDelegate.fingerprint(der: Data("abc".utf8))
        #expect(fp.hasPrefix("BA:78:16:BF"))
        #expect(fp.split(separator: ":").count == 32)
    }
}
