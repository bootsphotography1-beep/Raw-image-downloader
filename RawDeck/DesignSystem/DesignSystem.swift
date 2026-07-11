import SwiftUI
import AppKit

// MARK: - RawDeck Design System
//
// Single source of truth for color, typography, spacing, motion, and
// reusable SwiftUI primitives. Every view in the app should reach for
// these tokens instead of hard-coded values.
//
// Why a design system here?
// - Pro photo apps are color-accurate by convention. We lock the chrome
//   to a fixed neutral dark palette so it never flips light/dark based
//   on system appearance — that protects the user's color perception
//   of the photos they're culling.
// - All metadata values render in monospaced digits. Eyeballing numeric
//   values when they're tabular is much faster when columns line up.
// - Spacing and radii come from a 4-pt scale. No magic numbers in views.
//
// Token reference: see vault page "rawdeck-ui-redesign-2026-06-29".

// MARK: - Color tokens

public enum RDColor {

    // Surface (chrome — never affected by system appearance)
    public static let surfaceBase      = Color(red: 0.071, green: 0.071, blue: 0.078)  // #121214
    public static let surfaceRaised    = Color(red: 0.102, green: 0.102, blue: 0.110)  // #1A1A1C
    public static let surfaceElevated  = Color(red: 0.137, green: 0.137, blue: 0.149)  // #232326
    public static let surfaceOverlay   = Color(red: 0.067, green: 0.067, blue: 0.071).opacity(0.85) // scrim

    // Stage (photo viewing — true black, not off-black, so the
    // sensor pixels are seen against the deepest possible void)
    public static let stageBlack       = Color.black
    public static let stageGutter      = Color(red: 0.039, green: 0.039, blue: 0.043)  // #0A0A0B

    // Borders / hairlines
    public static let hairline         = Color.white.opacity(0.06)
    public static let hairlineStrong   = Color.white.opacity(0.12)
    public static let hairlineAccent   = Color.white.opacity(0.20)

    // Text (off-white; pure white is reserved for the photo stage)
    public static let textPrimary      = Color(red: 0.94, green: 0.94, blue: 0.95)     // #F0F0F2
    public static let textSecondary    = Color(red: 0.66, green: 0.66, blue: 0.69)     // #A8A8B0
    public static let textTertiary     = Color(red: 0.42, green: 0.42, blue: 0.45)     // #6B6B73
    public static let textOnStage      = Color.white
    public static let textOnStageDim   = Color.white.opacity(0.60)

    // Accents — single accent, low-saturation, pro-leaning
    public static let accentPrimary    = Color(red: 0.42, green: 0.62, blue: 0.96)     // #6B9EF5, deliberate blue
    public static let accentPrimaryDim = accentPrimary.opacity(0.18)
    public static let accentSubtle     = Color(red: 0.78, green: 0.78, blue: 0.82)     // #C7C7D1

    // Semantic
    public static let positive         = Color(red: 0.40, green: 0.78, blue: 0.55)     // muted green, not kelly
    public static let warning          = Color(red: 0.95, green: 0.70, blue: 0.30)
    public static let destructive      = Color(red: 0.95, green: 0.40, blue: 0.40)     // muted red
    public static let destructiveDim   = destructive.opacity(0.18)

    // Star rating — the *one* place a warm color appears, and only
    // for rated photos. Unrated: outline only in textTertiary.
    public static let starActive       = Color(red: 0.98, green: 0.84, blue: 0.42)     // warm amber, Lightroom-adjacent
    public static let starActiveDim    = starActive.opacity(0.18)
    public static let starInactive     = textTertiary
}

// MARK: - Typography

public enum RDType {

    // Display & chrome — SF Pro Display, Apple's system geometric sans.
    public static let displayLarge: Font = .system(size: 22, weight: .semibold, design: .default)
    public static let titleMedium:  Font = .system(size: 15, weight: .semibold, design: .default)
    public static let body:         Font = .system(size: 13, weight: .regular, design: .default)
    public static let caption:      Font = .system(size: 11, weight: .regular, design: .default)
    public static let captionMono:  Font = .system(size: 11, weight: .regular, design: .monospaced)
    public static let captionMonoEmph: Font = .system(size: 11, weight: .semibold, design: .monospaced)
    public static let microMono:    Font = .system(size: 10, weight: .medium, design: .monospaced)

    // Eyebrow / section label — uppercase, wide tracking, 10pt.
    // USED SPARINGLY: max one per top-level panel.
    public static let eyebrow:      Font = .system(size: 10, weight: .semibold, design: .default)
}

// MARK: - Spacing

public enum RDSpace {
    public static let xxs: CGFloat = 2
    public static let xs:  CGFloat = 4
    public static let s:   CGFloat = 8
    public static let m:   CGFloat = 12
    public static let l:   CGFloat = 16
    public static let xl:  CGFloat = 24
    public static let xxl: CGFloat = 32
    public static let xxxl: CGFloat = 48
}

// MARK: - Radii

public enum RDRadius {
    // Single shape system: cards 8, panels 12, buttons 6, pills = full.
    public static let card:    CGFloat = 8
    public static let panel:   CGFloat = 12
    public static let button:  CGFloat = 6
    public static let pill:    CGFloat = 999
    public static let none:    CGFloat = 0
}

// MARK: - Motion

public enum RDMotion {
    // Pro apps, not playful. Short, restrained, no bounce.
    public static let fast:     Double = 0.12
    public static let base:     Double = 0.18
    public static let slow:     Double = 0.28

    public static let easeOut:  Animation = .timingCurve(0.16, 1.0, 0.3, 1.0, duration: base)
    public static let easeInOut: Animation = .timingCurve(0.4, 0.0, 0.2, 1.0, duration: base)
    public static let snap:     Animation = .timingCurve(0.4, 0.0, 0.6, 1.0, duration: fast)
}

// MARK: - Reusable view modifiers

public struct RDChromeRow: ViewModifier {
    let height: CGFloat
    public func body(content: Content) -> some View {
        content
            .frame(height: height)
            .padding(.horizontal, RDSpace.l)
            .background(RDColor.surfaceRaised)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(RDColor.hairline)
                    .frame(height: 0.5)
            }
    }
}

public struct RDCard: ViewModifier {
    let radius: CGFloat
    public func body(content: Content) -> some View {
        content
            .background(RDColor.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(RDColor.hairline, lineWidth: 0.5)
            )
    }
}

public struct RDButtonStyle: ViewModifier {
    let kind: Kind
    public enum Kind { case primary, secondary, ghost, destructive }
    public func body(content: Content) -> some View {
        content
            .font(RDType.body)
            .padding(.horizontal, RDSpace.m)
            .padding(.vertical, RDSpace.xs + 2)
            .foregroundStyle(foreground)
            .background(
                RoundedRectangle(cornerRadius: RDRadius.button, style: .continuous)
                    .fill(background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: RDRadius.button, style: .continuous)
                    .strokeBorder(border, lineWidth: 0.5)
            )
            .contentShape(Rectangle())
    }
    private var foreground: Color {
        switch kind {
        case .primary:     return RDColor.surfaceBase
        case .secondary:   return RDColor.textPrimary
        case .ghost:       return RDColor.textSecondary
        case .destructive: return RDColor.textPrimary
        }
    }
    private var background: Color {
        switch kind {
        case .primary:     return RDColor.accentPrimary
        case .secondary:   return RDColor.surfaceElevated
        case .ghost:       return .clear
        case .destructive: return RDColor.destructive
        }
    }
    private var border: Color {
        switch kind {
        case .primary:     return .clear
        case .secondary:   return RDColor.hairlineStrong
        case .ghost:       return .clear
        case .destructive: return .clear
        }
    }
}

public extension View {
    func rdChromeRow(height: CGFloat = 36) -> some View {
        modifier(RDChromeRow(height: height))
    }
    func rdCard(radius: CGFloat = RDRadius.card) -> some View {
        modifier(RDCard(radius: radius))
    }
    func rdButton(_ kind: RDButtonStyle.Kind = .secondary) -> some View {
        modifier(RDButtonStyle(kind: kind))
    }
}

// MARK: - Section header

/// Sparse section header — uppercase, wide tracking, max one per panel.
/// Internal padding matches the spec's density (no giant margins).
public struct RDSectionHeader: View {
    let title: String
    public init(_ title: String) { self.title = title }
    public var body: some View {
        Text(title.uppercased())
            .font(RDType.eyebrow)
            .tracking(1.2)
            .foregroundStyle(RDColor.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, RDSpace.l)
            .padding(.bottom, RDSpace.xs)
    }
}

// MARK: - 5-Star control (replaces the in-place StarRow)

/// Five-star input/display. Filled stars are warm amber; unfilled are
/// hairline outlines.
public struct RDStarRow: View {
    let rating: Int
    var size: CGFloat = 11
    var isRejected: Bool = false
    var isInteractive: Bool = false
    var onSet: ((Int) -> Void)? = nil

    public init(rating: Int, size: CGFloat = 11, isRejected: Bool = false, isInteractive: Bool = false, onSet: ((Int) -> Void)? = nil) {
        self.rating = rating
        self.size = size
        self.isRejected = isRejected
        self.isInteractive = isInteractive
        self.onSet = onSet
    }

    public var body: some View {
        HStack(spacing: 1) {
            ForEach(1...5, id: \.self) { i in
                star(for: i)
                    .frame(width: size, height: size)
                    // Spring-pop on rating change. See StarPopModifier below.
                    .modifier(StarPopModifier(index: i, rating: rating))
            }
        }
    }

    @ViewBuilder
    private func star(for index: Int) -> some View {
        let filled = index <= rating
        let color: Color = isRejected
            ? RDColor.destructive
            : (filled ? RDColor.starActive : RDColor.starInactive)

        if isInteractive {
            Button {
                onSet?(index == rating ? 0 : index)
            } label: {
                Image(systemName: filled ? "star.fill" : "star")
                    .resizable()
                    .foregroundStyle(color)
            }
            .buttonStyle(.plain)
        } else {
            Image(systemName: filled ? "star.fill" : "star")
                .resizable()
                .foregroundStyle(color)
        }
    }
}

// MARK: - Numeric readout (monospaced, tabular)

/// Tabular numeric readout for camera raw values. Always monospaced,
/// always right-aligned. Dim variant for un-inferred / set-to-zero
/// values.
public struct RDNumberReadout: View {
    let value: Double
    var format: Format = .signed
    var dimmed: Bool = false
    public enum Format {
        case signed
        case ev
        case percent
        case integer
        case kelvin
    }
    public init(_ value: Double, format: Format = .signed, dimmed: Bool = false) {
        self.value = value
        self.format = format
        self.dimmed = dimmed
    }
    public var body: some View {
        Text(formatted)
            .font(RDType.captionMonoEmph)
            .monospacedDigit()
            .foregroundStyle(dimmed ? RDColor.textTertiary : RDColor.textPrimary)
            .frame(minWidth: 72, alignment: .trailing)
    }
    private var formatted: String {
        if abs(value) < 0.005 && format != .integer && format != .kelvin { return "0" }
        switch format {
        case .signed:  return String(format: "%+.2f", value)
        case .ev:      return String(format: "%+.2f EV", value)
        case .percent: return String(format: "%+.0f%%", value)
        case .integer: return "\(Int(value.rounded()))"
        case .kelvin:  return "\(Int(value.rounded())) K"
        }
    }
}

// MARK: - Nav rail (left-edge icon stack)

/// Left-edge vertical icon rail. Replaces the top "tabs" pattern
/// with a Lightroom / Capture One style sidebar.
///
/// Each item is a 44×44pt hit target with a 24pt SF Symbol glyph.
/// Active state: accent-colored glyph + 2pt left-edge accent bar.
/// Inactive: secondary-text glyph. Hover: primary-text glyph on a
/// surfaceElevated pill.
///
/// Caller provides the binding to the active mode and a list of
/// (id, label, systemImage) items. The rail is intentionally dumb —
/// it doesn't know about Library vs Colorway; that's the caller's
/// job to interpret the selected id.
public struct RDNavItem: Identifiable, Hashable {
    public let id: String
    public let label: String
    public let systemImage: String
    public init(id: String, label: String, systemImage: String) {
        self.id = id
        self.label = label
        self.systemImage = systemImage
    }
}

public struct RDNavRail: View {
    @Binding var selection: String
    let items: [RDNavItem]

    public init(selection: Binding<String>, items: [RDNavItem]) {
        self._selection = selection
        self.items = items
    }

    public var body: some View {
        VStack(spacing: RDSpace.xs) {
            ForEach(items) { item in
                navButton(for: item)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, RDSpace.s)
        .frame(width: 56)
        .background(RDColor.surfaceRaised)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(RDColor.hairline)
                .frame(width: 0.5)
        }
    }

    @ViewBuilder
    private func navButton(for item: RDNavItem) -> some View {
        let isActive = selection == item.id
        Button {
            selection = item.id
        } label: {
            VStack(spacing: 2) {
                ZStack(alignment: .leading) {
                    // Hover/active pill background.
                    if isActive {
                        Capsule()
                            .fill(RDColor.accentPrimaryDim)
                            .frame(width: 40, height: 36)
                    } else {
                        EmptyView()
                    }
                    // 2pt left-edge accent bar (active only).
                    if isActive {
                        Capsule()
                            .fill(RDColor.accentPrimary)
                            .frame(width: 2, height: 18)
                            .offset(x: -25)
                    }
                    Image(systemName: item.systemImage)
                        // CRITICAL: keep the same font weight regardless
                        // of active state. SF Symbols' semibold vs regular
                        // weights render at slightly different widths,
                        // and that width change shifts the centered icon
                        // within its frame, which propagates downstream
                        // and causes the main content area to shift left
                        // or right by a pixel or two on click. We vary
                        // only color to indicate active state.
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(isActive
                                         ? RDColor.accentPrimary
                                         : RDColor.textSecondary)
                }
                .frame(width: 44, height: 36)

                Text(item.label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(isActive
                                     ? RDColor.textPrimary
                                     : RDColor.textSecondary)
            }
            .frame(width: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(item.label)
        .accessibilityLabel(item.label)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

// MARK: - Confidence dot

/// Three-state confidence indicator used in Colorway coaching rows.
///
///   ● high   — solid circle, RDColor.positive
///   ◐ medium — half-filled circle, RDColor.warning
///   ○ low    — ring outline, RDColor.textTertiary
///
/// 8pt default. Sized to read at the right edge of a coaching delta
/// row, next to the value. Not interactive on its own — the parent
/// row provides any popover that explains *why*.
public enum RDConfidence: String, CaseIterable, Hashable {
    case high
    case medium
    case low
}

public struct RDConfidenceDot: View {
    var level: RDConfidence
    var size: CGFloat = 8

    public init(_ level: RDConfidence, size: CGFloat = 8) {
        self.level = level
        self.size = size
    }

    @ViewBuilder
    public var body: some View {
        switch level {
        case .high:
            Circle()
                .fill(RDColor.positive)
                .frame(width: size, height: size)
                .help("High confidence")
        case .medium:
            // SF Symbol half-filled circle. We tint via .foregroundStyle.
            Image(systemName: "circle.lefthalf.filled")
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .foregroundStyle(RDColor.warning)
                .help("Medium confidence")
        case .low:
            Circle()
                .strokeBorder(RDColor.textTertiary, lineWidth: 1)
                .frame(width: size, height: size)
                .help("Low confidence")
        }
    }
}

// MARK: - Pixelmator-sent badge

/// Small overlay glyph for thumbnails that have been opened in
/// Pixelmator. Persistent per photo (requires Photo.sentToPixelmator
/// to be added — see spec).
public struct RDPixelmatorSentBadge: View {
    var size: CGFloat = 14
    public init(size: CGFloat = 14) { self.size = size }
    public var body: some View {
        Image(systemName: "wand.and.stars")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .padding(3)
            .foregroundStyle(RDColor.textOnStage)
            .background(
                Circle()
                    .fill(RDColor.surfaceBase.opacity(0.65))
                    .overlay(Circle().strokeBorder(RDColor.hairlineStrong, lineWidth: 0.5))
            )
            .accessibilityLabel("Sent to Pixelmator Pro")
    }
}
