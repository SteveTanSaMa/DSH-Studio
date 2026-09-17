//
//  SettingsDesign.swift
//  DSH Studio
//

import AppKit
import SwiftUI

/// Layout metrics for the app's Settings window.
///
/// The values follow the macOS settings surface: 46pt rows, a 12pt group radius,
/// 11pt section headers, and a 3% group fill over the pane background. Hierarchy
/// comes from spacing, type weight, and that one low-contrast fill; the page has
/// no shadows, gradients, or decorative borders.
enum SettingsDesign {
    // Window and columns.
    /// Narrowest window the two-column layout still renders without squeezing rows.
    static let windowMinWidth: CGFloat = 780
    /// Default window width, matching the width System Settings opens at.
    static let windowIdealWidth: CGFloat = 900
    /// Shortest window that keeps a full group and its footer visible.
    static let windowMinHeight: CGFloat = 520
    /// Default window height.
    static let windowIdealHeight: CGFloat = 640
    /// Narrowest sidebar that still fits the longest category label.
    static let sidebarMinWidth: CGFloat = 200
    /// Default sidebar width.
    static let sidebarIdealWidth: CGFloat = 232
    /// Widest sidebar, so the content column never loses its comfortable width.
    static let sidebarMaxWidth: CGFloat = 240

    // Content column.
    /// Widest content column; wider windows keep the reading measure instead of stretching rows.
    static let contentMaxWidth: CGFloat = 720
    /// Inset between the pane edge and a group card.
    static let contentHorizontalPadding: CGFloat = 20
    /// Space above the first group, below the window toolbar.
    static let contentTopPadding: CGFloat = 20
    /// Space below the last group.
    static let contentBottomPadding: CGFloat = 28
    /// Vertical gap between two groups, including their header and footer.
    static let sectionSpacing: CGFloat = 24
    /// Gap between a group's header or footer text and its card.
    static let headerSpacing: CGFloat = 6

    // Group surface.
    /// Corner radius of a group card.
    static let groupCornerRadius: CGFloat = 12
    /// Card fill: a 3% black wash in light mode and a 5.5% white wash in dark mode.
    ///
    /// Keeping the card this quiet lets spacing and typography carry the hierarchy.
    static let groupFill = adaptive(
        light: NSColor(white: 0, alpha: 0.032),
        dark: NSColor(white: 1, alpha: 0.055)
    )
    /// Hairline between two rows: 5% black in light mode, 7% white in dark mode.
    static let separator = adaptive(
        light: NSColor(white: 0, alpha: 0.05),
        dark: NSColor(white: 1, alpha: 0.07)
    )
    /// Pane background the cards sit on; a semantic color so it follows the system theme.
    static let paneBackground = Color(nsColor: .controlBackgroundColor)

    // Row.
    /// Minimum row height, giving every row the same calm rhythm.
    static let rowMinHeight: CGFloat = 46
    /// Leading and trailing inset of a row's content inside its card.
    static let rowHorizontalPadding: CGFloat = 16
    /// Extra vertical padding around a row's content.
    static let rowVerticalPadding: CGFloat = 2
    /// Minimum gap between a row's label block and its control.
    static let rowColumnSpacing: CGFloat = 16
    /// Gap between a row's title and its description.
    static let rowLabelSpacing: CGFloat = 2

    /// Shared label width for row action buttons.
    ///
    /// The label carries the width because a bordered button sizes its own
    /// background to its content, so equal labels are what make the buttons line
    /// up as a column instead of stepping in and out with each title.
    static let actionButtonLabelWidth: CGFloat = 68

    // Type: 13pt row titles and values, 11pt descriptions, headers, footers.
    /// Row titles: 13pt medium.
    static let titleFont = Font.body.weight(.medium)
    /// Read-only row values: 13pt regular, shown in the secondary color.
    static let valueFont = Font.body
    /// Descriptions, headers, and footers: 11pt.
    static let detailFont = Font.subheadline
    /// Group headers: 11pt bold.
    static let headerFont = Font.subheadline.weight(.bold)

    /// A colour that follows the effective appearance.
    ///
    /// Values are resolved per appearance instead of being frozen to whichever one
    /// happened to be current when the constant was created.
    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

/// A group of settings rows on one rounded surface.
///
/// An optional 11pt header sits above the card and an optional footer below it.
/// Rows are separated by a hairline inset to the text column, so a group reads as
/// a single control surface rather than a stack of individual cards.
struct SettingsGroup<Content: View>: View {
    /// Optional label above the card.
    var header: String?
    /// Optional explanatory text below the card.
    var footer: String?
    /// One entry per row; separators are drawn between them automatically.
    @ViewBuilder var content: Content

    /// Renders the header, the card with its rows, and the footer.
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
    /// Renders the inset hairline between two rows.
    var body: some View {
        Rectangle()
            .fill(SettingsDesign.separator)
            .frame(height: 1)
            .padding(.leading, SettingsDesign.rowHorizontalPadding)
    }
}

/// A settings row: a title with an optional explanation and a trailing control.
struct SettingsRow<Control: View>: View {
    /// Row title.
    let title: String
    /// Optional explanation shown under the title.
    var description: String?
    /// Optional problem shown under the description in red.
    var problem: String?
    /// Trailing control, laid out at the row's trailing edge.
    @ViewBuilder var control: () -> Control

    /// Lays out the label, a flexible spacer, and the trailing control.
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

/// The leading half of a settings row.
///
/// A 13pt medium title with an 11pt explanation underneath. Explanations only
/// appear where the title alone would not explain the setting.
struct SettingsRowLabel: View {
    /// Row title.
    let title: String
    /// Optional explanation shown under the title.
    var description: String?
    /// Optional problem shown under the description in red.
    var problem: String?

    /// Stacks the title, description, and problem text at the leading edge.
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
    /// Row title.
    let title: String
    /// Value rendered in the secondary color and selectable for copying.
    let value: String
    /// Shows a progress indicator next to the value.
    var isBusy = false

    /// Renders the value, with a spinner while the surrounding operation runs.
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
    /// Row title.
    let title: String
    /// Optional explanation shown under the title.
    var description: String?
    /// Visible button title.
    let actionTitle: String
    /// Spoken name for the button when the visible title is not self-contained.
    var accessibilityLabel: String?
    /// Optional button role, used for the destructive action.
    var role: ButtonRole?
    /// Whether the action can be taken right now.
    var isEnabled = true
    /// Shows a progress indicator and disables the button.
    var isBusy = false
    /// Action performed when the button is pressed.
    let action: () -> Void

    /// Renders the description and the trailing action button.
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

/// A row action button with the shared action width.
///
/// The bordered style keeps the system's own hover, pressed, focus, and disabled
/// rendering, and the fixed label width makes every action line up.
struct SettingsActionButton: View {
    /// Visible button title.
    let title: String
    /// Optional button role, used for the destructive action.
    var role: ButtonRole?
    /// Whether the action can be taken right now.
    var isEnabled = true
    /// Spoken name, used when the visible title is not self-contained.
    var accessibilityLabel: String?
    /// Action performed when the button is pressed.
    let action: () -> Void

    /// Renders a bordered button whose label carries the shared action width.
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
