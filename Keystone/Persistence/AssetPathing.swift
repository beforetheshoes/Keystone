import Foundation

/// Filesystem-path helpers for the per-record/per-database `Assets/`
/// layout. The structure on disk is:
///
/// ```
/// Assets/
///   <DatabaseName>/
///     <RecordTitle>-<8-char-record-id>/
///       <original_filename>
/// ```
///
/// Folders are sanitized for filesystem safety; filenames keep the
/// user-visible original (with collision disambiguation via `-2`,
/// `-3`, …). The 8-char id suffix on the record folder makes the
/// folder name stable across pure title-rename collisions and lets us
/// recover the record id from the filesystem if needed.
enum AssetPathing {
    /// Replace path-unsafe characters with `-`, trim, strip leading
    /// dots (so we never accidentally create a hidden folder), and cap
    /// length so the resulting full path stays under typical macOS
    /// limits. Empty inputs fall back to `_`.
    static func sanitize(_ name: String, maxLength: Int = 80) -> String {
        let bad: Set<Character> = ["/", "\\", ":", "?", "<", ">", "|", "*", "\"", "\0"]
        var cleaned = String(name.map { bad.contains($0) ? "-" : $0 })
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        if cleaned.count > maxLength { cleaned = String(cleaned.prefix(maxLength)) }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "_" : cleaned
    }

    /// `<SanitizedTitle>-<short-id>`. Stable suffix means even if the
    /// user has multiple records with the same title, the folders are
    /// distinct, and a folder rename only happens when the title
    /// actually changes.
    static func recordFolderName(title: String, recordID: String) -> String {
        let stub = sanitize(title)
        let short = String(recordID.prefix(8))
        return "\(stub)-\(short)"
    }

    /// Compose the workspace-relative path for an asset attached to a
    /// record. Caller is responsible for ensuring the directory exists
    /// and for resolving filename collisions inside it via
    /// `disambiguateFilename`.
    static func assetRelativePath(
        databaseName: String,
        recordTitle: String,
        recordID: String,
        filename: String
    ) -> String {
        let dbDir = sanitize(databaseName)
        let recDir = recordFolderName(title: recordTitle, recordID: recordID)
        let safeFile = sanitize(filename, maxLength: 200)
        return "Assets/\(dbDir)/\(recDir)/\(safeFile)"
    }

    /// Remove `folder` and any empty ancestor folders up the chain until
    /// hitting a non-empty directory or the provided root (exclusive).
    /// `.DS_Store` is ignored when judging emptiness — macOS sprinkles
    /// it everywhere and we'd never prune anything otherwise.
    /// Used after deleting assets so the per-record / per-database
    /// folder structure doesn't leave behind empty husks.
    static func pruneEmptyAncestors(_ folder: URL, stopAt root: URL) {
        let fm = FileManager.default
        var current = folder.standardizedFileURL
        let stop = root.standardizedFileURL
        while current.path != stop.path,
              current.path.hasPrefix(stop.path) {
            let contents = (try? fm.contentsOfDirectory(
                at: current,
                includingPropertiesForKeys: nil,
                options: []
            )) ?? []
            let meaningful = contents.filter { $0.lastPathComponent != ".DS_Store" }
            guard meaningful.isEmpty else { break }
            // Sweep the .DS_Store first so removeItem doesn't fail on
            // a non-empty folder.
            for noise in contents { try? fm.removeItem(at: noise) }
            do {
                try fm.removeItem(at: current)
            } catch {
                break
            }
            current = current.deletingLastPathComponent().standardizedFileURL
        }
    }

    /// Sweep the entire `Assets/` tree for empty record-level and
    /// database-level folders. Used as a final pass after a bulk
    /// orphan-cleanup so anywhere a record's files were the last
    /// occupants of a folder, the folder itself goes too.
    static func pruneAllEmptyFolders(under assetsRoot: URL) {
        let fm = FileManager.default
        // Walk database-level dirs, then record-level dirs underneath.
        guard let dbDirs = try? fm.contentsOfDirectory(
            at: assetsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else { return }
        for dbDir in dbDirs {
            guard (try? dbDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            if let recordDirs = try? fm.contentsOfDirectory(
                at: dbDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            ) {
                for recordDir in recordDirs {
                    guard (try? recordDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                    pruneEmptyAncestors(recordDir, stopAt: assetsRoot)
                }
            }
            // The recordDir prune may have already taken dbDir if it was
            // its only child, but try again in case dbDir had only
            // subfolders that all got pruned.
            pruneEmptyAncestors(dbDir, stopAt: assetsRoot)
        }
    }

    /// Return a filename that doesn't already exist in `folder`. If
    /// `filename` is taken, appends `-2`, `-3`, … before the extension.
    /// Falls back to a UUID-suffixed name after 99 attempts so the
    /// caller always gets a usable result.
    static func disambiguateFilename(_ filename: String, in folder: URL) -> String {
        let fm = FileManager.default
        let candidate = folder.appendingPathComponent(filename)
        if !fm.fileExists(atPath: candidate.path) { return filename }

        let stem = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        for i in 2...99 {
            let suffix = ext.isEmpty ? "\(stem)-\(i)" : "\(stem)-\(i).\(ext)"
            let alt = folder.appendingPathComponent(suffix)
            if !fm.fileExists(atPath: alt.path) { return suffix }
        }
        let uuid = UUID().uuidString.lowercased()
        return ext.isEmpty ? "\(stem)-\(uuid)" : "\(stem)-\(uuid).\(ext)"
    }
}
