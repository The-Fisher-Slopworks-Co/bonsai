import CryptoKit
import Foundation
import Security

final class TrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    let host: String
    let pinned: String?
    private let lock = NSLock()
    private var failed: String?
    private var accepted: Data?

    init(host: String, pinned: String?) {
        self.host = host
        self.pinned = pinned
    }

    var lastFailedFingerprint: String? { lock.withLock { failed } }

    var acceptedCertificate: Data? { lock.withLock { accepted } }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?)
    {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            let trust = challenge.protectionSpace.serverTrust
        else {
            return (.performDefaultHandling, nil)
        }
        if SecTrustEvaluateWithError(trust, nil) {
            return (.performDefaultHandling, nil)
        }
        let fingerprint = Self.fingerprint(of: trust)
        lock.withLock { failed = fingerprint }
        if Self.accepts(
            challengeHost: challenge.protectionSpace.host, host: host, pinned: pinned, presented: fingerprint)
        {
            let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first.map {
                SecCertificateCopyData($0) as Data
            }
            lock.withLock { accepted = leaf }
            return (.useCredential, URLCredential(trust: trust))
        }
        return (.cancelAuthenticationChallenge, nil)
    }

    static func accepts(challengeHost: String, host: String, pinned: String?, presented: String?) -> Bool {
        guard let pinned, let presented else { return false }
        return challengeHost.caseInsensitiveCompare(host) == .orderedSame && pinned == presented
    }

    static func fingerprint(of trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else {
            return nil
        }
        return fingerprint(der: SecCertificateCopyData(leaf) as Data)
    }

    static func pem(der: Data) -> String {
        let body = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN CERTIFICATE-----\n\(body)\n-----END CERTIFICATE-----\n"
    }

    static func fingerprint(der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}
