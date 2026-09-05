import AppKit
import SwiftUI

/// Shared visual roles. Content stays quiet; accent belongs to focus and actions.
enum PanelTheme {
    static let accentColor = adaptive(light: 0x4D6997, dark: 0xAAC1EC)
    static let accent = Color(nsColor: accentColor)
    static let accentForeground = color(light: 0xFFFFFF, dark: 0x202C43)
    static let favorite = color(light: 0x947840, dark: 0xD1B577)
    static let success = color(light: 0x5C7567, dark: 0xAAC1B1)
    static let imageTint = accent
    static let fileTint = accent
    static let inkColor = adaptive(light: 0x252930, dark: 0xECEEF2)
    static let ink = Color(nsColor: inkColor)
    static let secondary = color(light: 0x656C77, dark: 0xADB3BE)
    static let muted = color(light: 0x747B85, dark: 0x9BA1AC)
    static let selection = color(light: 0xE9EFF8, dark: 0x354158)
    static let selectionBorder = color(light: 0xD6E1F0, dark: 0x465570)
    static let chrome = color(light: 0xF4F5F7, dark: 0x292C31)
    static let canvas = color(light: 0xFAFBFC, dark: 0x25272C)
    static let surface = color(light: 0xFFFFFF, dark: 0x2D3035)
    static let paper = color(light: 0xFFFFFF, dark: 0x292C31)
    static let paperSurround = canvas
    static let paperBorder = color(light: 0xECEEF1, dark: 0x34373D)
    static let scopeSelection = selection
    static let hover = color(light: 0xF0F2F5, dark: 0x30333A)
    static let pressed = Color.primary.opacity(0.10)
    static let border = color(light: 0xE4E7EB, dark: 0x3B3E45)
    static let radius: CGFloat = 12
    static let controlRadius: CGFloat = 8
    static let windowRadius: CGFloat = 18
    static let contentInset: CGFloat = 24
    static let rowInset: CGFloat = 10
    static let rowHeight: CGFloat = 52
    static let toolbarHeight: CGFloat = 32
    static let footerHeight: CGFloat = 48
    static let previewFooterHeight: CGFloat = 60
    static let readingInset: CGFloat = 28
    static let bodyFont = Font.system(size: 13)
    static let captionFont = Font.system(size: 11)

    private static func color(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: adaptive(light: light, dark: dark))
    }

    private static func adaptive(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((hex >> 16) & 255) / 255,
                           green: Double((hex >> 8) & 255) / 255,
                           blue: Double(hex & 255) / 255, alpha: 1)
        }
    }
}

enum PanelMotion {
    static let feedback = Animation.easeOut(duration: 0.12)
    static let transition = Animation.easeInOut(duration: 0.18)
    static let windowIn: TimeInterval = 0.20
    static let windowOut: TimeInterval = 0.11
}

struct PanelSurface: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .background(PanelTheme.surface, in: RoundedRectangle(cornerRadius: PanelTheme.radius))
            .overlay(RoundedRectangle(cornerRadius: PanelTheme.radius)
                .strokeBorder(contrast == .increased ? Color.primary.opacity(0.3) : PanelTheme.border))
    }
}

extension View {
    func panelSurface() -> some View { modifier(PanelSurface()) }
    func readingPaper() -> some View { modifier(ReadingPaper()) }
}

private struct ReadingPaper: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .background(PanelTheme.paper)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9)
                .strokeBorder(contrast == .increased ? Color.primary.opacity(0.3) : PanelTheme.paperBorder))
    }
}

struct PanelToolbarButtonStyle: ButtonStyle {
    var isSelected = false
    var tint: Color = PanelTheme.accent
    var isProminent = false

    func makeBody(configuration: Configuration) -> some View {
        PanelButtonBody(configuration: configuration, isSelected: isSelected, tint: tint, isProminent: isProminent)
    }
}

private struct PanelButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let isSelected: Bool
    let tint: Color
    let isProminent: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 8)
            .frame(minWidth: PanelTheme.toolbarHeight, minHeight: PanelTheme.toolbarHeight)
            .foregroundStyle(isProminent ? PanelTheme.accentForeground : isSelected ? tint : hovering ? PanelTheme.ink : PanelTheme.secondary)
            .background(background, in: RoundedRectangle(cornerRadius: PanelTheme.controlRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: PanelTheme.controlRadius)
                .strokeBorder(contrast == .increased ? Color.primary.opacity(0.3) : Color.clear))
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: PanelTheme.controlRadius))
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : PanelMotion.feedback, value: hovering)
            .animation(reduceMotion ? nil : PanelMotion.feedback, value: configuration.isPressed)
            .animation(reduceMotion ? nil : PanelMotion.feedback, value: isSelected)
    }

    private var background: Color {
        if isProminent { return PanelTheme.accent.opacity(configuration.isPressed && isEnabled ? 0.80 : hovering && isEnabled ? 0.90 : 1) }
        if configuration.isPressed && isEnabled { return isSelected ? tint.opacity(0.20) : PanelTheme.pressed }
        if isSelected { return tint == PanelTheme.favorite ? .clear : PanelTheme.selection }
        return hovering && isEnabled ? PanelTheme.hover : .clear
    }
}

struct PanelScopeButtonStyle: ButtonStyle {
    var isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        ScopeButtonBody(configuration: configuration, isSelected: isSelected)
    }

    private struct ScopeButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let isSelected: Bool
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.colorSchemeContrast) private var contrast
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(isSelected ? PanelTheme.accent : PanelTheme.secondary)
                .background(configuration.isPressed ? PanelTheme.pressed : isSelected ? PanelTheme.scopeSelection : hovering ? PanelTheme.hover : .clear,
                            in: RoundedRectangle(cornerRadius: PanelTheme.controlRadius))
                .overlay(RoundedRectangle(cornerRadius: PanelTheme.controlRadius)
                    .strokeBorder(isSelected && contrast == .increased ? Color.primary.opacity(0.3) : .clear))
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .animation(reduceMotion ? nil : PanelMotion.feedback, value: hovering)
                .animation(reduceMotion ? nil : PanelMotion.feedback, value: configuration.isPressed)
                .animation(reduceMotion ? nil : PanelMotion.transition, value: isSelected)
        }
    }
}

struct PanelSeparator: View {
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Rectangle()
            .fill(contrast == .increased ? Color.primary.opacity(0.3) : PanelTheme.border)
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}
