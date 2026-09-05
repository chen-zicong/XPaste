import SwiftUI

/// Present sheets, errors and transient feedback on the window the user is using.
struct PanelFeedback: ViewModifier {
    @Bindable var model: AppModel
    let isPreview: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isActiveHost: Bool { model.isDetailVisible == isPreview }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                Group {
                    if isActiveHost, let toast = model.toastMessage {
                        HStack(spacing: 10) {
                            Text(toast).font(.callout)
                            if model.pendingDeletion != nil {
                                Button("撤销") { model.undoDeletion() }
                                    .buttonStyle(PanelToolbarButtonStyle(isSelected: true))
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(PanelTheme.chrome, in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(PanelTheme.border))
                        .shadow(color: .black.opacity(0.10), radius: 8, y: 3)
                        .padding(16)
                        .padding(.bottom, isPreview ? PanelTheme.previewFooterHeight : PanelTheme.footerHeight)
                        .id(toast)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 6)))
                    }
                }
                .animation(reduceMotion ? nil : PanelMotion.transition, value: isActiveHost ? model.toastMessage : nil)
            }
            .sheet(item: Binding(
                get: { isActiveHost ? model.imageEditorItem : nil },
                set: { if isActiveHost { model.imageEditorItem = $0 } }
            )) { item in
                ImageEditorView(model: model, item: item)
            }
            .alert("XPaste", isPresented: Binding(
                get: { isActiveHost && model.errorMessage != nil },
                set: { if !$0 && isActiveHost { model.errorMessage = nil } }
            )) {
                Button("好") { model.errorMessage = nil }
            } message: {
                Text(model.errorMessage ?? "发生未知错误")
            }
    }
}

struct PanelGlassSurface: ViewModifier {
    var cornerRadius: CGFloat = PanelTheme.radius
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !reduceTransparency {
            content.background {
                // Keep labels outside the glass compositing layer so native text
                // retains its semantic foreground color in both appearances.
                Color.clear.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius))
            }
        } else {
            content
                .background(PanelTheme.chrome, in: RoundedRectangle(cornerRadius: cornerRadius))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(contrast == .increased ? Color.primary.opacity(0.3) : PanelTheme.border))
        }
    }
}
