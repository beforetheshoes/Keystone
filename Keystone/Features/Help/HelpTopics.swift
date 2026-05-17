import Foundation

/// Single source of truth for the Help table-of-contents. Topic IDs match the
/// markdown filenames under `Keystone/Resources/Help/`.
enum HelpTopics {
    struct Topic: Equatable, Sendable, Identifiable {
        let id: String        // resource basename (sans .md), e.g., "01-welcome"
        let title: String     // display name in TOC and breadcrumb
    }

    static let all: [Topic] = [
        .init(id: "01-welcome",                title: "Welcome"),
        .init(id: "02-quick-start",            title: "Quick start"),
        .init(id: "03-records-and-databases",  title: "Records & databases"),
        .init(id: "04-properties",             title: "Properties"),
        .init(id: "05-tags",                   title: "Tags"),
        .init(id: "06-relations",              title: "Relations"),
        .init(id: "07-block-editor",           title: "Block editor"),
        .init(id: "08-files-and-attachments",  title: "Files & attachments"),
        .init(id: "09-quick-capture",          title: "Quick capture"),
        .init(id: "10-command-palette",        title: "Command palette"),
        .init(id: "11-sync",                   title: "Sync"),
        .init(id: "12-keyboard-shortcuts",     title: "Keyboard shortcuts"),
        .init(id: "13-architecture",           title: "Architecture"),
        .init(id: "14-profile-images",         title: "Profile images"),
        .init(id: "15-storage-location",       title: "Storage location"),
        .init(id: "16-inbox",                  title: "Inbox folder"),
        .init(id: "17-travel",                 title: "Travel"),
        .init(id: "18-enrichment",             title: "Enrichment & API keys"),
        .init(id: "19-calendar",               title: "Calendar"),
        .init(id: "20-collections",            title: "Collections"),
        .init(id: "21-maintenance-scheduling", title: "Maintenance scheduling"),
        .init(id: "22-privacy-lock",           title: "Privacy lock"),
        .init(id: "23-sharing",                title: "Sharing"),
        .init(id: "24-sync-diagnostics",       title: "Sync diagnostics"),
    ]

    static let defaultTopicID = "01-welcome"

    static func topic(id: String) -> Topic? {
        all.first { $0.id == id } ?? all.first
    }

    /// The bundle that owns the Help resources. Tests can override this to point
    /// at the test-target bundle when needed.
    nonisolated(unsafe) static var bundle: Bundle = .main

    static func loadMarkdown(topicID: String) -> String {
        guard let url = resourceURL(for: topicID),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "# \(topicID)\n\nThis topic is missing."
        }
        return text
    }

    /// Resolve a topic's bundled markdown URL. Xcode flattens the `Help/`
    /// folder into the bundle's Resources root by default, so try the
    /// flat path first and fall back to the namespaced path for folder
    /// references.
    static func resourceURL(for topicID: String) -> URL? {
        bundle.url(forResource: topicID, withExtension: "md")
            ?? bundle.url(forResource: topicID, withExtension: "md", subdirectory: "Help")
    }
}
