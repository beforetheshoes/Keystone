import Foundation
import GRDB

/// Decrypts an `is_encrypted` asset to a temp file so QuickLook /
/// NSWorkspace.open can hand it off to a plaintext-aware viewer
/// without exposing the on-disk ciphertext.
///
/// The temp file lives at `NSTemporaryDirectory()/keystone-asset-<uuid>/<originalFilename>`
/// — a per-session subdirectory so multiple opens don't collide and we
/// can sweep the whole directory on app quit. We do NOT proactively
/// delete the file after the viewer closes (no signal back from QL),
/// so the temp directory accumulates until the OS reclaims it.
///
/// Plaintext assets short-circuit: this returns the asset's
/// `absoluteURL` directly, no copy.
enum EncryptedAssetReader {
    /// Returns a file URL safe to hand to NSWorkspace / QLPreview.
    /// For plaintext assets, this is the asset's actual location;
    /// for encrypted assets, it's a freshly-decrypted temp file.
    static func decryptedURL(
        for asset: AssetRecord,
        encryptor: ValueEncryptor
    ) throws -> URL {
        guard asset.isEncrypted else { return asset.absoluteURL }
        let cipherURL = asset.absoluteURL
        let blob = try Data(contentsOf: cipherURL)
        let magic = Data("KSTENC1".utf8)
        guard blob.count >= magic.count, blob.prefix(magic.count) == magic else {
            // Flag says encrypted, file says otherwise — return the
            // raw bytes via temp-copy since the in-place URL would
            // also work, but keep the contract that "encrypted asset
            // returns a temp file" so callers don't grow conditional
            // cleanup paths.
            return try copyToTemp(blob, originalFilename: asset.originalFilename)
        }
        let inner = blob.suffix(from: magic.count)
        let base64 = try encryptor.decrypt(Data(inner))
        guard let plain = Data(base64Encoded: base64) else {
            throw ValueEncryptor.EncryptorError.nonUTF8
        }
        return try copyToTemp(plain, originalFilename: asset.originalFilename)
    }

    /// Drop a per-session subdirectory under NSTemporaryDirectory and
    /// stash the plaintext bytes inside under their original filename.
    /// QuickLook / NSWorkspace key the file type off the extension, so
    /// preserving the original filename matters.
    private static func copyToTemp(_ data: Data, originalFilename: String) throws -> URL {
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("keystone-asset-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        let dest = tmpRoot.appendingPathComponent(originalFilename)
        try data.write(to: dest, options: .atomic)
        return dest
    }
}
