//
//  SettingsDesign.swift
//  DSH Studio
//

import AppKit
import SwiftUI

/// Metrics for the app's Settings window, taken from the macOS 26 settings
/// surface: 42pt rows, 12pt group radius, 11pt section headers, and a 3% group
/// fill over the pane background.
///
/// Hierarchy comes from spacing, type weight, and one low-contrast fill. There
/// are no shadows, gradients, or decorative borders anywhere in the page.
enum SettingsDesign {
    // Window and columns.
    static let windowMinWidth: CGFloat = 780
    static let windowIdealWidth: CGFloat = 900
    static let windowMinHeight: CGFloat = 520
    static let windowIdealHeight: CGFloat = 640
    static let sidebarMinWidth: CGFloat = 200
    static let sidebarIdealWidth: CGFloat = 232
    static let sidebarMaxWidth: CGFloat = 240

    // Content column.
    static let contentMaxWidth: CGFloat = 720
    static let contentHorizontalPadding: CGFloat = 20
    static let contentTopPadding: CGFloat = 20
    static let contentBottomPadding: CGFloat = 28
    static let sectionSpacing: CGFloat = 24
    static let headerSpacing: CGFloat = 6

    // Group surface.
    static let groupCornerRadius: CGFloat = 12
    static let groupFill = adaptive(
        light: NSColor(white: 0, alpha: 0.032),
        dark: NSColor(white: 1, alpha: 0.055)
    )
    static let separator = adaptive(
        light: NSColor(white: 0, alpha: 0.05),
        dark: NSColor(white: 1, alpha: 0.07)
    )
    static let paneBackground = Color(nsColor: .controlBackgroundColor)

    // Row.
    static let rowMinHeight: CGFloat = 46
    static let rowHorizontalPadding: CGFloat = 16
    static let rowVerticalPadding: CGFloat = 2
    static let rowColumnSpacing: CGFloat = 16
    static let rowLabelSpacing: CGFloat = 2

    /// One width for every row action, so trailing buttons line up as a column
    /// instead of stepping in and out with the length of each label. The label
    /// carries the width because a bordered button sizes its own background to
    /// its content.
    static let actionButtonLabelWidth: CGFloat = 68

    // Type: 13pt row titles and values, 11pt descriptions, headers, footers.
    static let titleFont = Font.body.weight(.medium)
    static let valueFont = Font.body
    static let detailFont = Font.subheadline
    static let headerFont = Font.subheadline.weight(.bold)

    /// A colour that follows the effective appearance instead of being frozen
    /// to whichever one happened to be current when the value was created.
    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

/// A group of settings rows: an optional 11pt header, one rounded surface, and
/// an optional explanatory footer. Rows are separated by a hairline inset to the
/// text column, so a group reads as a single control surface rather than a stack
/// of individual cards.
struct SettingsGroup<Content: View>: View {
    var header: String?
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let header {
                Text(header)
                    .font(SettingsDesign.headerFont)
                    .foregroundStyle(.secondary)
                    .padding(.leading, SettingsDesign.rowHorizontalPadding)
                    .padding(.bottom, SettingsDesign.headerSpacing)
            }

            Group(subviews: content) { subviews in
                VStack(spacing: 0) {
                    ForEach(subviews.indices, id: \.self) { index in
                        subviews[index]
                        if index < subviews.count - 1 {
                            SettingsRowSeparator()
                        }
                    }
                }
            }
            .background(
                RoundedRectangle(
                    cornerRadius: SettingsDesign.groupCornerRadius,
                    style: .continuous
                )
                .fill(SettingsDesign.groupFill)
            )

            if let footer {
                Text(footer)
                    .font(SettingsDesign.detailFont)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, SettingsDesign.rowHorizontalPadding)
                    .padding(.top, SettingsDesign.headerSpacing)
            }
        }
    }
}

/// The hairline between two rows inside a group.
struct SettingsRowSeparator: View {
    var body: some View {
        Rectangle()
            .fill(SettingsDesign.separator)
            .frame(height: 1)
            .padding(.leading, SettingsDesign.rowHorizontalPadding)
    }
}

/// A settings row: a title with an optional explanation and a trailing control.
struct SettingsRow<Control: View>: View {
    let title: String
    var description: String?
    var problem: String?
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: SettingsDesign.rowColumnSpacing) {
            SettingsRowLabel(title: title, description: description, problem: problem)
            Spacer(minLength: SettingsDesign.rowColumnSpacing)
            control()
        }
        .padding(.horizontal, SettingsDesign.rowHorizontalPadding)
        .padding(.vertical, SettingsDesign.rowVerticalPadding)
        .frame(minHeight: SettingsDesign.rowMinHeight)
    }
}

/// The leading half of a settings row: a 13pt medium title with an 11pt
/// explanation underneath. Explanations only appear where the title alone would
/// not explain the setting.
struct SettingsRowLabel: View {
    let title: String
    var description: String?
    var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsDesign.rowLabelSpacing) {
            Text(title)
                .font(SettingsDesign.titleFont)
            if let description {
                Text(description)
                    .font(SettingsDesign.detailFont)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let problem {
                // The message itself carries the state, so colour is never the
                // only signal that something needs attention.
                Text(problem)
                    .font(SettingsDesign.detailFont)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A read-only row whose value is secondary information.
struct SettingsValueRow: View {
    let title: String
    let value: String
    var isBusy = false

    var body: some View {
        SettingsRow(title: title) {
            HStack(spacing: 6) {
                if isBusy {
                    ProgressView().controlSize(.small)
                }
                Text(value)
                    .font(SettingsDesign.valueFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }
        }
    }
}

/// An action row: one button carries the action while the row explains it.
///
/// Buttons use the standard bordered style on purpose. An accent-filled button
/// stays visually loud even when it is disabled, which misrepresents an action
/// that is not currently available.
struct SettingsActionRow: View {
    let title: String
    var description: String?
    let actionTitle: String
    /// Spoken name for the button when the visible title is not self-contained.
    var accessibilityLabel: String?
    var role: ButtonRole?
    var isEnabled = true
    var isBusy = false
    let action: () -> Void

    var body: some View {
        SettingsRow(title: title, description: description) {
            HStack(spacing: 8) {
                if isBusy {
                    ProgressView().controlSize(.small)
                }
                SettingsActionButton(
                    title: actionTitle,
                    role: role,
                    isEnabled: isEnabled && !isBusy,
                    accessibilityLabel: accessibilityLabel,
                    action: action
                )
            }
        }
    }
}

/// The row action button. Every instance is the same width so the actions read
/// as a column, and the bordered style keeps the system's own hover, pressed,
/// focus, and disabled rendering.
struct SettingsActionButton: View {
    let title: String
    var role: ButtonRole?
    var isEnabled = true
    var accessibilityLabel: String?
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Text(title)
                .frame(minWidth: SettingsDesign.actionButtonLabelWidth)
        }
        .buttonStyle(.bordered)
        .disabled(!isEnabled)
        .accessibilityLabel(accessibilityLabel ?? title)
    }
}
