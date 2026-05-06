import Foundation
import SwiftUI

/// Constrains the inline-formatting palette inside Keystone's block editor.
///
/// We allow Foundation's `inlinePresentationIntent` (covers bold, italic,
/// strikethrough, inline code, and combinations of those) plus `link` for
/// hyperlinks. Other attributes in the Foundation scope flow through the
/// editor without restriction.
struct KeystoneFormattingDefinition: AttributedTextFormattingDefinition {
    typealias Scope = AttributeScopes.FoundationAttributes

    var body: some AttributedTextFormattingDefinition<AttributeScopes.FoundationAttributes> {
        ValueConstraint(
            for: \.inlinePresentationIntent,
            values: Self.allowedIntents,
            default: nil
        )
    }

    private static let allowedIntents: Set<InlinePresentationIntent?> = [
        nil,
        .stronglyEmphasized,
        .emphasized,
        .strikethrough,
        .code,
        [.stronglyEmphasized, .emphasized],
        [.stronglyEmphasized, .strikethrough],
        [.emphasized, .strikethrough],
        [.stronglyEmphasized, .code],
        [.emphasized, .code],
        [.stronglyEmphasized, .emphasized, .strikethrough],
        [.stronglyEmphasized, .emphasized, .code],
    ]
}
