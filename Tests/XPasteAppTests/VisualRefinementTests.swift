import AppKit
import SwiftUI
import XCTest
import XPasteCore
@testable import XPaste

@MainActor
final class VisualRefinementTests: XCTestCase {
    func testReadEditSwitchPreservesNativeViewSelectionAndGeometry() async throws {
        _ = NSApplication.shared
        let state = EditorState()
        let host = NSHostingView(rootView: EditorHarness(state: state))
        host.frame = NSRect(x: 0, y: 0, width: 480, height: 300)
        host.layoutSubtreeIfNeeded()
        await settle()
        let original = try XCTUnwrap(findTextView(in: host))
        original.setSelectedRange(NSRange(location: 3, length: 4))
        let inset = original.textContainerInset
        let width = original.textContainer?.containerSize.width
        state.editing = true
        await settle()
        let editing = try XCTUnwrap(findTextView(in: host))
        XCTAssertTrue(editing === original)
        XCTAssertTrue(editing.isEditable)
        XCTAssertEqual(editing.selectedRange(), NSRange(location: 3, length: 4))
        XCTAssertEqual(editing.textContainerInset, inset)
        XCTAssertEqual(editing.textContainer?.containerSize.width, width)
        state.editing = false
        await settle()
        XCTAssertFalse(original.isEditable)
        XCTAssertEqual(original.selectedRange(), NSRange(location: 3, length: 4))
    }

    func testNativeTypingAndUndoReachDraftWithoutResettingCaret() async throws {
        _ = NSApplication.shared
        let state = EditorState()
        state.editing = true
        state.text = "设计记录。\n\n正文仍然使用原生编辑与撤销。"
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        let host = NSHostingView(rootView: EditorHarness(state: state))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        await settle()
        let editor = try XCTUnwrap(findTextView(in: host))
        let original = state.text
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        editor.insertText("中文", replacementRange: editor.selectedRange())
        await settle()
        XCTAssertEqual(state.text, editor.string)
        XCTAssertTrue(state.text.contains("中文"))
        XCTAssertEqual(editor.selectedRange().location, 4)
        XCTAssertTrue(editor.undoManager?.canUndo == true)
        editor.breakUndoCoalescing()
        editor.undoManager?.undo()
        await settle()
        XCTAssertEqual(editor.string, original, "Native undo should restore text")
        XCTAssertEqual(state.text, original, "Draft should receive native undo")
    }

    func testChineseCompositionSurvivesBindingRefresh() async throws {
        _ = NSApplication.shared
        let state = EditorState()
        state.editing = true
        let host = NSHostingView(rootView: EditorHarness(state: state))
        host.frame = NSRect(x: 0, y: 0, width: 480, height: 300)
        host.layoutSubtreeIfNeeded()
        await settle()
        let editor = try XCTUnwrap(findTextView(in: host))
        let oldText = state.text
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.setMarkedText("拼", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        await settle()
        XCTAssertTrue(editor.hasMarkedText())
        state.text = oldText // A refresh must not replace the in-progress composition.
        await settle()
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertTrue(editor.string.hasPrefix("拼"))
        editor.insertText("拼音", replacementRange: NSRange(location: NSNotFound, length: 0))
        await settle()
        XCTAssertFalse(editor.hasMarkedText())
        XCTAssertTrue(state.text.hasPrefix("拼音"))
        XCTAssertEqual(state.text, editor.string)
    }

    func testRetinaImageMetadataUsesPixelsInsteadOfPoints() throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 600, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = NSSize(width: 400, height: 300)
        let image = NSImage(size: bitmap.size)
        image.addRepresentation(bitmap)
        XCTAssertEqual(image.size.width, 400)
        XCTAssertEqual(image.previewPixelDimensions?.width, 800)
        XCTAssertEqual(image.previewPixelDimensions?.height, 600)
    }

    func testPaperTypographyPreservesPlainTextAndLineEndings() async throws {
        _ = NSApplication.shared
        let state = EditorState()
        state.text = "设计记录。\r\n\r\n第一行正文。\r\n第二行正文。"
        let host = NSHostingView(rootView: EditorHarness(state: state))
        host.frame = NSRect(x: 0, y: 0, width: 480, height: 300)
        host.layoutSubtreeIfNeeded()
        await settle()
        let textView = try XCTUnwrap(findTextView(in: host))
        XCTAssertEqual(textView.string, state.text)
        XCTAssertFalse(textView.isRichText)
        let storage = try XCTUnwrap(textView.textStorage)
        let titleFont = try XCTUnwrap(storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let bodyFont = try XCTUnwrap(storage.attribute(.font, at: storage.length - 1, effectiveRange: nil) as? NSFont)
        XCTAssertGreaterThan(titleFont.pointSize, bodyFont.pointSize)
        state.editing = true
        await settle()
        XCTAssertEqual(textView.string, state.text)
        XCTAssertEqual(storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont, titleFont)
        state.text = "https://example.com/design\n\n链接的补充说明"
        await settle()
        let linkFont = try XCTUnwrap(storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(linkFont.pointSize, bodyFont.pointSize, "URLs should retain body typography")
        XCTAssertEqual(textView.string, state.text)
    }

    private func findTextView(in view: NSView) -> NSTextView? {
        if let text = view as? NSTextView { return text }
        return view.subviews.lazy.compactMap { self.findTextView(in: $0) }.first
    }

    private func settle() async { try? await Task.sleep(for: .milliseconds(80)) }

    @Observable final class EditorState {
        var text = "A native text surface with a stable selection.\n第二行文字。"
        var editing = false
    }

    private struct EditorHarness: View {
        @Bindable var state: EditorState
        var body: some View { PreviewTextSurface(text: $state.text, isEditable: state.editing) }
    }
}
