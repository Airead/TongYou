import AppKit

/// Lightweight NSView search bar displayed at the top of a terminal pane.
/// Manages its own text field and buttons; communicates via closures.
final class SearchBarView: NSView {

    /// Called when the search query changes (debounced by keystrokes).
    var onQueryChanged: ((String) -> Void)?
    /// Called when the user presses Enter or clicks "next".
    var onNext: (() -> Void)?
    /// Called when the user presses Shift+Enter or clicks "previous".
    var onPrevious: (() -> Void)?
    /// Called when the user presses Escape or clicks the close button.
    var onClose: (() -> Void)?

    private let searchField: NSTextField
    private let matchLabel: NSTextField
    private let prevButton: NSButton
    private let nextButton: NSButton
    private let closeButton: NSButton
    private let separator: NSView
    private let containerView: NSView
    private let themeBackground: NSColor
    private let themeForeground: NSColor

    static let barHeight: CGFloat = 32

    override init(frame frameRect: NSRect) {
        let defaultBackground = NSColor.windowBackgroundColor
        let defaultForeground = NSColor.labelColor
        searchField = NSTextField()
        matchLabel = NSTextField(labelWithString: "")
        prevButton = NSButton()
        nextButton = NSButton()
        closeButton = NSButton()
        separator = NSView()
        containerView = NSView()
        themeBackground = defaultBackground
        themeForeground = defaultForeground
        super.init(frame: frameRect)
        setupViews()
    }

    init(frame frameRect: NSRect, themeBackground: NSColor, themeForeground: NSColor) {
        searchField = NSTextField()
        matchLabel = NSTextField(labelWithString: "")
        prevButton = NSButton()
        nextButton = NSButton()
        closeButton = NSButton()
        separator = NSView()
        containerView = NSView()
        self.themeBackground = themeBackground
        self.themeForeground = themeForeground
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    private func setupViews() {
        // Background
        containerView.wantsLayer = true
        containerView.layer?.cornerRadius = 6
        containerView.layer?.backgroundColor = themeBackground.withAlphaComponent(0.9).cgColor
        containerView.layer?.borderColor = themeForeground.withAlphaComponent(0.2).cgColor
        containerView.layer?.borderWidth = 1
        containerView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(containerView)

        // Search field
        searchField.placeholderString = "Search..."
        searchField.font = .systemFont(ofSize: 13)
        searchField.textColor = themeForeground
        searchField.backgroundColor = themeBackground.withAlphaComponent(0.6)
        searchField.drawsBackground = true
        searchField.wantsLayer = true
        searchField.layer?.cornerRadius = 4
        searchField.isEditable = true
        searchField.isSelectable = true
        searchField.isBordered = false
        searchField.isBezeled = false
        searchField.focusRingType = .none
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(searchField)

        // Match count label
        matchLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        matchLabel.textColor = themeForeground.withAlphaComponent(0.7)
        matchLabel.alignment = .center
        matchLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(matchLabel)

        // Previous button
        prevButton.image = NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Previous")
        prevButton.bezelStyle = .inline
        prevButton.isBordered = false
        prevButton.contentTintColor = themeForeground
        prevButton.target = self
        prevButton.action = #selector(previousClicked)
        prevButton.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(prevButton)

        // Next button
        nextButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Next")
        nextButton.bezelStyle = .inline
        nextButton.isBordered = false
        nextButton.contentTintColor = themeForeground
        nextButton.target = self
        nextButton.action = #selector(nextClicked)
        nextButton.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(nextButton)

        // Close button
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.contentTintColor = themeForeground
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(closeButton)

        // Separator between match count and buttons
        separator.wantsLayer = true
        separator.layer?.backgroundColor = themeForeground.withAlphaComponent(0.15).cgColor
        separator.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(separator)

        // Layout
        NSLayoutConstraint.activate([
            containerView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            containerView.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            containerView.heightAnchor.constraint(equalToConstant: Self.barHeight),

            searchField.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 6),
            searchField.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
            searchField.widthAnchor.constraint(equalToConstant: 200),

            matchLabel.leadingAnchor.constraint(equalTo: searchField.trailingAnchor, constant: 6),
            matchLabel.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
            matchLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 50),

            separator.leadingAnchor.constraint(equalTo: matchLabel.trailingAnchor, constant: 6),
            separator.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
            separator.widthAnchor.constraint(equalToConstant: 1),
            separator.heightAnchor.constraint(equalToConstant: 16),

            prevButton.leadingAnchor.constraint(equalTo: separator.trailingAnchor, constant: 6),
            prevButton.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),

            nextButton.leadingAnchor.constraint(equalTo: prevButton.trailingAnchor, constant: 2),
            nextButton.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),

            closeButton.leadingAnchor.constraint(equalTo: nextButton.trailingAnchor, constant: 4),
            closeButton.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -6),
        ])
    }

    /// Focus the search field and select all text.
    func activate() {
        // Defer to the next runloop tick so the view hierarchy and layout
        // are fully established before AppKit evaluates first-responder eligibility.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self.searchField)
            self.searchField.selectText(nil)
        }
    }

    /// Update the match count display.
    func updateMatchCount(current: Int?, total: Int) {
        if total == 0 {
            matchLabel.stringValue = searchField.stringValue.isEmpty ? "" : "No results"
        } else if let current {
            matchLabel.stringValue = "\(current + 1)/\(total)"
        } else {
            matchLabel.stringValue = "\(total) found"
        }
    }

    /// Get the current query text.
    var query: String {
        searchField.stringValue
    }

    // MARK: - Actions

    @objc private func previousClicked() {
        onPrevious?()
    }

    @objc private func nextClicked() {
        onNext?()
    }

    @objc private func closeClicked() {
        onClose?()
    }
}

// MARK: - NSTextFieldDelegate

extension SearchBarView: NSTextFieldDelegate {

    func controlTextDidChange(_ obj: Notification) {
        onQueryChanged?(searchField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            // Escape
            onClose?()
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            // Enter — check for Shift modifier
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                onPrevious?()
            } else {
                onNext?()
            }
            return true
        }
        return false
    }
}
