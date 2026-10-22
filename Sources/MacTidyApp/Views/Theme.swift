import SwiftUI
import AppKit

/// MacTidy's design system.
///
/// Direction: quiet, native, precise. Neutral surfaces that read as macOS,
/// one accent (spruce in light, mint in dark) spent only on what can be
/// reclaimed and on primary actions. Hierarchy comes from type size and
/// weight, not from boxes: one level of grouped surface, never a card inside
/// a card. Every color is defined for light *and* dark.
enum Theme {
    /// The single accent. Spruce green in light mode, a softer mint in dark so
    /// it keeps contrast without glowing.
    static let accent = Color(light: 0x0B7D6E, dark: 0x4FD1B4)

    /// Semantic status colors. System colors already adapt to appearance.
    enum Status {
        static let good = Theme.accent
        static let caution = Color.orange
        static let blocked = Color.red
        static let neutral = Color.secondary
    }

    // MARK: Surfaces

    /// Page background behind grouped surfaces.
    static let canvas = Color(light: 0xF4F4F5, dark: 0x18181A)
    /// One level of grouped content (a section's rows).
    static let surface = Color(light: 0xFFFFFF, dark: 0x232326)
    /// Hover / pressed state for rows on a surface.
    static let surfaceHover = Color(light: 0xF1F1F3, dark: 0x2C2C30)
    /// Hairline separators and surface edges.
    static let hairline = Color(light: 0x000000, lightAlpha: 0.08, dark: 0xFFFFFF, darkAlpha: 0.08)
    /// Empty part of meters and bars.
    static let track = Color(light: 0x000000, lightAlpha: 0.07, dark: 0xFFFFFF, darkAlpha: 0.09)
    /// The "used, not cleanable" share of the capacity bar.
    static let used = Color(light: 0x8E8E93, dark: 0x6E6E73)

    // MARK: Layout

    /// Spacing scale. Tight inside groups, generous between them.
    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 36
    }

    /// Horizontal page gutter and max readable content width.
    static let gutter: CGFloat = 32
    static let contentMaxWidth: CGFloat = 920

    static let cardRadius: CGFloat = 10
    static let smallRadius: CGFloat = 6

    // MARK: Type

    /// The type ramp. Each step is at least 1.25x the next one down, so the
    /// hierarchy reads at a glance.
    enum Font {
        /// Hero figures (reclaimable total).
        static let display = SwiftUI.Font.system(size: 52, weight: .semibold).monospacedDigit()
        /// Page titles.
        static let title = SwiftUI.Font.system(size: 24, weight: .semibold)
        /// Secondary figures inside rows and stats.
        static let figure = SwiftUI.Font.system(size: 17, weight: .semibold).monospacedDigit()
        /// Section headings above grouped surfaces.
        static let section = SwiftUI.Font.system(size: 13, weight: .semibold)
        static let body = SwiftUI.Font.system(size: 13)
        static let bodyStrong = SwiftUI.Font.system(size: 13, weight: .medium)
        static let caption = SwiftUI.Font.system(size: 11)
    }

    /// Motion: short and decelerating, never bouncy.
    static let ease = Animation.easeOut(duration: 0.22)
}

extension Color {
    /// A color that resolves per appearance.
    init(light: UInt32, lightAlpha: Double = 1, dark: UInt32, darkAlpha: Double = 1) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: isDark ? darkAlpha : lightAlpha)
        })
    }
}

// MARK: - Surfaces

/// The one level of grouped surface. Kept under its old name so every screen
/// adopts the new look; do not nest one inside another.
struct Card: ViewModifier {
    var padded: Bool = true

    func body(content: Content) -> some View {
        content
            .padding(padded ? Theme.Spacing.lg : 0)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            )
    }
}

extension View {
    func cardStyle(padded: Bool = true) -> some View {
        modifier(Card(padded: padded))
    }
}

/// Inset hairline between rows on a surface.
struct RowDivider: View {
    var inset: CGFloat = Theme.Spacing.lg
    var body: some View {
        Rectangle().fill(Theme.hairline).frame(height: 1).padding(.leading, inset)
    }
}

/// A titled group of rows on one surface. Separate rows with `RowDivider`.
struct SurfaceSection<Content: View, Accessory: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    init(_ title: String? = nil, footer: String? = nil,
         @ViewBuilder accessory: () -> Accessory = { EmptyView() },
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            if title != nil || !(Accessory.self == EmptyView.self) {
                HStack(alignment: .firstTextBaseline) {
                    if let title {
                        Text(title).font(Theme.Font.section).foregroundStyle(.secondary)
                    }
                    Spacer()
                    accessory
                }
                .padding(.horizontal, Theme.Spacing.xs)
            }
            VStack(spacing: 0) { content }
                .cardStyle(padded: false)
            if let footer {
                Text(footer)
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Theme.Spacing.xs)
            }
        }
    }
}

/// Standard page: large title, optional subtitle, trailing actions, then
/// content in a centered readable column on the canvas.
struct Page<Content: View, Actions: View>: View {
    let title: String
    var subtitle: String?
    var scrolls = true
    @ViewBuilder var actions: Actions
    @ViewBuilder var content: Content

    init(_ title: String, subtitle: String? = nil, scrolls: Bool = true,
         @ViewBuilder actions: () -> Actions = { EmptyView() },
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.scrolls = scrolls
        self.actions = actions()
        self.content = content()
    }

    var body: some View {
        Group {
            if scrolls {
                ScrollView {
                    column { content }
                        .padding(.bottom, Theme.Spacing.xxl)
                }
            } else {
                column { content.frame(maxHeight: .infinity, alignment: .top) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
    }

    private func column<C: View>(@ViewBuilder _ body: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            PageHeader(title: title, subtitle: subtitle) { actions }
            body()
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.top, Theme.Spacing.xl)
        .frame(maxWidth: Theme.contentMaxWidth, alignment: .leading)
        .frame(maxWidth: .infinity)
    }
}

struct PageHeader<Actions: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(title).font(Theme.Font.title)
                if let subtitle {
                    Text(subtitle).font(Theme.Font.body).foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: Theme.Spacing.lg)
            HStack(spacing: Theme.Spacing.sm) { actions }
                .controlSize(.regular)
        }
    }
}

// MARK: - Small components

/// A short status label. Sentence case, tinted, no border.
struct Badge: View {
    let text: String
    var tint: Color = Theme.accent
    var filled: Bool = false

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(filled ? Color.white : tint)
            .background(Capsule().fill(filled ? tint : tint.opacity(0.14)))
    }
}

/// Thin proportional meter.
struct Meter: View {
    let fraction: Double
    var tint: Color = Theme.accent
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule().fill(tint)
                    .frame(width: max(fraction > 0 ? height : 0, proxy.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: height)
    }
}

/// Disk capacity: in use, safe to clean, worth reviewing, free.
struct CapacityBar: View {
    let total: Int64
    let free: Int64
    let cleanable: Int64
    var review: Int64 = 0
    var height: CGFloat = 10

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let t = max(Double(total), 1)
            let usedAll = max(0, Double(total - free))
            let clean = min(Double(cleanable), usedAll)
            let rev = min(Double(review), usedAll - clean)
            HStack(spacing: 2) {
                Rectangle().fill(Theme.used).frame(width: w * (usedAll - clean - rev) / t)
                if rev > 0 { Rectangle().fill(Theme.accent.opacity(0.4)).frame(width: w * rev / t) }
                Rectangle().fill(Theme.accent).frame(width: w * clean / t)
                Rectangle().fill(Theme.track)
            }
            .clipShape(RoundedRectangle(cornerRadius: height / 2, style: .continuous))
        }
        .frame(height: height)
        .animation(Theme.ease, value: cleanable)
    }
}

/// Legend entry for the capacity bar.
struct LegendItem: View {
    let color: Color
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: Theme.Spacing.xs + 2) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
        .font(Theme.Font.caption)
    }
}

/// Centered quiet empty state.
struct EmptyStateView: View {
    let symbol: String
    let title: String
    var message: String?

    var body: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
                .padding(.bottom, Theme.Spacing.xs)
            Text(title).font(.system(size: 15, weight: .semibold))
            if let message {
                Text(message).font(Theme.Font.body).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
        }
        .padding(Theme.Spacing.xxl)
        .frame(maxWidth: .infinity)
    }
}

/// Hover-highlighted, full-width clickable row on a surface.
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowHover(configuration: configuration)
    }

    private struct RowHover: View {
        let configuration: ButtonStyle.Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .contentShape(Rectangle())
                .background(hovering || configuration.isPressed ? Theme.surfaceHover : Color.clear)
                .onHover { hovering = $0 }
        }
    }
}
