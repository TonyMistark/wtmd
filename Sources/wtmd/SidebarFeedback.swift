import SwiftUI

// MARK: - Sidebar press feedback

/// Pressed-state highlight shared by every sidebar row.
///
/// Two flavors for two gesture worlds:
/// - `SidebarRowButtonStyle` for rows that are `Button`s (`isPressed` drives it).
/// - `pressFeedback()` for rows whose action rides on `.onTapGesture` — tree
///   rows must not become `Button`s because a Button swallows the drag gesture
///   and the row can no longer be picked up. The press signal there comes from
///   `onLongPressGesture`'s `onPressingChanged`, which fires on mouse-down and
///   mouse-up without ever completing (infinite duration), so the tap gesture
///   stays the one performing the action. A small `maximumDistance` cancels the
///   highlight as soon as a real drag & drop takes over the mouse.
///
/// The highlight is a neutral wash, clearly weaker than the accent-colored
/// drop-target highlight — press feedback must never read as "dropping here".
struct SidebarRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.1 : 0))
            )
    }
}

private struct PressFeedback: ViewModifier {
    @State private var isPressed = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(isPressed ? 0.1 : 0))
            )
            .onLongPressGesture(minimumDuration: .infinity, maximumDistance: 8) {
                // Never fires: the infinite duration exists so this gesture
                // never claims the click — the tap gesture keeps the action.
            } onPressingChanged: { pressing in
                isPressed = pressing
            }
    }
}

extension View {
    /// Adds a pressed/released highlight to a tap-gesture row. See
    /// `SidebarRowButtonStyle` for why this is not a Button style.
    func pressFeedback() -> some View {
        modifier(PressFeedback())
    }
}
