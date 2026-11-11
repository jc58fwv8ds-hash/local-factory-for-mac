import Foundation
import Security

/// The development team of the Apple Development certificate already in this Mac's keychain (2026-11-10, the user:
/// 「Xcode でのサインインや、iPhone 側で開発者を信頼する操作については君に頼んだらいつもやってくれているからファクトリーにも
/// 頼みたい」). Once Xcode has signed in, its certificate stays; a project without DEVELOPMENT_TEAM is built with this team
/// passed on the command line only. The team is never written to the project or the workspace.
public enum SigningTeamDetector {
    /// The team when this Mac holds Apple Development certificates of exactly one team; nil for none or several.
    public static func team() -> String? {
        let teams = Set(certificateSubjects().compactMap(teamIdentifier(fromSubjectUnits:)))
        return teams.count == 1 ? teams.first : nil
    }

    /// A team identifier is ten capital letters and digits.
    public static func isTeamIdentifier(_ value: String) -> Bool {
        value.range(of: #"^[A-Z0-9]{10}$"#, options: .regularExpression) != nil
    }

    /// The organisational unit of an Apple Development certificate is its team.
    static func teamIdentifier(fromSubjectUnits units: [String]) -> String? {
        units.first(where: isTeamIdentifier)
    }

    /// The organisational units of each Apple Development certificate in the keychain.
    static func certificateSubjects() -> [[String]] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnRef as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let certificates = result as? [SecCertificate] else { return [] }
        return certificates.compactMap { certificate -> [String]? in
            guard let summary = SecCertificateCopySubjectSummary(certificate) as String?,
                  summary.hasPrefix("Apple Development") else { return nil }
            let keys = [kSecOIDX509V1SubjectName] as CFArray
            guard let values = SecCertificateCopyValues(certificate, keys, nil) as? [String: Any],
                  let subject = values[kSecOIDX509V1SubjectName as String] as? [String: Any],
                  let fields = subject[kSecPropertyKeyValue as String] as? [[String: Any]] else { return nil }
            return fields.compactMap { field in
                (field[kSecPropertyKeyLabel as String] as? String) == (kSecOIDOrganizationalUnitName as String)
                    ? field[kSecPropertyKeyValue as String] as? String : nil
            }
        }
    }
}
