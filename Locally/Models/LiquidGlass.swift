import SwiftUI

extension View {
    /// Applies pure Apple Liquid Glass to the view with concentric shape clipping and dynamic material optics.
    @ViewBuilder
    func liquidGlass<S: Shape>(_ shape: S, isClear: Bool = false) -> some View {
        if #available(macOS 26.0, iOS 26.0, *) {
            self.glassEffect(isClear ? .clear : .regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }

    /// Applies pure Apple Liquid Glass to the view.
    @ViewBuilder
    func liquidGlass(isClear: Bool = false) -> some View {
        if #available(macOS 26.0, iOS 26.0, *) {
            self.glassEffect(isClear ? .clear : .regular)
        } else {
            self.background(.ultraThinMaterial)
        }
    }
}
