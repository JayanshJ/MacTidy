import SwiftUI

/// MacTidy's design system. A small set of tokens and reusable components so
/// the app reads as one designed product instead of default SwiftUI.
///
/// Direction: "pro tool / dashboard" — calm, data-dense, monospace accents,
/// one strong accent color (teal), generous whitespace, subtle dividers.
enum Theme {
    /// The app's accent: a teal/cyan that reads as "clean / tidy" and is
    /// distinct from Apple's default blue. Applied as the window tint so every
    /// button, toggle, and progress bar picks it up.
    static let accent = Color(red: 0.13, green: 0.62, blue: 0.60)

    /// Semantic colors for the safety story. Green = reclaimed/good,
    /// orange = caution/suggest-only, red = blocked, gray = neutral.
    enum Status {
        static let good = Color.green
        static let caution = Color.orange
        static let blocked = Color.red
        static let neutral = Color.secondary
    }

    /// Spacing scale (points). Use these instead of ad-hoc literals so padding
    /// is consistent and composable across views.
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
    }

    /// Card corner radius and stroke. One value so every card matches.
    static let cardRadius: CGFloat = 12
}

/// Reusable card surface. Replaces the copy-pasted
/// `.background(.quaternary.opacity(0.5), in: RoundedRectangle)` pattern with
/// a consistent rounded surface plus a hairline border for definition.
struct Card: ViewModifier {
    var padded: Bool = true

    func body(content: Content) -> some View {
        content
            .padding(padded ? Theme.Spacing.md : 0)
            .background(
                RoundedRectangle(cornerRadius: Theme.cardRadius)
                    .fill(.quaternary.opacity(0.45))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius)
                    .strokeBorder(.separator.opacity(0.5), lineWidth: 0.5)
            )
    }
}

extension View {
    /// Standard card treatment. Pass `padded: false` when the content manages
    /// its own padding (e.g. a List inside a card).
    func cardStyle(padded: Bool = true) -> some View {
        modifier(Card(padded: padded))
    }
}

/// A compact pill badge with a tinted background. Used for category tags,
/// "suggest-only", "loaded", clone/extra-copy markers, etc. Replaces the
/// repeated `.padding(.horizontal, 4).background(.tint.opacity(0.25), in:
/// Capsule())` pattern across views.
struct Badge: View {
    let text: String
    var tint: Color = Theme.accent
    var filled: Bool = false

    var body: some View {
        Text(text)
            .font(.caption2.bold())
            .textCase(.uppercase)
            .tracking(0.2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(filled ? Color.white : tint)
            .background(
                Capsule().fill(filled ? tint : tint.opacity(0.18))
            )
    }
}