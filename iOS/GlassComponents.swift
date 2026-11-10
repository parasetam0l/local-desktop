import SwiftUI

extension View {
    /// A sheet on an iPhone. On an iPad, where a sheet is a large fixed page whatever it
    /// holds, a popover of `padSize` next to the control that opened it.
    @ViewBuilder
    func adaptiveSheet<Content: View>(isPresented: Binding<Bool>, padSize: CGSize,
                                      @ViewBuilder content: @escaping () -> Content) -> some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            popover(isPresented: isPresented) {
                content().frame(width: padSize.width, height: padSize.height)
            }
        } else {
            sheet(isPresented: isPresented, content: content)
        }
    }
}
