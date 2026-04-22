import AppKit
import SwiftUI

/// The Phase 5 command palette overlay. Shows an input field + a ranked
/// candidate list. Keystrokes from the palette's NSTextField are routed
/// through the delegate below; arrow keys / Ctrl+P / Ctrl+N / Tab travel
/// through SwiftUI's `.onKeyPress` modifier attached to the outer panel.
///
/// The view does not manage its own presentation — `TerminalWindowView`
/// mounts it inside a modal overlay when `controller.isOpen == true` and
/// tears it down on ESC / outside-click.
struct CommandPaletteView: View {

    @Bindable var controller: CommandPaletteController
    let themeForeground: RGBColor
    let themeBackground: RGBColor
    /// Invoked whenever a commit path fires (Enter + variants). Phase 5
    /// simply closes the palette; Phase 6–8 dispatch to real actions.
    let onCommit: (PaletteEnterMode) -> Void
    let onDismiss: () -> Void

    var body: some View {
        let fgColor = Color(nsColor: themeForeground.nsColor)

        VStack(spacing: 0) {
            inputRow(fgColor: fgColor)

            Divider().overlay(fgColor.opacity(0.15))

            resultArea(fgColor: fgColor)

            if !controller.selection.isEmpty {
                selectionChip(fgColor: fgColor)
            }
        }
        .frame(width: 600)
        .overlayPanelStyle(cornerRadius: 10)
        .onKeyPress(.upArrow) {
            controller.moveHighlight(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            controller.moveHighlight(by: 1)
            return .handled
        }
        .onKeyPress(.tab) {
            controller.toggleSelection()
            return .handled
        }
        .onKeyPress(.escape) {
            onDismiss()
            return .handled
        }
        // Ctrl+P / Ctrl+N aliases for emacs-style up/down. `.onKeyPress`
        // inspects the resolved character, so Ctrl+P arrives as "p" with
        // a `.control` modifier in `KeyPress.modifiers`.
        .onKeyPress(keys: ["p"]) { press in
            guard press.modifiers.contains(.control) else { return .ignored }
            controller.moveHighlight(by: -1)
            return .handled
        }
        .onKeyPress(keys: ["n"]) { press in
            guard press.modifiers.contains(.control) else { return .ignored }
            controller.moveHighlight(by: 1)
            return .handled
        }
    }

    // MARK: - Input row

    @ViewBuilder
    private func inputRow(fgColor: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: scopeIcon)
                .foregroundStyle(fgColor.opacity(0.55))
                .font(.system(size: 13))
                .frame(width: 16)

            if controller.scope != .session {
                scopeBadge(fgColor: fgColor)
            }

            PaletteTextField(
                text: $controller.input,
                placeholder: placeholderText,
                textColor: themeForeground.nsColor,
                refocusTick: controller.refocusTick,
                onCommit: { mode in onCommit(mode) },
                onCancel: { onDismiss() },
                onDelete: { controller.deleteHighlighted() }
            )
            .frame(maxWidth: .infinity, minHeight: 22)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var scopeIcon: String {
        switch controller.scope {
        case .ssh: return "terminal.fill"
        case .command: return "chevron.right.2"
        case .profile: return "doc.text"
        case .tab: return "rectangle.stack"
        case .session: return "list.bullet.rectangle"
        }
    }

    private var placeholderText: String {
        switch controller.scope {
        case .ssh: return "Connect to… (host, user@host)"
        case .command: return "Run a command…"
        case .profile: return "Open profile…"
        case .tab: return "Go to tab…"
        case .session: return "Switch session… (type > cmd, p profile, t tab, ssh host)"
        }
    }

    @ViewBuilder
    private func scopeBadge(fgColor: Color) -> some View {
        let label: String = {
            switch controller.scope {
            case .ssh: return "ssh"
            case .command: return "cmd"
            case .profile: return "profile"
            case .tab: return "tab"
            case .session: return "session"
            }
        }()
        Text(label)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(fgColor.opacity(0.85))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(fgColor.opacity(0.12)))
    }

    // MARK: - Result list

    @ViewBuilder
    private func resultArea(fgColor: Color) -> some View {
        if controller.rows.isEmpty {
            Text("No matches")
                .font(.system(size: 12))
                .foregroundStyle(fgColor.opacity(0.55))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(controller.rows.enumerated()), id: \.element.id) { index, row in
                            paletteRowView(row: row, index: index, fgColor: fgColor)
                                .id(row.id)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: rowsListMaxHeight)
                .onChange(of: controller.highlightedIndex) { _, newValue in
                    guard controller.rows.indices.contains(newValue) else { return }
                    proxy.scrollTo(controller.rows[newValue].id, anchor: .center)
                }
            }
        }
    }

    /// Cap the visible list at 8 rows; more than that and the user is
    /// expected to narrow with the query.
    private var rowsListMaxHeight: CGFloat { 8 * 30 + 8 }

    /// Parse a "rrggbb" / "#rrggbb" string into a SwiftUI Color. Returns
    /// nil for malformed hex so the swatch simply does not render.
    /// `nonisolated` so SwiftUI can pass it through `flatMap` in a
    /// synchronous context.
    nonisolated static func colorFromHex(_ hex: String) -> Color? {
        var cleaned = hex
        if cleaned.hasPrefix("#") { cleaned.removeFirst() }
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xff) / 255
        let g = Double((value >> 8) & 0xff) / 255
        let b = Double(value & 0xff) / 255
        return Color(red: r, green: g, blue: b)
    }

    @ViewBuilder
    private func paletteRowView(row: PaletteRow, index: Int, fgColor: Color) -> some View {
        let isHighlighted = controller.highlightedIndex == index
        let isSelected = controller.selection.contains(row.id)

        HStack(spacing: 8) {
            if row.candidate.historyIdentifier != nil {
                Image(systemName: "clock")
                    .foregroundStyle(fgColor.opacity(0.55))
                    .font(.system(size: 11))
                    .frame(width: 14)
            } else if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
                    .font(.system(size: 11))
                    .frame(width: 14)
            } else {
                Color.clear.frame(width: 14, height: 1)
            }

            highlightedPrimaryText(row: row, fgColor: fgColor)
                .font(.system(size: 13))
                .lineLimit(1)

            Spacer(minLength: 8)

            if let accent = row.candidate.accentHex.flatMap(Self.colorFromHex) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(accent)
                    .frame(width: 12, height: 12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(fgColor.opacity(0.35), lineWidth: 0.5)
                    )
            }

            if let subtitle = row.candidate.secondaryText, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(fgColor.opacity(0.55))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHighlighted ? fgColor.opacity(0.18) : Color.clear)
                .padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            controller.moveHighlight(by: index - controller.highlightedIndex)
            onCommit(.plain)
        }
    }

    /// Render the primary text with bold+accent highlights on the fuzzy
    /// match positions so users can see what matched.
    private func highlightedPrimaryText(row: PaletteRow, fgColor: Color) -> Text {
        let text = row.candidate.primaryText
        let matched = Set(row.match.matchedIndices)
        if matched.isEmpty {
            return Text(text).foregroundColor(fgColor)
        }
        var attr = AttributedString()
        var index = text.startIndex
        while index < text.endIndex {
            var piece = AttributedString(String(text[index]))
            if matched.contains(index) {
                piece.font = .system(size: 13, weight: .semibold)
                piece.foregroundColor = .accentColor
            } else {
                piece.foregroundColor = fgColor
            }
            attr += piece
            index = text.index(after: index)
        }
        return Text(attr)
    }

    // MARK: - Selection chip

    @ViewBuilder
    private func selectionChip(fgColor: Color) -> some View {
        HStack {
            Text("\(controller.selection.count) selected")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(fgColor.opacity(0.7))
            Spacer()
            Text("⏎ open • ⌘⏎ split right • ⇧⏎ split below • ⌥⏎ float")
                .font(.system(size: 10))
                .foregroundStyle(fgColor.opacity(0.45))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(fgColor.opacity(0.05))
    }
}

// MARK: - PaletteTextField

/// AppKit-backed text field that:
/// - Becomes first responder when it enters the window.
/// - Reports live edits (including IME composition).
/// - Maps Enter / ⌘Enter / ⇧Enter / ⌥Enter to the four palette commit modes.
/// - Swallows Up/Down/Tab so they bubble to the SwiftUI `onKeyPress` handlers
///   attached to the outer panel.
struct PaletteTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let textColor: NSColor
    /// Monotonically increasing counter. Each time it changes, the text
    /// field re-promotes itself to first responder on the next update
    /// pass. Lets the controller reclaim focus after an external action
    /// (e.g. closing a session from the palette) promoted a MetalView.
    let refocusTick: Int
    let onCommit: (PaletteEnterMode) -> Void
    let onCancel: () -> Void
    /// Called on ⌘⌫ in the field. Coordinator intercepts
    /// `deleteToBeginningOfLine:` and forwards to this closure instead of
    /// clearing the input line.
    let onDelete: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = ActivatingPaletteField()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 15)
        field.textColor = textColor
        field.placeholderString = placeholder
        field.stringValue = text
        field.delegate = context.coordinator
        field.onDidMoveToWindow = { [weak field] in
            guard let field, field.window != nil else { return }
            DispatchQueue.main.async {
                field.window?.makeFirstResponder(field)
                field.currentEditor()?.selectedRange = NSRange(location: field.stringValue.count, length: 0)
            }
        }
        // ⌘⏎ travels through `performKeyEquivalent` — AppKit's field
        // editor never forwards Cmd-modified Returns to `doCommandBy`,
        // so without this hook it would hit the no-responder beep.
        // ⇧⏎ / ⌥⏎ are handled separately via `doCommandBy` selectors
        // (`insertLineBreak:` / `insertNewlineIgnoringFieldEditor:`).
        field.onModifiedReturn = { [onCommit] event in
            onCommit(Coordinator.enterMode(from: event))
        }

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.textDidChange(_:)),
            name: NSText.didChangeNotification,
            object: nil
        )
        context.coordinator.lastRefocusTick = refocusTick
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.placeholderString = placeholder
        if context.coordinator.lastRefocusTick != refocusTick {
            context.coordinator.lastRefocusTick = refocusTick
            // Defer so any in-flight AppKit responder switch (caused by
            // the same action that asked us to refocus) has settled.
            DispatchQueue.main.async { [weak nsView] in
                guard let nsView, let window = nsView.window else { return }
                window.makeFirstResponder(nsView)
                let end = nsView.stringValue.count
                nsView.currentEditor()?.selectedRange = NSRange(location: end, length: 0)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            onCommit: onCommit,
            onCancel: onCancel,
            onDelete: onDelete
        )
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding var text: String
        let onCommit: (PaletteEnterMode) -> Void
        let onCancel: () -> Void
        let onDelete: () -> Void
        /// Snapshot of the last seen `refocusTick` from the representable,
        /// so `updateNSView` can detect a bump and re-promote the field.
        var lastRefocusTick: Int = 0

        init(
            text: Binding<String>,
            onCommit: @escaping (PaletteEnterMode) -> Void,
            onCancel: @escaping () -> Void,
            onDelete: @escaping () -> Void
        ) {
            self._text = text
            self.onCommit = onCommit
            self.onCancel = onCancel
            self.onDelete = onDelete
        }

        @objc func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSText else { return }
            let newValue = String(textView.string)
            if newValue != text { text = newValue }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)),
                 #selector(NSResponder.insertLineBreak(_:)),
                 #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                // Plain ⏎ → `insertNewline:`. ⇧⏎ and ⌥⏎ usually arrive
                // as `insertLineBreak:` / `insertNewlineIgnoringFieldEditor:`
                // — without intercepting them the field editor inserts a
                // literal newline into the search box. Route all three
                // through the same commit path; `enterMode(from:)` reads
                // the current event's modifier flags to distinguish them.
                onCommit(Self.enterMode(from: NSApp.currentEvent))
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                onCancel()
                return true
            case #selector(NSResponder.deleteToBeginningOfLine(_:)):
                // ⌘⌫ in an NSTextField normally clears the input up to the
                // line start. We repurpose it as "delete highlighted row".
                onDelete()
                return true
            case #selector(NSResponder.moveUp(_:)),
                 #selector(NSResponder.moveDown(_:)),
                 #selector(NSResponder.insertTab(_:)),
                 #selector(NSResponder.insertBacktab(_:)):
                // Let the outer SwiftUI onKeyPress handlers deal with these.
                return false
            default:
                return false
            }
        }

        static func enterMode(from event: NSEvent?) -> PaletteEnterMode {
            guard let flags = event?.modifierFlags else { return .plain }
            if flags.contains(.command) { return .commandEnter }
            if flags.contains(.shift)   { return .shiftEnter }
            if flags.contains(.option)  { return .optionEnter }
            return .plain
        }
    }
}

/// NSTextField subclass that fires a callback when it is added to a window,
/// so the representable can promote it to first responder. Also catches
/// ⌘⏎ via `performKeyEquivalent` — once the field is focused its field
/// editor (an NSTextView) becomes the first responder, so `keyDown`
/// overrides on the NSTextField subclass never fire. Cmd-modified keys
/// still travel through `performKeyEquivalent` on the key view hierarchy,
/// which is the one reliable seam to intercept ⌘⏎ before it reaches
/// the no-responder beep.
final class ActivatingPaletteField: NSTextField {
    var onDidMoveToWindow: (() -> Void)?
    var onModifiedReturn: ((NSEvent) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { onDidMoveToWindow?() }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Key code 36 is Return; 76 is the numpad Enter.
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        let relevant: NSEvent.ModifierFlags = [.command, .control]
        let mods = event.modifierFlags.intersection(relevant)
        // Only claim the event when the field actually owns input focus.
        // Otherwise a palette-less window could still funnel ⌘⏎ through
        // this branch if another ActivatingPaletteField lingered in the
        // view tree.
        let owns = window?.firstResponder === self
            || window?.firstResponder === currentEditor()
        if isReturn, !mods.isEmpty, owns, let handler = onModifiedReturn {
            handler(event)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
