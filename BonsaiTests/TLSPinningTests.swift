import Foundation
import Testing
@testable import Bonsai

@Suite(.serialized)
final class TLSPinningTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bonsai-tls-\(UUID().uuidString)")
    var server: Process?
    var port = 0
    var fingerprint = ""

    init() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cert = dir.appendingPathComponent("cert.pem").path
        let key = dir.appendingPathComponent("key.pem").path
        try run("/usr/bin/openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=localhost",
                                     "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1", "-keyout", key, "-out", cert])
        let der = dir.appendingPathComponent("cert.der").path
        try run("/usr/bin/openssl", ["x509", "-in", cert, "-outform", "DER", "-out", der])
        fingerprint = TrustDelegate.fingerprint(der: try Data(contentsOf: URL(fileURLWithPath: der)))

        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Support/tls_server.py").path
        let portFile = dir.appendingPathComponent("port").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", script, cert, key, portFile]
        try process.run()
        server = process
        for _ in 0..<100 where port == 0 {
            if let text = try? String(contentsOfFile: portFile, encoding: .utf8), let value = Int(text) { port = value }
            else { Thread.sleep(forTimeInterval: 0.05) }
        }
    }

    deinit {
        server?.terminate()
        try? FileManager.default.removeItem(at: dir)
    }

    private func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 { throw CocoaError(.fileWriteUnknown) }
    }

    var url: URL { URL(string: "https://127.0.0.1:\(port)")! }

    @Test func untrustedCertificateReportsFingerprint() async {
        #expect(port != 0)
        let client = GitLabClient(server: url, token: "t")
        await #expect(throws: GitLabError.certificate(fingerprint: fingerprint)) { try await client.user() }
    }

    @Test func pinnedFingerprintIsAccepted() async throws {
        let client = GitLabClient(server: url, token: "t", trustedFingerprint: fingerprint)
        #expect(try await client.user().username == "tls")
        let der = try #require(client.acceptedCertificate)
        #expect(TrustDelegate.fingerprint(der: der) == fingerprint)
        #expect(TrustDelegate.pem(der: der).hasPrefix("-----BEGIN CERTIFICATE-----\n"))
    }

    @Test func wrongPinIsRejected() async {
        let client = GitLabClient(server: url, token: "t", trustedFingerprint: "00:11")
        await #expect(throws: GitLabError.certificate(fingerprint: fingerprint)) { try await client.user() }
    }
}
