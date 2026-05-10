import Foundation
import CryptoKit
import GRDB
import OSLog
@preconcurrency import SQLiteData

private let rotationLog = Logger(subsystem: "Keystone", category: "ProtectionKeyRotation")

/// One-shot per-account migration that re-keys every protected row from
/// the legacy single workspace key (#9 vintage) to per-record keys
/// (#14). Runs at boot from `Bootstrap.bootstrapKeystoneDatabase` after
/// the SyncEngine is configured.
///
/// **Signal model.** The presence of the legacy workspace key in iCloud
/// Keychain is the only signal of "rotation pending"; its deletion is
/// the only signal of "rotation done." There is no schema column or
/// row-level tracker — the keychain item, once removed, stays removed
/// across all of the user's devices via iCloud Keychain Sync.
///
/// **Restartability.** A crash mid-rotation leaves some rows already
/// re-keyed under their per-record keys and the rest still encrypted
/// under the workspace key. The decrypt path
/// (`ProtectionKeyClient.decryptForRecord`) tries the per-record key
/// first and falls back to the workspace key if that fails, so reads
/// stay correct in either state. The next boot's rotation pass picks
/// up where the previous one left off; rows that already round-trip
/// under the per-record key are detected and skipped.
///
/// **Follow-up.** Once every active install has rotated, the
/// `legacyWorkspaceKey` / `dropLegacyWorkspaceKey` /
/// fall-back-to-workspace-key paths can be deleted in a small follow-up
/// issue.
enum ProtectionKeyRotation {

    /// Run the rotation job. Cheap when there's nothing to do (one
    /// keychain read returns nil → early return). Idempotent.
    static func runIfNeeded(
        writer: any DatabaseWriter,
        keys: ProtectionKeyClient
    ) {
        do {
            guard let workspaceKey = try keys.legacyWorkspaceKey() else {
                // No legacy key — rotation already happened (or this is
                // a fresh install, or #9 never landed on this account).
                return
            }
            rotationLog.notice("starting per-record key rotation")

            // Pull the rows that need rotation. We don't care WHICH
            // rows are still on the workspace key vs. already on a
            // per-record key — the per-row decrypt-with-record-key probe
            // handles that classification.
            let work = try writer.read { db in
                try ProtectedRowsToRotate.fetch(db)
            }

            if work.isEmpty {
                rotationLog.notice("no encrypted rows present; dropping legacy workspace key")
                try keys.dropLegacyWorkspaceKey()
                return
            }

            var rotatedRows = 0
            var skippedAlreadyRotated = 0
            try writer.write { db in
                for entry in work {
                    let perRecord = try keys.recordKey(entry.recordID)

                    // Decide which key the existing ciphertext is
                    // under. Try per-record first; if that succeeds
                    // the row was already rotated on a previous
                    // (interrupted) pass and we skip the re-encrypt.
                    if decryptsUnder(perRecord, ciphertext: entry.ciphertext) {
                        skippedAlreadyRotated += 1
                        continue
                    }

                    // Workspace-key path. If this also fails the row
                    // is corrupt or was never workspace-encrypted to
                    // begin with — log and move on. Don't crash the
                    // boot flow over a single bad row.
                    let plaintext: Data
                    do {
                        let box = try AES.GCM.SealedBox(combined: entry.ciphertext)
                        plaintext = try AES.GCM.open(box, using: workspaceKey)
                    } catch {
                        rotationLog.error("row \(entry.kind.rawValue, privacy: .public) id=\(entry.rowID, privacy: .public) decrypt-with-workspace-key failed: \(String(describing: error), privacy: .public)")
                        continue
                    }

                    let resealed = try AES.GCM.seal(plaintext, using: perRecord)
                    guard let combined = resealed.combined else { continue }

                    let now = AppDatabase.isoFormatter.string(from: Date())
                    switch entry.kind {
                    case .propertyValue:
                        try db.execute(
                            sql: "UPDATE property_values SET enc_value = ?, updated_at = ? WHERE id = ?",
                            arguments: [combined, now, entry.rowID]
                        )
                    case .blockContent:
                        try db.execute(
                            sql: "UPDATE blocks SET enc_content = ?, updated_at = ? WHERE id = ?",
                            arguments: [combined, now, entry.rowID]
                        )
                    }
                    rotatedRows += 1
                }
            }

            // Asset files (`KSTENC1` magic + AES-GCM combined) follow
            // the same rotation rule. Looped per-asset since the
            // re-encrypt is a file-level operation, not a SQL update.
            try rotateAssets(writer: writer, keys: keys, workspaceKey: workspaceKey)

            rotationLog.notice("rotation complete — rotated=\(rotatedRows) skipped-already=\(skippedAlreadyRotated)")
            try keys.dropLegacyWorkspaceKey()
            rotationLog.notice("dropped legacy workspace key")
        } catch {
            // Don't let rotation failures block app boot. The decrypt
            // fallback keeps reads working under the workspace key
            // until the next attempt. Loud log so the issue surfaces
            // in Console.app.
            rotationLog.error("protection-key rotation failed: \(String(describing: error), privacy: .public)")
        }
    }

    private static func rotateAssets(
        writer: any DatabaseWriter,
        keys: ProtectionKeyClient,
        workspaceKey: SymmetricKey
    ) throws {
        let assetEntries: [(assetID: String, recordID: String, relativePath: String)]
        assetEntries = try writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, record_id, relative_path
                FROM assets
                WHERE is_encrypted = 1
            """).compactMap { row in
                guard let rid: String = row["record_id"] else { return nil }
                return (row["id"], rid, row["relative_path"])
            }
        }

        let magic = Data("KSTENC1".utf8)
        for entry in assetEntries {
            let url = AppDatabase.absoluteURL(forRelativePath: entry.relativePath)
            guard let blob = try? Data(contentsOf: url),
                  blob.count >= magic.count,
                  blob.prefix(magic.count) == magic else {
                continue
            }
            let cipher = blob.suffix(from: magic.count)
            let perRecord = try keys.recordKey(entry.recordID)

            // Already rotated?
            if decryptsUnder(perRecord, ciphertext: Data(cipher)) {
                continue
            }

            let plain: Data
            do {
                let box = try AES.GCM.SealedBox(combined: Data(cipher))
                plain = try AES.GCM.open(box, using: workspaceKey)
            } catch {
                rotationLog.error("asset \(entry.assetID, privacy: .public) decrypt-with-workspace-key failed; leaving in-place")
                continue
            }
            let resealed = try AES.GCM.seal(plain, using: perRecord)
            guard let combined = resealed.combined else { continue }
            var out = Data("KSTENC1".utf8)
            out.append(combined)
            try out.write(to: url, options: .atomic)
        }
    }
}

/// Helper: every `(record_id, ciphertext)` pair we may need to
/// re-encrypt during rotation. Pulls property_values and blocks rows
/// that have non-empty `enc_value` / `enc_content`.
private enum ProtectedRowsToRotate {
    enum Kind: String { case propertyValue, blockContent }
    struct Entry {
        let kind: Kind
        let rowID: String
        let recordID: String
        let ciphertext: Data
    }

    static func fetch(_ db: Database) throws -> [Entry] {
        var out: [Entry] = []
        let pvRows = try Row.fetchAll(db, sql: """
            SELECT id, record_id, enc_value
            FROM property_values
            WHERE enc_value IS NOT NULL
        """)
        for row in pvRows {
            guard let cipher: Data = row["enc_value"], !cipher.isEmpty else { continue }
            out.append(Entry(
                kind: .propertyValue,
                rowID: row["id"],
                recordID: row["record_id"],
                ciphertext: cipher
            ))
        }
        let blockRows = try Row.fetchAll(db, sql: """
            SELECT id, record_id, enc_content
            FROM blocks
            WHERE enc_content IS NOT NULL
        """)
        for row in blockRows {
            guard let cipher: Data = row["enc_content"], !cipher.isEmpty else { continue }
            out.append(Entry(
                kind: .blockContent,
                rowID: row["id"],
                recordID: row["record_id"],
                ciphertext: cipher
            ))
        }
        return out
    }
}

/// True iff `ciphertext` opens cleanly under `key`. Used by rotation
/// to detect already-rotated rows so an interrupted pass picks up
/// where it left off without double-encrypting.
private func decryptsUnder(_ key: SymmetricKey, ciphertext: Data) -> Bool {
    guard let box = try? AES.GCM.SealedBox(combined: ciphertext) else { return false }
    return (try? AES.GCM.open(box, using: key)) != nil
}
