import AppKit
import PRPeekCore

/// Dedicated, high-performance native Diff Viewer window for PRPeek.
/// Supports both Side-by-Side (Split) and Inline (Unified) diff views with
/// an instant 1-click toggle and keyboard shortcuts (⌘1 / ⌘2 / Tab).
@MainActor
final class DiffWindow: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    enum ViewMode: Int {
        case sideBySide = 0
        case inline = 1
    }

    private let model: AppModel
    private var window: NSWindow?

    private var currentPR: PullRequest?
    private var allFiles: [PullRequestFile] = []
    private var filteredFiles: [PullRequestFile] = []
    private var selectedFileIndex: Int = 0

    // Parsed diff cache for current file
    private var currentUnifiedLines: [UnifiedDiffLine] = []
    private var currentSideBySideRows: [SideBySideDiffRow] = []

    // UI Elements
    private let splitView = NSSplitView()
    private let fileFilterField = NSSearchField()
    private let fileTable = KeyTableView()
    private let diffTable = KeyTableView()

    private let titleLabel = NSTextField(labelWithString: "")
    private let repoBadge = makePill()
    private let statsBadge = makePill()
    private let modeControl = NSSegmentedControl()

    private let currentFilePathLabel = NSTextField(labelWithString: "")
    private let currentFileStatusBadge = makePill()
    private let emptyStateLabel = NSTextField(labelWithString: "")
    private let progressIndicator = NSProgressIndicator()

    private var viewMode: ViewMode {
        get {
            let val = UserDefaults.standard.integer(forKey: "diffViewMode")
            return ViewMode(rawValue: val) ?? .sideBySide
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "diffViewMode")
            modeControl.selectedSegment = newValue.rawValue
            diffTable.reloadData()
        }
    }

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func show(for pr: PullRequest) {
        self.currentPR = pr
        if window == nil {
            window = makeWindow()
        }

        updateHeader()
        loadDiff(for: pr)

        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        window?.orderOut(nil)
    }

    private func updateHeader() {
        guard let pr = currentPR else { return }
        window?.title = "Diff: \(pr.repoFullName)#\(pr.number) — \(pr.title)"
        titleLabel.stringValue = pr.title
        repoBadge.label.stringValue = "\(pr.repoFullName)#\(pr.number)"

        let p = model.palette
        titleLabel.textColor = p?.text ?? .labelColor
        let accent = p?.subtext ?? .secondaryLabelColor
        repoBadge.label.textColor = accent
        repoBadge.view.layer?.backgroundColor = accent.withAlphaComponent(0.14).cgColor
    }

    private func loadDiff(for pr: PullRequest) {
        allFiles = []
        filteredFiles = []
        selectedFileIndex = 0
        fileTable.reloadData()
        diffTable.reloadData()

        emptyStateLabel.stringValue = "Loading diff from GitHub…"
        emptyStateLabel.isHidden = false
        progressIndicator.startAnimation(nil)
        progressIndicator.isHidden = false

        if let cached = model.files(for: pr) {
            populateFiles(cached)
            return
        }

        let targetID = pr.id
        model.loadFiles(for: pr) { [weak self] files in
            guard let self, let current = self.currentPR, current.id == targetID else { return }
            self.populateFiles(files)
        }
    }

    private func populateFiles(_ files: [PullRequestFile]) {
        progressIndicator.stopAnimation(nil)
        progressIndicator.isHidden = true
        allFiles = files
        applyFileFilter()

        let totalAdds = files.reduce(0) { $0 + $1.additions }
        let totalDels = files.reduce(0) { $0 + $1.deletions }
        statsBadge.label.stringValue = "+\(totalAdds)  -\(totalDels)"
        statsBadge.label.textColor = model.palette?.green ?? .systemGreen
        statsBadge.view.layer?.backgroundColor = (model.palette?.green ?? .systemGreen).withAlphaComponent(0.12).cgColor

        if files.isEmpty {
            emptyStateLabel.stringValue = "No files changed in this PR."
            emptyStateLabel.isHidden = false
        } else {
            emptyStateLabel.isHidden = true
            selectFile(at: 0)
        }
    }

    private func applyFileFilter() {
        let q = fileFilterField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty {
            filteredFiles = allFiles
        } else {
            filteredFiles = allFiles.filter { $0.filename.lowercased().contains(q) }
        }
        fileTable.reloadData()
        if !filteredFiles.isEmpty {
            selectFile(at: min(selectedFileIndex, filteredFiles.count - 1))
        } else {
            currentUnifiedLines = []
            currentSideBySideRows = []
            diffTable.reloadData()
            emptyStateLabel.stringValue = "No matching files."
            emptyStateLabel.isHidden = false
        }
    }

    private func selectFile(at index: Int) {
        guard filteredFiles.indices.contains(index) else { return }
        selectedFileIndex = index
        fileTable.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        fileTable.scrollRowToVisible(index)

        let file = filteredFiles[index]
        currentFilePathLabel.stringValue = file.filename
        currentFileStatusBadge.label.stringValue = file.status.displayLabel
        let statusColor: NSColor
        switch file.status {
        case .added: statusColor = model.palette?.green ?? .systemGreen
        case .removed: statusColor = model.palette?.red ?? .systemRed
        case .modified: statusColor = model.palette?.blue ?? .systemBlue
        case .renamed: statusColor = model.palette?.yellow ?? .systemOrange
        default: statusColor = model.palette?.subtext ?? .secondaryLabelColor
        }
        currentFileStatusBadge.label.textColor = statusColor
        currentFileStatusBadge.view.layer?.backgroundColor = statusColor.withAlphaComponent(0.14).cgColor

        if let patch = file.patch {
            currentUnifiedLines = DiffParser.parseUnified(patch: patch)
            currentSideBySideRows = DiffParser.parseSideBySide(patch: patch)
            emptyStateLabel.isHidden = true
        } else {
            currentUnifiedLines = []
            currentSideBySideRows = []
            emptyStateLabel.stringValue = "Binary file or changes too large to display directly."
            emptyStateLabel.isHidden = false
        }
        diffTable.reloadData()
        if (viewMode == .inline && !currentUnifiedLines.isEmpty) || (viewMode == .sideBySide && !currentSideBySideRows.isEmpty) {
            diffTable.scrollRowToVisible(0)
        }
    }

    // MARK: - Window Construction

    private func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.setFrameAutosaveName("PRPeekDiffWindow")
        w.minSize = NSSize(width: 720, height: 440)
        w.center()
        w.delegate = self
        w.appearance = model.theme.nsAppearance

        let content = NSView()
        w.contentView = content

        // Header View
        let headerView = makeHeaderView()
        headerView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(headerView)

        // Split View
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(splitView)

        // Left Pane: File List
        let leftPane = makeFileListPane()
        splitView.addSubview(leftPane)

        // Right Pane: Diff View
        let rightPane = makeDiffPane()
        splitView.addSubview(rightPane)

        // Adjust split position
        splitView.setPosition(260, ofDividerAt: 0)

        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: content.topAnchor),
            headerView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            headerView.heightAnchor.constraint(equalToConstant: 48),

            splitView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        return w
    }

    private func makeHeaderView() -> NSView {
        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        modeControl.segmentCount = 2
        modeControl.setLabel("◫ Side-by-Side", forSegment: 0)
        modeControl.setLabel("☰ Inline", forSegment: 1)
        modeControl.setToolTip("Side-by-Side diff view (⌘1)", forSegment: 0)
        modeControl.setToolTip("Inline unified diff view (⌘2)", forSegment: 1)
        modeControl.selectedSegment = viewMode.rawValue
        modeControl.target = self
        modeControl.action = #selector(modeChanged(_:))
        modeControl.translatesAutoresizingMaskIntoConstraints = false

        let openBrowserBtn = NSButton(image: Self.symbol("arrow.up.right.square"), target: self, action: #selector(openOnGitHub))
        openBrowserBtn.isBordered = false
        openBrowserBtn.toolTip = "Open Pull Request on GitHub (⌘O)"
        openBrowserBtn.translatesAutoresizingMaskIntoConstraints = false

        bar.addSubview(repoBadge.view)
        bar.addSubview(titleLabel)
        bar.addSubview(statsBadge.view)
        bar.addSubview(modeControl)
        bar.addSubview(openBrowserBtn)

        let bottomDivider = NSBox()
        bottomDivider.boxType = .separator
        bottomDivider.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(bottomDivider)

        NSLayoutConstraint.activate([
            repoBadge.view.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 14),
            repoBadge.view.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: repoBadge.view.trailingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: statsBadge.view.leadingAnchor, constant: -10),

            statsBadge.view.trailingAnchor.constraint(equalTo: modeControl.leadingAnchor, constant: -14),
            statsBadge.view.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            modeControl.trailingAnchor.constraint(equalTo: openBrowserBtn.leadingAnchor, constant: -10),
            modeControl.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            openBrowserBtn.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -14),
            openBrowserBtn.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            openBrowserBtn.widthAnchor.constraint(equalToConstant: 24),
            openBrowserBtn.heightAnchor.constraint(equalToConstant: 24),

            bottomDivider.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            bottomDivider.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            bottomDivider.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            bottomDivider.heightAnchor.constraint(equalToConstant: 1),
        ])

        return bar
    }

    private func makeFileListPane() -> NSView {
        let pane = NSView()
        pane.translatesAutoresizingMaskIntoConstraints = false

        fileFilterField.placeholderString = "Filter files…"
        fileFilterField.target = self
        fileFilterField.action = #selector(filterFilesChanged)
        fileFilterField.translatesAutoresizingMaskIntoConstraints = false

        fileTable.headerView = nil
        fileTable.rowHeight = 32
        fileTable.style = .plain
        fileTable.selectionHighlightStyle = .regular
        let col = NSTableColumn(identifier: .init("file"))
        col.resizingMask = .autoresizingMask
        fileTable.addTableColumn(col)
        fileTable.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        fileTable.dataSource = self
        fileTable.delegate = self
        fileTable.target = self
        fileTable.action = #selector(fileSelected)
        fileTable.onEscape = { [weak self] in self?.hide() }

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = fileTable
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        pane.addSubview(fileFilterField)
        pane.addSubview(scroll)

        NSLayoutConstraint.activate([
            fileFilterField.topAnchor.constraint(equalTo: pane.topAnchor, constant: 8),
            fileFilterField.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 8),
            fileFilterField.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -8),

            scroll.topAnchor.constraint(equalTo: fileFilterField.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: pane.bottomAnchor),
        ])
        return pane
    }

    private func makeDiffPane() -> NSView {
        let pane = NSView()
        pane.translatesAutoresizingMaskIntoConstraints = false

        // File Path bar at top of diff
        let fileBar = NSView()
        fileBar.wantsLayer = true
        fileBar.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        fileBar.translatesAutoresizingMaskIntoConstraints = false

        currentFilePathLabel.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        currentFilePathLabel.lineBreakMode = .byTruncatingHead
        currentFilePathLabel.isSelectable = true
        currentFilePathLabel.translatesAutoresizingMaskIntoConstraints = false

        let copyPathBtn = NSButton(image: Self.symbol("doc.on.doc"), target: self, action: #selector(copyCurrentPath))
        copyPathBtn.isBordered = false
        copyPathBtn.toolTip = "Copy File Path"
        copyPathBtn.translatesAutoresizingMaskIntoConstraints = false

        fileBar.addSubview(currentFileStatusBadge.view)
        fileBar.addSubview(currentFilePathLabel)
        fileBar.addSubview(copyPathBtn)

        NSLayoutConstraint.activate([
            currentFileStatusBadge.view.leadingAnchor.constraint(equalTo: fileBar.leadingAnchor, constant: 10),
            currentFileStatusBadge.view.centerYAnchor.constraint(equalTo: fileBar.centerYAnchor),

            currentFilePathLabel.leadingAnchor.constraint(equalTo: currentFileStatusBadge.view.trailingAnchor, constant: 8),
            currentFilePathLabel.centerYAnchor.constraint(equalTo: fileBar.centerYAnchor),
            currentFilePathLabel.trailingAnchor.constraint(lessThanOrEqualTo: copyPathBtn.leadingAnchor, constant: -8),

            copyPathBtn.trailingAnchor.constraint(equalTo: fileBar.trailingAnchor, constant: -10),
            copyPathBtn.centerYAnchor.constraint(equalTo: fileBar.centerYAnchor),
            copyPathBtn.widthAnchor.constraint(equalToConstant: 20),
            copyPathBtn.heightAnchor.constraint(equalToConstant: 20),
        ])

        diffTable.headerView = nil
        diffTable.rowHeight = 20
        diffTable.style = .plain
        diffTable.intercellSpacing = .zero
        diffTable.selectionHighlightStyle = .none
        let col = NSTableColumn(identifier: .init("diff"))
        col.resizingMask = .autoresizingMask
        diffTable.addTableColumn(col)
        diffTable.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        diffTable.dataSource = self
        diffTable.delegate = self
        diffTable.onEscape = { [weak self] in self?.hide() }

        let diffScroll = NSScrollView()
        diffScroll.translatesAutoresizingMaskIntoConstraints = false
        diffScroll.documentView = diffTable
        diffScroll.hasVerticalScroller = true
        diffScroll.hasHorizontalScroller = true
        diffScroll.autohidesScrollers = true

        emptyStateLabel.font = .systemFont(ofSize: 13, weight: .medium)
        emptyStateLabel.textColor = .secondaryLabelColor
        emptyStateLabel.alignment = .center
        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .regular
        progressIndicator.isDisplayedWhenStopped = false
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false

        pane.addSubview(fileBar)
        pane.addSubview(diffScroll)
        pane.addSubview(emptyStateLabel)
        pane.addSubview(progressIndicator)

        NSLayoutConstraint.activate([
            fileBar.topAnchor.constraint(equalTo: pane.topAnchor),
            fileBar.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            fileBar.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            fileBar.heightAnchor.constraint(equalToConstant: 32),

            diffScroll.topAnchor.constraint(equalTo: fileBar.bottomAnchor),
            diffScroll.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            diffScroll.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            diffScroll.bottomAnchor.constraint(equalTo: pane.bottomAnchor),

            emptyStateLabel.centerXAnchor.constraint(equalTo: pane.centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: pane.centerYAnchor),

            progressIndicator.centerXAnchor.constraint(equalTo: pane.centerXAnchor),
            progressIndicator.bottomAnchor.constraint(equalTo: emptyStateLabel.topAnchor, constant: -12),
        ])

        return pane
    }

    // MARK: - Actions & Shortcuts

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        if let mode = ViewMode(rawValue: sender.selectedSegment) {
            viewMode = mode
        }
    }

    @objc private func openOnGitHub() {
        guard let pr = currentPR else { return }
        model.open(pr)
    }

    @objc private func copyCurrentPath() {
        guard filteredFiles.indices.contains(selectedFileIndex) else { return }
        let path = filteredFiles[selectedFileIndex].filename
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    @objc private func filterFilesChanged() {
        applyFileFilter()
    }

    @objc private func fileSelected() {
        selectFile(at: fileTable.selectedRow)
    }

    // Keyboard Shortcuts
    func windowDidBecomeKey(_ notification: Notification) {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible else { return event }
            if event.modifierFlags.contains(.command) {
                if event.charactersIgnoringModifiers == "1" {
                    self.viewMode = .sideBySide; return nil
                } else if event.charactersIgnoringModifiers == "2" {
                    self.viewMode = .inline; return nil
                } else if event.charactersIgnoringModifiers == "w" {
                    self.hide(); return nil
                } else if event.charactersIgnoringModifiers == "o" {
                    self.openOnGitHub(); return nil
                }
            } else if event.keyCode == 48 { // Tab
                self.viewMode = self.viewMode == .sideBySide ? .inline : .sideBySide
                return nil
            } else if event.keyCode == 30 { // ] -> Next file
                if self.selectedFileIndex < self.filteredFiles.count - 1 {
                    self.selectFile(at: self.selectedFileIndex + 1)
                }
                return nil
            } else if event.keyCode == 33 { // [ -> Previous file
                if self.selectedFileIndex > 0 {
                    self.selectFile(at: self.selectedFileIndex - 1)
                }
                return nil
            }
            return event
        }
    }

    // MARK: - NSTableViewDataSource & Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === fileTable {
            return filteredFiles.count
        } else {
            return viewMode == .sideBySide ? currentSideBySideRows.count : currentUnifiedLines.count
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === fileTable {
            guard filteredFiles.indices.contains(row) else { return nil }
            let file = filteredFiles[row]
            let cell = (tableView.makeView(withIdentifier: .init("fileCell"), owner: self) as? DiffFileCellView)
                ?? DiffFileCellView(frame: .zero)
            cell.identifier = .init("fileCell")
            cell.configure(file: file, palette: model.palette)
            return cell
        } else {
            if viewMode == .sideBySide {
                guard currentSideBySideRows.indices.contains(row) else { return nil }
                let item = currentSideBySideRows[row]
                let cell = (tableView.makeView(withIdentifier: .init("sbsCell"), owner: self) as? SideBySideDiffCellView)
                    ?? SideBySideDiffCellView(frame: .zero)
                cell.identifier = .init("sbsCell")
                cell.configure(row: item, palette: model.palette)
                return cell
            } else {
                guard currentUnifiedLines.indices.contains(row) else { return nil }
                let item = currentUnifiedLines[row]
                let cell = (tableView.makeView(withIdentifier: .init("inlineCell"), owner: self) as? InlineDiffCellView)
                    ?? InlineDiffCellView(frame: .zero)
                cell.identifier = .init("inlineCell")
                cell.configure(line: item, palette: model.palette)
                return cell
            }
        }
    }

    // MARK: - Helpers

    private static func makePill() -> (view: NSView, label: NSTextField) {
        let pill = NSView()
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 5
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.setContentHuggingPriority(.required, for: .horizontal)

        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.maximumNumberOfLines = 1
        label.usesSingleLineMode = true
        label.cell?.wraps = false
        label.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(label)

        NSLayoutConstraint.activate([
            pill.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
        ])
        return (pill, label)
    }

    private static func symbol(_ name: String) -> NSImage {
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()
        img.isTemplate = true
        return img
    }
}

// MARK: - Custom Views for Diff

/// Cell view for the changed files list in the left sidebar
private final class DiffFileCellView: NSTableCellView {
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let diffBadge = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown

        nameLabel.font = .systemFont(ofSize: 11.5, weight: .regular)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        diffBadge.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        diffBadge.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(nameLabel)
        addSubview(diffBadge)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),

            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: diffBadge.leadingAnchor, constant: -6),

            diffBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            diffBadge.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(file: PullRequestFile, palette: Palette?) {
        let iconName = file.status.symbol
        let color: NSColor
        switch file.status {
        case .added: color = palette?.green ?? .systemGreen
        case .removed: color = palette?.red ?? .systemRed
        case .modified: color = palette?.blue ?? .systemBlue
        case .renamed: color = palette?.yellow ?? .systemOrange
        default: color = palette?.subtext ?? .secondaryLabelColor
        }

        let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            .applying(.init(paletteColors: [color]))
        iconView.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)

        nameLabel.stringValue = (file.filename as NSString).lastPathComponent
        nameLabel.toolTip = file.filename
        nameLabel.textColor = palette?.text ?? .labelColor

        diffBadge.stringValue = "+\(file.additions) -\(file.deletions)"
        diffBadge.textColor = palette?.subtext ?? .secondaryLabelColor
    }
}

/// Cell view for Inline (Unified) diff row
private final class InlineDiffCellView: NSTableCellView {
    private let oldNumLabel = NSTextField(labelWithString: "")
    private let newNumLabel = NSTextField(labelWithString: "")
    private let prefixLabel = NSTextField(labelWithString: "")
    private let codeLabel = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        wantsLayer = true

        oldNumLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        oldNumLabel.alignment = .right
        oldNumLabel.textColor = .tertiaryLabelColor
        oldNumLabel.translatesAutoresizingMaskIntoConstraints = false

        newNumLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        newNumLabel.alignment = .right
        newNumLabel.textColor = .tertiaryLabelColor
        newNumLabel.translatesAutoresizingMaskIntoConstraints = false

        prefixLabel.font = .monospacedSystemFont(ofSize: 11.5, weight: .bold)
        prefixLabel.alignment = .center
        prefixLabel.translatesAutoresizingMaskIntoConstraints = false

        codeLabel.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        codeLabel.lineBreakMode = .byClipping
        codeLabel.isSelectable = true
        codeLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(oldNumLabel)
        addSubview(newNumLabel)
        addSubview(prefixLabel)
        addSubview(codeLabel)

        NSLayoutConstraint.activate([
            oldNumLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            oldNumLabel.widthAnchor.constraint(equalToConstant: 40),
            oldNumLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            newNumLabel.leadingAnchor.constraint(equalTo: oldNumLabel.trailingAnchor, constant: 4),
            newNumLabel.widthAnchor.constraint(equalToConstant: 40),
            newNumLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            prefixLabel.leadingAnchor.constraint(equalTo: newNumLabel.trailingAnchor, constant: 4),
            prefixLabel.widthAnchor.constraint(equalToConstant: 16),
            prefixLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            codeLabel.leadingAnchor.constraint(equalTo: prefixLabel.trailingAnchor, constant: 6),
            codeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            codeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(line: UnifiedDiffLine, palette: Palette?) {
        oldNumLabel.stringValue = line.oldLineNumber.map(String.init) ?? ""
        newNumLabel.stringValue = line.newLineNumber.map(String.init) ?? ""
        codeLabel.stringValue = line.text

        switch line.kind {
        case .addition:
            prefixLabel.stringValue = "+"
            prefixLabel.textColor = palette?.green ?? .systemGreen
            codeLabel.textColor = palette?.text ?? .labelColor
            layer?.backgroundColor = (palette?.green ?? .systemGreen).withAlphaComponent(0.13).cgColor
        case .deletion:
            prefixLabel.stringValue = "-"
            prefixLabel.textColor = palette?.red ?? .systemRed
            codeLabel.textColor = palette?.text ?? .labelColor
            layer?.backgroundColor = (palette?.red ?? .systemRed).withAlphaComponent(0.13).cgColor
        case .hunkHeader:
            prefixLabel.stringValue = "@@"
            prefixLabel.textColor = palette?.mauve ?? .systemPurple
            codeLabel.textColor = palette?.mauve ?? .systemPurple
            layer?.backgroundColor = (palette?.mauve ?? .systemPurple).withAlphaComponent(0.11).cgColor
        case .comment:
            prefixLabel.stringValue = "\\"
            prefixLabel.textColor = .secondaryLabelColor
            codeLabel.textColor = .secondaryLabelColor
            layer?.backgroundColor = NSColor.clear.cgColor
        case .context:
            prefixLabel.stringValue = ""
            codeLabel.textColor = palette?.text ?? .labelColor
            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }
}

/// Cell view for Side-by-Side (Split) diff row
private final class SideBySideDiffCellView: NSTableCellView {
    private let leftNumLabel = NSTextField(labelWithString: "")
    private let leftCodeLabel = NSTextField(labelWithString: "")
    private let leftBgView = NSView()

    private let divider = NSBox()

    private let rightNumLabel = NSTextField(labelWithString: "")
    private let rightCodeLabel = NSTextField(labelWithString: "")
    private let rightBgView = NSView()

    private let hunkHeaderLabel = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        wantsLayer = true

        leftBgView.wantsLayer = true
        leftBgView.translatesAutoresizingMaskIntoConstraints = false

        rightBgView.wantsLayer = true
        rightBgView.translatesAutoresizingMaskIntoConstraints = false

        leftNumLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        leftNumLabel.alignment = .right
        leftNumLabel.textColor = .tertiaryLabelColor
        leftNumLabel.translatesAutoresizingMaskIntoConstraints = false

        leftCodeLabel.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        leftCodeLabel.lineBreakMode = .byClipping
        leftCodeLabel.isSelectable = true
        leftCodeLabel.translatesAutoresizingMaskIntoConstraints = false

        rightNumLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        rightNumLabel.alignment = .right
        rightNumLabel.textColor = .tertiaryLabelColor
        rightNumLabel.translatesAutoresizingMaskIntoConstraints = false

        rightCodeLabel.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        rightCodeLabel.lineBreakMode = .byClipping
        rightCodeLabel.isSelectable = true
        rightCodeLabel.translatesAutoresizingMaskIntoConstraints = false

        divider.boxType = .custom
        divider.borderWidth = 0.5
        divider.borderColor = .separatorColor
        divider.fillColor = .separatorColor
        divider.translatesAutoresizingMaskIntoConstraints = false

        hunkHeaderLabel.font = .monospacedSystemFont(ofSize: 11.5, weight: .medium)
        hunkHeaderLabel.textColor = .systemPurple
        hunkHeaderLabel.translatesAutoresizingMaskIntoConstraints = false
        hunkHeaderLabel.isHidden = true

        addSubview(leftBgView)
        addSubview(rightBgView)
        addSubview(divider)
        addSubview(leftNumLabel)
        addSubview(leftCodeLabel)
        addSubview(rightNumLabel)
        addSubview(rightCodeLabel)
        addSubview(hunkHeaderLabel)

        NSLayoutConstraint.activate([
            // Left Half
            leftBgView.leadingAnchor.constraint(equalTo: leadingAnchor),
            leftBgView.topAnchor.constraint(equalTo: topAnchor),
            leftBgView.bottomAnchor.constraint(equalTo: bottomAnchor),
            leftBgView.trailingAnchor.constraint(equalTo: divider.leadingAnchor),

            leftNumLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            leftNumLabel.widthAnchor.constraint(equalToConstant: 38),
            leftNumLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            leftCodeLabel.leadingAnchor.constraint(equalTo: leftNumLabel.trailingAnchor, constant: 6),
            leftCodeLabel.trailingAnchor.constraint(equalTo: divider.leadingAnchor, constant: -4),
            leftCodeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            // Middle Divider
            divider.centerXAnchor.constraint(equalTo: centerXAnchor),
            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),

            // Right Half
            rightBgView.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            rightBgView.topAnchor.constraint(equalTo: topAnchor),
            rightBgView.bottomAnchor.constraint(equalTo: bottomAnchor),
            rightBgView.trailingAnchor.constraint(equalTo: trailingAnchor),

            rightNumLabel.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 4),
            rightNumLabel.widthAnchor.constraint(equalToConstant: 38),
            rightNumLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            rightCodeLabel.leadingAnchor.constraint(equalTo: rightNumLabel.trailingAnchor, constant: 6),
            rightCodeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            rightCodeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            // Hunk Header (spans whole width)
            hunkHeaderLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            hunkHeaderLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            hunkHeaderLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(row: SideBySideDiffRow, palette: Palette?) {
        if row.isHunkHeader {
            hunkHeaderLabel.stringValue = row.hunkHeaderText ?? ""
            hunkHeaderLabel.isHidden = false
            hunkHeaderLabel.textColor = palette?.mauve ?? .systemPurple
            layer?.backgroundColor = (palette?.mauve ?? .systemPurple).withAlphaComponent(0.12).cgColor

            leftBgView.isHidden = true
            rightBgView.isHidden = true
            leftNumLabel.isHidden = true
            leftCodeLabel.isHidden = true
            rightNumLabel.isHidden = true
            rightCodeLabel.isHidden = true
            divider.isHidden = true
            return
        }

        hunkHeaderLabel.isHidden = true
        leftBgView.isHidden = false
        rightBgView.isHidden = false
        leftNumLabel.isHidden = false
        leftCodeLabel.isHidden = false
        rightNumLabel.isHidden = false
        rightCodeLabel.isHidden = false
        divider.isHidden = false
        layer?.backgroundColor = NSColor.clear.cgColor

        // Left side
        leftNumLabel.stringValue = row.left.lineNumber.map(String.init) ?? ""
        leftCodeLabel.stringValue = row.left.text
        if row.left.kind == .deletion {
            leftBgView.layer?.backgroundColor = (palette?.red ?? .systemRed).withAlphaComponent(0.13).cgColor
            leftCodeLabel.textColor = palette?.text ?? .labelColor
        } else if row.left == .empty {
            leftBgView.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.04).cgColor
            leftCodeLabel.textColor = .clear
        } else {
            leftBgView.layer?.backgroundColor = NSColor.clear.cgColor
            leftCodeLabel.textColor = palette?.text ?? .labelColor
        }

        // Right side
        rightNumLabel.stringValue = row.right.lineNumber.map(String.init) ?? ""
        rightCodeLabel.stringValue = row.right.text
        if row.right.kind == .addition {
            rightBgView.layer?.backgroundColor = (palette?.green ?? .systemGreen).withAlphaComponent(0.13).cgColor
            rightCodeLabel.textColor = palette?.text ?? .labelColor
        } else if row.right == .empty {
            rightBgView.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.04).cgColor
            rightCodeLabel.textColor = .clear
        } else {
            rightBgView.layer?.backgroundColor = NSColor.clear.cgColor
            rightCodeLabel.textColor = palette?.text ?? .labelColor
        }
    }
}
