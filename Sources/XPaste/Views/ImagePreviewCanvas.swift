import AppKit
import SwiftUI

/// A quiet checkerboard makes transparent image edges visible in either appearance.
struct ImagePreviewCanvas: View {
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(PanelTheme.surface))
            let step: CGFloat = 12
            for row in 0..<Int(ceil(size.height / step)) {
                for column in 0..<Int(ceil(size.width / step)) where (row + column).isMultiple(of: 2) {
                    let rect = CGRect(x: CGFloat(column) * step, y: CGFloat(row) * step, width: step, height: step)
                    context.fill(Path(rect), with: .color(.primary.opacity(0.025)))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

extension NSImage {
    var previewPixelDimensions: (width: Int, height: Int)? {
        guard let representation = representations.filter({ $0.pixelsWide > 0 && $0.pixelsHigh > 0 })
            .max(by: { $0.pixelsWide < $1.pixelsWide }) else { return nil }
        return (representation.pixelsWide, representation.pixelsHigh)
    }
}
