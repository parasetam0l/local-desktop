// Checks that an update's EdDSA signature (from Sparkle's sign_update) is
// valid for the public key in the app (SUPublicEDKey): the same check an
// installed LocalDesktop makes before it installs the update.
//
// Usage: swift Scripts/verify-update-signature.swift <SUPublicEDKey> <signature> <file>

import CryptoKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 4 else {
    FileHandle.standardError.write(Data("usage: verify-update-signature.swift <public-key> <signature> <file>\n".utf8))
    exit(2)
}
guard let keyData = Data(base64Encoded: arguments[1]),
      let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
    FileHandle.standardError.write(Data("The public key is not a base64 Ed25519 key.\n".utf8))
    exit(1)
}
guard let signature = Data(base64Encoded: arguments[2]) else {
    FileHandle.standardError.write(Data("The signature is not base64.\n".utf8))
    exit(1)
}
let file = try Data(contentsOf: URL(fileURLWithPath: arguments[3]), options: .alwaysMapped)
guard key.isValidSignature(signature, for: file) else {
    FileHandle.standardError.write(Data("The signature doesn't match the app's public key.\n".utf8))
    exit(1)
}
print("The signature matches the app's public key.")
