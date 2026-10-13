// Checks the appcast a release publishes, the way Sparkle will on users' Macs: the item for this
// build exists, points at the archive, and the archive's EdDSA signature verifies against the
// public key baked into the app (SUPublicEDKey). Run by .github/workflows/release.yml after
// generate_appcast, so a Sparkle private key that does not match the public key fails the
// release instead of every update.
//
//   swift Scripts/verify-appcast.swift <appcast.xml> <archive.zip> <public-key> <version> <build> <download-url-prefix>

import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("verify-appcast: \(message)\n".utf8))
    exit(1)
}

let arguments = CommandLine.arguments.dropFirst()
guard arguments.count == 6 else {
    fail("usage: verify-appcast.swift <appcast.xml> <archive.zip> <public-key> <version> <build> <download-url-prefix>")
}
let (appcastPath, archivePath, publicKeyText, version, build, downloadPrefix) = (
    arguments[arguments.startIndex], arguments[arguments.startIndex + 1], arguments[arguments.startIndex + 2],
    arguments[arguments.startIndex + 3], arguments[arguments.startIndex + 4], arguments[arguments.startIndex + 5]
)

guard let keyData = Data(base64Encoded: publicKeyText),
      let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
else { fail("the public key is not base64 of a 32-byte Ed25519 key") }

let document: XMLDocument
do {
    document = try XMLDocument(contentsOf: URL(fileURLWithPath: appcastPath))
} catch {
    fail("cannot read \(appcastPath): \(error.localizedDescription)")
}

func child(_ element: XMLElement, _ name: String) -> String? {
    element.elements(forName: name).first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
}

let items = (try? document.nodes(forXPath: "/rss/channel/item"))?.compactMap { $0 as? XMLElement } ?? []
guard let item = items.first(where: { child($0, "sparkle:version") == build }) else {
    fail("no item with sparkle:version \(build) in \(appcastPath)")
}
guard child(item, "sparkle:shortVersionString") == version else {
    fail("the item for build \(build) is not version \(version)")
}
guard let enclosure = item.elements(forName: "enclosure").first,
      let url = enclosure.attribute(forName: "url")?.stringValue,
      let signatureText = enclosure.attribute(forName: "sparkle:edSignature")?.stringValue,
      let length = enclosure.attribute(forName: "length")?.stringValue
else { fail("the item for build \(build) has no signed enclosure") }

let archiveURL = URL(fileURLWithPath: archivePath)
guard url == downloadPrefix + archiveURL.lastPathComponent else {
    fail("the enclosure URL is \(url), expected \(downloadPrefix)\(archiveURL.lastPathComponent)")
}
guard let archive = try? Data(contentsOf: archiveURL) else { fail("cannot read \(archivePath)") }
guard length == String(archive.count) else {
    fail("the enclosure length is \(length), the archive has \(archive.count) bytes")
}
guard let signature = Data(base64Encoded: signatureText), publicKey.isValidSignature(signature, for: archive) else {
    fail("the archive's EdDSA signature does not verify against SUPublicEDKey; the Sparkle private key does not match the public key")
}
print("appcast: build \(build) (\(version)) at \(url), \(archive.count) bytes, EdDSA signature valid")
