import Foundation
import CryptoKit
let encoded=try String(contentsOfFile:CommandLine.arguments[1],encoding:.utf8).trimmingCharacters(in:.whitespacesAndNewlines)
guard let seed=Data(base64Encoded:encoded) else {fatalError("Invalid update signing key")}
let key=try Curve25519.Signing.PrivateKey(rawRepresentation:seed)
print(key.publicKey.rawRepresentation.base64EncodedString())
