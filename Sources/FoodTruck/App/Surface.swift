import SwiftUI

/// FoodTruck's one glass surface.
///
/// Three facts shaped this, all verified rather than assumed:
///
/// * **"Golden Gate" is not a design language.** It is macOS 27's marketing
///   name. The design language is Liquid Glass, introduced in Tahoe and
///   *refined* in 27 -- Apple's WWDC26 guide heads the section "Platform design
///   and Liquid Glass" and calls 27's work "New platform design refinements".
///   So there is one visual target here, not three.
/// * **The restyle follows the linked SDK, not the deployment target.** Standard
///   controls pick up the new look because we compile against the macOS 26 SDK.
///   macOS 27 additionally grants the scroll-edge effect and click-bounce for
///   free, with no code change.
/// * **The glass symbols hard-error below macOS 26**, so a deployment target of
///   15 requires an explicit gate. Apple publishes no pattern for this -- every
///   sample is macOS 26.0+ with no fallback -- so this wrapper is our own
///   convention, kept in one file precisely because it is ours.
///
/// Reduce Transparency is checked first and wins outright. It is a statement
/// about legibility, and a translucent "compromise" would honour the letter of
/// the setting while ignoring the point of it.
struct Surface: ViewModifier {
    var cornerRadius: CGFloat = 12
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(
                Color(nsColor: .controlBackgroundColor),
                in: .rect(cornerRadius: cornerRadius))
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            content.background(.regularMaterial, in: .rect(cornerRadius: cornerRadius))
        }
    }
}

extension View {
    func surface(cornerRadius: CGFloat = 12) -> some View {
        modifier(Surface(cornerRadius: cornerRadius))
    }
}
