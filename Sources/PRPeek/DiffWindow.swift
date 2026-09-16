import AppKit
import PRPeekCore

/// Dedicated, high-performance native Diff Viewer window for PRPeek.
/// Supports Side-by-Side & Inline views, intra-line word deltas, inline review comments with quick replies,
/// hunk navigation (J/K), file viewed tracking (V), in-diff search (⌘F), whitespace ignore (W),
/// folder tree vs flat list sidebar, commit-by-commit review, local IDE jump (⌘E), and review submission (⌘⇧R).
@MainActor
final class DiffWindow: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    enum ViewMode: Int {
        case sideBySide = 0
        case inline = 1
    }

    enum SidebarViewMode: Int {
        case flat = 0
        case tree = 1
    }

    enum SidebarItem {
        case folder(path: String, name: String, fileCount: Int, isExpanded: Bool, depth: Int)
        case file(PullRequestFile, depth: Int)
    }

    enum DiffTableRow {
        case unified(UnifiedDiffLine)
        case sideBySide(SideBySideDiffRow)
        case reviewComment(ReviewComment)

        var isHunkStart: Bool {
            switch self {
            case .unified(let line):
                return line.kind == .addition || line.kind == .deletion
            case .sideBySide(let row):
                return row.left.kind == .deletion || row.right.kind == .addition
            case .reviewComment:
                return false
            }
        }
    }

    private let model: AppModel
    private var window: NSWindow?
    private var keyMonitor: Any?

    private var currentPR: PullRequest?
    private var allFiles: [PullRequestFile] = []
    private var filteredFiles: [PullRequestFile] = []
    private var selectedFileIndex: Int = 0

    // Parsed diff cache for current file
    private var currentUnifiedLines: [UnifiedDiffLine] = []
    private var currentSideBySideRows: [SideBySideDiffRow] = []
    private var currentFileComments: [ReviewComment] = []
    private var tableRows: [DiffTableRow] = []

    // Navigation, Viewed & Whitespace State
    private var hunkRowIndices: [Int] = []
    private var currentHunkIndex: Int = 0
    private var viewedFilePaths: Set<String> = []

    private var ignoreWhitespace: Bool {
        get { UserDefaults.standard.bool(forKey: "diffIgnoreWhitespace") }
        set {
            UserDefaults.standard.set(newValue, forKey: "diffIgnoreWhitespace")
            updateWhitespaceBtn()
            reparseCurrentFile()
        }
    }

    // Sidebar Tree / Flat State
    private var sidebarViewMode: SidebarViewMode {
        get {
            let val = UserDefaults.standard.integer(forKey: "diffSidebarMode")
            return SidebarViewMode(rawValue: val) ?? .flat
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "diffSidebarMode")
            sidebarModeControl.selectedSegment = newValue.rawValue
            rebuildSidebarItems()
        }
    }
    private var expandedFolders: Set<String> = []
    private var sidebarItems: [SidebarItem] = []

    // In-Diff Search State
    private let searchBar = DiffSearchBarView()
    private var searchBarHeightConstraint: NSLayoutConstraint?
    private var currentSearchQuery: String = ""
    private var searchMatchRowIndices: [Int] = []
    private var currentSearchMatchIndex: Int = 0

    // Inline Reply State
    private var activeReplyCommentIDs: Set<String> = []

    // Commit Picker State
    private var currentCommitSHA: String?

    // UI Elements
    private let splitView = NSSplitView()
    private let fileFilterField = NSSearchField()
    private let sidebarModeControl = NSSegmentedControl()
    private let fileTable = KeyTableView()
    private let diffTable = KeyTableView()

    private let titleLabel = NSTextField(labelWithString: "")
    private let repoBadge = makePill()
    private let statsBadge = makePill()
    private let viewedBadge = makePill()
    private let hunkBadge = makePill()
    private let commitPopUp = NSPopUpButton()
    private let submitReviewBtn = NSButton()
    private let whitespaceBtn = NSButton()
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
            rebuildTableRows()
        }
    }

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func show(for pr: PullRequest) {
        self.currentPR = pr
        loadViewed(for: pr)

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

    private func loadViewed(for pr: PullRequest) {
        let saved = UserDefaults.standard.stringArray(forKey: "viewed_\(pr.key)") ?? []
        viewedFilePaths = Set(saved)
    }

    private func saveViewed() {
        guard let pr = currentPR else { return }
        UserDefaults.standard.set(Array(viewedFilePaths), forKey: "viewed_\(pr.key)")
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
        updateViewedProgress()
        updateWhitespaceBtn()
        updateCommitPicker()
    }

    private func updateCommitPicker() {
        guard let pr = currentPR else { return }
        commitPopUp.removeAllItems()
        commitPopUp.addItem(withTitle: "All Changes")
        commitPopUp.item(at: 0)?.representedObject = nil

        if let commits = model.commits(for: pr) {
            for c in commits {
                let title = "\(c.shortSHA): \(c.message)"
                commitPopUp.addItem(withTitle: title)
                commitPopUp.lastItem?.representedObject = c.id
            }
        }
        if let currentSHA = currentCommitSHA,
           let idx = commitPopUp.itemArray.firstIndex(where: { ($0.representedObject as? String) == currentSHA }) {
            commitPopUp.selectItem(at: idx)
        } else {
            commitPopUp.selectItem(at: 0)
        }
    }

    private func updateWhitespaceBtn() {
        let active = ignoreWhitespace
        whitespaceBtn.state = active ? .on : .off
        whitespaceBtn.title = active ? "␣ Whitespace Ignored" : "␣ Ignore Whitespace"
        if active {
            whitespaceBtn.contentTintColor = model.palette?.blue ?? .systemBlue
        } else {
            whitespaceBtn.contentTintColor = .secondaryLabelColor
        }
    }

    private func updateViewedProgress() {
        guard !allFiles.isEmpty else {
            viewedBadge.view.isHidden = true
            return
        }
        let viewedCount = allFiles.filter { viewedFilePaths.contains($0.filename) }.count
        let total = allFiles.count
        viewedBadge.label.stringValue = "✓ \(viewedCount)/\(total) viewed"
        let p = model.palette
        if viewedCount == total {
            viewedBadge.label.textColor = p?.green ?? .systemGreen
            viewedBadge.view.layer?.backgroundColor = (p?.green ?? .systemGreen).withAlphaComponent(0.14).cgColor
        } else {
            viewedBadge.label.textColor = p?.subtext ?? .secondaryLabelColor
            viewedBadge.view.layer?.backgroundColor = (p?.subtext ?? .secondaryLabelColor).withAlphaComponent(0.12).cgColor
        }
        viewedBadge.view.isHidden = false
    }

    private func loadDiff(for pr: PullRequest) {
        allFiles = []
        filteredFiles = []
        sidebarItems = []
        selectedFileIndex = 0
        fileTable.reloadData()
        tableRows = []
        diffTable.reloadData()

        emptyStateLabel.stringValue = "Loading diff from GitHub…"
        emptyStateLabel.isHidden = false
        progressIndicator.startAnimation(nil)
        progressIndicator.isHidden = false

        // Load comments and commits asynchronously in background
        model.loadComments(for: pr)
        model.loadCommits(for: pr)

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

        updateViewedProgress()
        updateCommitPicker()

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

        // Expand all folders by default when search query or files change
        if expandedFolders.isEmpty {
            for f in filteredFiles {
                if !f.directoryPath.isEmpty {
                    expandedFolders.insert(f.directoryPath)
                }
            }
        }

        rebuildSidebarItems()

        if !filteredFiles.isEmpty {
            selectFile(at: min(selectedFileIndex, filteredFiles.count - 1))
        } else {
            currentUnifiedLines = []
            currentSideBySideRows = []
            tableRows = []
            diffTable.reloadData()
            emptyStateLabel.stringValue = "No matching files."
            emptyStateLabel.isHidden = false
            hunkBadge.view.isHidden = true
        }
    }

    private func rebuildSidebarItems() {
        sidebarItems = []
        if sidebarViewMode == .flat {
            for file in filteredFiles {
                sidebarItems.append(.file(file, depth: 0))
            }
        } else {
            var folderFileMap: [String: [PullRequestFile]] = [:]
            var rootFiles: [PullRequestFile] = []

            for file in filteredFiles {
                let dir = file.directoryPath
                if dir.isEmpty {
                    rootFiles.append(file)
                } else {
                    folderFileMap[dir, default: []].append(file)
                }
            }

            let sortedFolders = folderFileMap.keys.sorted()
            for folder in sortedFolders {
                let isExpanded = expandedFolders.contains(folder)
                let name = folder.hasSuffix("/") ? String(folder.dropLast()) : folder
                let folderName = (name as NSString).lastPathComponent
                let files = folderFileMap[folder] ?? []
                sidebarItems.append(.folder(path: folder, name: folderName, fileCount: files.count, isExpanded: isExpanded, depth: 0))

                if isExpanded {
                    for file in files {
                        sidebarItems.append(.file(file, depth: 1))
                    }
                }
            }

            for file in rootFiles {
                sidebarItems.append(.file(file, depth: 0))
            }
        }
        fileTable.reloadData()
    }

    private func selectFile(at index: Int) {
        guard filteredFiles.indices.contains(index) else { return }
        selectedFileIndex = index

        // Sync selection in fileTable
        if let row = sidebarItems.firstIndex(where: {
            if case .file(let f, _) = $0 { return f.filename == filteredFiles[index].filename }
            return false
        }) {
            fileTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            fileTable.scrollRowToVisible(row)
        }

        let file = filteredFiles[index]

        // Format file path with dimmed directory breadcrumb and bold base filename
        let pathAttr = NSMutableAttributedString()
        if !file.directoryPath.isEmpty {
            pathAttr.append(NSAttributedString(string: file.directoryPath, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor
            ]))
        }
        pathAttr.append(NSAttributedString(string: file.baseFilename, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .bold),
            .foregroundColor: model.palette?.text ?? NSColor.labelColor
        ]))
        if let rename = file.renameDescription {
            pathAttr.append(NSAttributedString(string: "  (\(rename))", attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: model.palette?.yellow ?? NSColor.systemOrange
            ]))
        }
        currentFilePathLabel.attributedStringValue = pathAttr

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

        // Filter comments for this file
        if let pr = currentPR, let comments = model.comments(for: pr) {
            currentFileComments = comments.filter { $0.fileAndLine?.filename == file.filename }
        } else {
            currentFileComments = []
        }

        if let patch = file.patch {
            currentUnifiedLines = DiffParser.parseUnified(patch: patch, ignoreWhitespace: ignoreWhitespace)
            currentSideBySideRows = DiffParser.parseSideBySide(patch: patch, ignoreWhitespace: ignoreWhitespace)
            emptyStateLabel.isHidden = true
        } else {
            currentUnifiedLines = []
            currentSideBySideRows = []
            emptyStateLabel.stringValue = "Binary file or changes too large to display directly."
            emptyStateLabel.isHidden = false
        }

        rebuildTableRows()
        if !tableRows.isEmpty {
            diffTable.scrollRowToVisible(0)
        }

        if !currentSearchQuery.isEmpty {
            updateSearch(query: currentSearchQuery)
        }
    }

    private func reparseCurrentFile() {
        guard filteredFiles.indices.contains(selectedFileIndex) else { return }
        let file = filteredFiles[selectedFileIndex]
        if let patch = file.patch {
            currentUnifiedLines = DiffParser.parseUnified(patch: patch, ignoreWhitespace: ignoreWhitespace)
            currentSideBySideRows = DiffParser.parseSideBySide(patch: patch, ignoreWhitespace: ignoreWhitespace)
            emptyStateLabel.isHidden = true
        }
        rebuildTableRows()
        if !currentSearchQuery.isEmpty {
            updateSearch(query: currentSearchQuery)
        }
    }

    private func rebuildTableRows() {
        tableRows = []
        let commentsByLine = Dictionary(grouping: currentFileComments, by: { $0.fileAndLine!.line })

        if viewMode == .inline {
            for line in currentUnifiedLines {
                tableRows.append(.unified(line))
                if let lineNum = line.newLineNumber ?? line.oldLineNumber, let cmts = commentsByLine[lineNum] {
                    for c in cmts {
                        tableRows.append(.reviewComment(c))
                    }
                }
            }
        } else {
            for row in currentSideBySideRows {
                tableRows.append(.sideBySide(row))
                if let lineNum = row.right.lineNumber ?? row.left.lineNumber, let cmts = commentsByLine[lineNum] {
                    for c in cmts {
                        tableRows.append(.reviewComment(c))
                    }
                }
            }
        }

        updateHunks()
        diffTable.reloadData()
    }

    private func updateHunks() {
        hunkRowIndices = []
        var inHunk = false
        for (i, row) in tableRows.enumerated() {
            if row.isHunkStart {
                if !inHunk {
                    hunkRowIndices.append(i)
                    inHunk = true
                }
            } else {
                inHunk = false
            }
        }
        currentHunkIndex = 0
        updateHunkBadge()
    }

    private func updateHunkBadge() {
        if hunkRowIndices.isEmpty {
            hunkBadge.label.stringValue = "0 hunks"
            hunkBadge.label.textColor = model.palette?.subtext ?? .secondaryLabelColor
            hunkBadge.view.layer?.backgroundColor = (model.palette?.subtext ?? .secondaryLabelColor).withAlphaComponent(0.12).cgColor
        } else {
            hunkBadge.label.stringValue = "Hunk \(currentHunkIndex + 1) of \(hunkRowIndices.count)"
            hunkBadge.label.textColor = model.palette?.blue ?? .systemBlue
            hunkBadge.view.layer?.backgroundColor = (model.palette?.blue ?? .systemBlue).withAlphaComponent(0.14).cgColor
        }
        hunkBadge.view.isHidden = false
    }

    private func jumpToNextHunk() {
        guard !hunkRowIndices.isEmpty else { return }
        currentHunkIndex = min(currentHunkIndex + 1, hunkRowIndices.count - 1)
        diffTable.scrollRowToVisible(hunkRowIndices[currentHunkIndex])
        updateHunkBadge()
    }

    private func jumpToPrevHunk() {
        guard !hunkRowIndices.isEmpty else { return }
        currentHunkIndex = max(currentHunkIndex - 1, 0)
        diffTable.scrollRowToVisible(hunkRowIndices[currentHunkIndex])
        updateHunkBadge()
    }

    private func toggleViewedCurrentFile() {
        guard filteredFiles.indices.contains(selectedFileIndex) else { return }
        let file = filteredFiles[selectedFileIndex]
        if viewedFilePaths.contains(file.filename) {
            viewedFilePaths.remove(file.filename)
        } else {
            viewedFilePaths.insert(file.filename)
            if let nextIdx = filteredFiles.indices.first(where: { $0 > selectedFileIndex && !viewedFilePaths.contains(filteredFiles[$0].filename) })
                ?? filteredFiles.indices.first(where: { !viewedFilePaths.contains(filteredFiles[$0].filename) }) {
                selectFile(at: nextIdx)
            }
        }
        saveViewed()
        rebuildSidebarItems()
        updateViewedProgress()
    }

    private func toggleIgnoreWhitespace() {
        ignoreWhitespace.toggle()
    }

    // MARK: - In-Diff Search Methods

    private func toggleSearchBar() {
        if searchBar.isHidden {
            searchBar.isHidden = false
            searchBarHeightConstraint?.constant = 34
            window?.makeFirstResponder(searchBar.searchField)
            searchBar.searchField.selectText(nil)
            if !searchBar.searchField.stringValue.isEmpty {
                updateSearch(query: searchBar.searchField.stringValue)
            }
        } else {
            closeSearchBar()
        }
    }

    private func closeSearchBar() {
        searchBar.isHidden = true
        searchBarHeightConstraint?.constant = 0
        searchBar.searchField.stringValue = ""
        currentSearchQuery = ""
        searchMatchRowIndices = []
        searchBar.matchLabel.stringValue = ""
        window?.makeFirstResponder(diffTable)
        diffTable.reloadData()
    }

    private func updateSearch(query: String) {
        currentSearchQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchMatchRowIndices = []
        currentSearchMatchIndex = 0

        guard !currentSearchQuery.isEmpty else {
            searchBar.matchLabel.stringValue = ""
            diffTable.reloadData()
            return
        }

        let q = currentSearchQuery.lowercased()
        for (i, row) in tableRows.enumerated() {
            switch row {
            case .unified(let line):
                if line.text.lowercased().contains(q) {
                    searchMatchRowIndices.append(i)
                }
            case .sideBySide(let sbs):
                if sbs.left.text.lowercased().contains(q) || sbs.right.text.lowercased().contains(q) {
                    searchMatchRowIndices.append(i)
                }
            case .reviewComment(let c):
                if c.body.lowercased().contains(q) || c.author.lowercased().contains(q) {
                    searchMatchRowIndices.append(i)
                }
            }
        }

        if searchMatchRowIndices.isEmpty {
            searchBar.matchLabel.stringValue = "0 matches"
        } else {
            searchBar.matchLabel.stringValue = "1 of \(searchMatchRowIndices.count)"
            diffTable.scrollRowToVisible(searchMatchRowIndices[0])
        }
        diffTable.reloadData()
    }

    private func searchNext() {
        guard !searchMatchRowIndices.isEmpty else { return }
        currentSearchMatchIndex = (currentSearchMatchIndex + 1) % searchMatchRowIndices.count
        searchBar.matchLabel.stringValue = "\(currentSearchMatchIndex + 1) of \(searchMatchRowIndices.count)"
        diffTable.scrollRowToVisible(searchMatchRowIndices[currentSearchMatchIndex])
    }

    private func searchPrev() {
        guard !searchMatchRowIndices.isEmpty else { return }
        currentSearchMatchIndex = (currentSearchMatchIndex - 1 + searchMatchRowIndices.count) % searchMatchRowIndices.count
        searchBar.matchLabel.stringValue = "\(currentSearchMatchIndex + 1) of \(searchMatchRowIndices.count)"
        diffTable.scrollRowToVisible(searchMatchRowIndices[currentSearchMatchIndex])
    }

    // MARK: - Window Construction

    private func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.setFrameAutosaveName("PRPeekDiffWindow")
        w.minSize = NSSize(width: 840, height: 520)
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
        splitView.setPosition(290, ofDividerAt: 0)

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

        commitPopUp.bezelStyle = .rounded
        commitPopUp.font = .systemFont(ofSize: 11, weight: .medium)
        commitPopUp.target = self
        commitPopUp.action = #selector(commitPickerChanged(_:))
        commitPopUp.translatesAutoresizingMaskIntoConstraints = false

        submitReviewBtn.title = "Submit Review…"
        submitReviewBtn.bezelStyle = .rounded
        submitReviewBtn.font = .systemFont(ofSize: 11, weight: .semibold)
        submitReviewBtn.target = self
        submitReviewBtn.action = #selector(showSubmitReviewSheet)
        submitReviewBtn.toolTip = "Submit Pull Request Review (⌘⇧R)"
        submitReviewBtn.translatesAutoresizingMaskIntoConstraints = false

        whitespaceBtn.setButtonType(.pushOnPushOff)
        whitespaceBtn.bezelStyle = .inline
        whitespaceBtn.font = .systemFont(ofSize: 11, weight: .medium)
        whitespaceBtn.target = self
        whitespaceBtn.action = #selector(toggleWhitespaceClicked)
        whitespaceBtn.toolTip = "Toggle Ignore Whitespace (W)"
        whitespaceBtn.translatesAutoresizingMaskIntoConstraints = false
        updateWhitespaceBtn()

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
        bar.addSubview(commitPopUp)
        bar.addSubview(statsBadge.view)
        bar.addSubview(viewedBadge.view)
        bar.addSubview(hunkBadge.view)
        bar.addSubview(whitespaceBtn)
        bar.addSubview(submitReviewBtn)
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
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: commitPopUp.leadingAnchor, constant: -10),

            commitPopUp.trailingAnchor.constraint(equalTo: statsBadge.view.leadingAnchor, constant: -8),
            commitPopUp.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            commitPopUp.widthAnchor.constraint(lessThanOrEqualToConstant: 180),

            statsBadge.view.trailingAnchor.constraint(equalTo: viewedBadge.view.leadingAnchor, constant: -8),
            statsBadge.view.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            viewedBadge.view.trailingAnchor.constraint(equalTo: hunkBadge.view.leadingAnchor, constant: -8),
            viewedBadge.view.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            hunkBadge.view.trailingAnchor.constraint(equalTo: whitespaceBtn.leadingAnchor, constant: -10),
            hunkBadge.view.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            whitespaceBtn.trailingAnchor.constraint(equalTo: submitReviewBtn.leadingAnchor, constant: -10),
            whitespaceBtn.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            submitReviewBtn.trailingAnchor.constraint(equalTo: modeControl.leadingAnchor, constant: -10),
            submitReviewBtn.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

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

        sidebarModeControl.segmentCount = 2
        sidebarModeControl.setLabel("☰", forSegment: 0)
        sidebarModeControl.setToolTip("Flat List", forSegment: 0)
        sidebarModeControl.setLabel("☵", forSegment: 1)
        sidebarModeControl.setToolTip("Folder Tree", forSegment: 1)
        sidebarModeControl.selectedSegment = sidebarViewMode.rawValue
        sidebarModeControl.target = self
        sidebarModeControl.action = #selector(sidebarModeChanged(_:))
        sidebarModeControl.translatesAutoresizingMaskIntoConstraints = false

        fileTable.headerView = nil
        fileTable.rowHeight = 34
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
        fileTable.contextMenuProvider = { [weak self] in self?.makeFileContextMenu() }

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = fileTable
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        pane.addSubview(fileFilterField)
        pane.addSubview(sidebarModeControl)
        pane.addSubview(scroll)

        NSLayoutConstraint.activate([
            fileFilterField.topAnchor.constraint(equalTo: pane.topAnchor, constant: 8),
            fileFilterField.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 8),
            fileFilterField.trailingAnchor.constraint(equalTo: sidebarModeControl.leadingAnchor, constant: -6),

            sidebarModeControl.centerYAnchor.constraint(equalTo: fileFilterField.centerYAnchor),
            sidebarModeControl.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -8),
            sidebarModeControl.widthAnchor.constraint(equalToConstant: 60),

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

        let ideBtn = NSButton(image: Self.symbol("arrow.up.forward.app"), target: self, action: #selector(openInIDEClicked))
        ideBtn.isBordered = false
        ideBtn.toolTip = "Open in Local IDE (⌘E)"
        ideBtn.translatesAutoresizingMaskIntoConstraints = false

        let findBtn = NSButton(image: Self.symbol("magnifyingglass"), target: self, action: #selector(toggleFindClicked))
        findBtn.isBordered = false
        findBtn.toolTip = "Find in Diff (⌘F)"
        findBtn.translatesAutoresizingMaskIntoConstraints = false

        let toggleViewedBtn = NSButton(title: "Mark Viewed (V)", target: self, action: #selector(toggleViewedClicked))
        toggleViewedBtn.bezelStyle = .inline
        toggleViewedBtn.font = .systemFont(ofSize: 11, weight: .medium)
        toggleViewedBtn.translatesAutoresizingMaskIntoConstraints = false

        let copyPathBtn = NSButton(image: Self.symbol("doc.on.doc"), target: self, action: #selector(copyCurrentPath))
        copyPathBtn.isBordered = false
        copyPathBtn.toolTip = "Copy File Path"
        copyPathBtn.translatesAutoresizingMaskIntoConstraints = false

        fileBar.addSubview(currentFileStatusBadge.view)
        fileBar.addSubview(currentFilePathLabel)
        fileBar.addSubview(ideBtn)
        fileBar.addSubview(findBtn)
        fileBar.addSubview(toggleViewedBtn)
        fileBar.addSubview(copyPathBtn)

        NSLayoutConstraint.activate([
            currentFileStatusBadge.view.leadingAnchor.constraint(equalTo: fileBar.leadingAnchor, constant: 10),
            currentFileStatusBadge.view.centerYAnchor.constraint(equalTo: fileBar.centerYAnchor),

            currentFilePathLabel.leadingAnchor.constraint(equalTo: currentFileStatusBadge.view.trailingAnchor, constant: 8),
            currentFilePathLabel.centerYAnchor.constraint(equalTo: fileBar.centerYAnchor),
            currentFilePathLabel.trailingAnchor.constraint(lessThanOrEqualTo: ideBtn.leadingAnchor, constant: -8),

            ideBtn.trailingAnchor.constraint(equalTo: findBtn.leadingAnchor, constant: -8),
            ideBtn.centerYAnchor.constraint(equalTo: fileBar.centerYAnchor),
            ideBtn.widthAnchor.constraint(equalToConstant: 20),
            ideBtn.heightAnchor.constraint(equalToConstant: 20),

            findBtn.trailingAnchor.constraint(equalTo: toggleViewedBtn.leadingAnchor, constant: -8),
            findBtn.centerYAnchor.constraint(equalTo: fileBar.centerYAnchor),
            findBtn.widthAnchor.constraint(equalToConstant: 20),
            findBtn.heightAnchor.constraint(equalToConstant: 20),

            toggleViewedBtn.trailingAnchor.constraint(equalTo: copyPathBtn.leadingAnchor, constant: -8),
            toggleViewedBtn.centerYAnchor.constraint(equalTo: fileBar.centerYAnchor),

            copyPathBtn.trailingAnchor.constraint(equalTo: fileBar.trailingAnchor, constant: -10),
            copyPathBtn.centerYAnchor.constraint(equalTo: fileBar.centerYAnchor),
            copyPathBtn.widthAnchor.constraint(equalToConstant: 20),
            copyPathBtn.heightAnchor.constraint(equalToConstant: 20),
        ])

        // In-Diff Search Bar
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        searchBar.isHidden = true
        searchBar.onQueryChanged = { [weak self] q in self?.updateSearch(query: q) }
        searchBar.onNext = { [weak self] in self?.searchNext() }
        searchBar.onPrev = { [weak self] in self?.searchPrev() }
        searchBar.onClose = { [weak self] in self?.closeSearchBar() }

        let searchHeight = searchBar.heightAnchor.constraint(equalToConstant: 0)
        self.searchBarHeightConstraint = searchHeight

        diffTable.headerView = nil
        diffTable.rowHeight = 20
        diffTable.style = .plain
        diffTable.intercellSpacing = .zero
        diffTable.selectionHighlightStyle = .regular
        let col = NSTableColumn(identifier: .init("diff"))
        col.resizingMask = .autoresizingMask
        diffTable.addTableColumn(col)
        diffTable.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        diffTable.dataSource = self
        diffTable.delegate = self
        diffTable.onEscape = { [weak self] in self?.hide() }
        diffTable.contextMenuProvider = { [weak self] in self?.makeDiffContextMenu() }

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
        pane.addSubview(searchBar)
        pane.addSubview(diffScroll)
        pane.addSubview(emptyStateLabel)
        pane.addSubview(progressIndicator)

        NSLayoutConstraint.activate([
            fileBar.topAnchor.constraint(equalTo: pane.topAnchor),
            fileBar.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            fileBar.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            fileBar.heightAnchor.constraint(equalToConstant: 32),

            searchBar.topAnchor.constraint(equalTo: fileBar.bottomAnchor),
            searchBar.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            searchBar.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            searchHeight,

            diffScroll.topAnchor.constraint(equalTo: searchBar.bottomAnchor),
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

    @objc private func sidebarModeChanged(_ sender: NSSegmentedControl) {
        if let mode = SidebarViewMode(rawValue: sender.selectedSegment) {
            sidebarViewMode = mode
        }
    }

    @objc private func commitPickerChanged(_ sender: NSPopUpButton) {
        if sender.indexOfSelectedItem == 0 {
            currentCommitSHA = nil
            populateFiles(allFiles)
        } else if let sha = sender.selectedItem?.representedObject as? String, let pr = currentPR {
            currentCommitSHA = sha
            emptyStateLabel.stringValue = "Loading commit diff…"
            emptyStateLabel.isHidden = false
            progressIndicator.startAnimation(nil)
            progressIndicator.isHidden = false

            Task { @MainActor in
                do {
                    let commitFiles = try await model.commitFiles(for: pr, sha: sha)
                    progressIndicator.stopAnimation(nil)
                    progressIndicator.isHidden = true
                    populateFiles(commitFiles)
                } catch {
                    progressIndicator.stopAnimation(nil)
                    progressIndicator.isHidden = true
                    emptyStateLabel.stringValue = "Failed to load commit: \(error.localizedDescription)"
                    emptyStateLabel.isHidden = false
                }
            }
        }
    }

    @objc private func openOnGitHub() {
        guard let pr = currentPR else { return }
        model.open(pr)
    }

    @objc private func toggleViewedClicked() {
        toggleViewedCurrentFile()
    }

    @objc private func toggleFindClicked() {
        toggleSearchBar()
    }

    @objc private func toggleWhitespaceClicked() {
        toggleIgnoreWhitespace()
    }

    @objc private func openInIDEClicked() {
        openCurrentFileInLocalIDE()
    }

    @objc private func showSubmitReviewSheet() {
        guard let pr = currentPR, let window else { return }
        let sheet = ReviewSubmissionSheet(pr: pr, palette: model.palette)
        sheet.onSubmit = { [weak self] verdict, body in
            guard let self else { return "Window closed." }
            let error = await self.model.submitReview(pr, verdict: verdict, body: body)
            if error == nil {
                self.loadDiff(for: pr)
            }
            return error
        }
        window.beginSheet(sheet.window!) { _ in }
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
        let selRow = fileTable.selectedRow
        guard sidebarItems.indices.contains(selRow) else { return }
        switch sidebarItems[selRow] {
        case .folder(let path, _, _, let isExpanded, _):
            if isExpanded {
                expandedFolders.remove(path)
            } else {
                expandedFolders.insert(path)
            }
            rebuildSidebarItems()
        case .file(let file, _):
            if let idx = filteredFiles.firstIndex(where: { $0.filename == file.filename }) {
                selectFile(at: idx)
            }
        }
    }

    // MARK: - Local IDE Jump & Git Helpers

    private func currentSelectedLineNumber() -> Int? {
        let selRow = diffTable.selectedRow
        guard selRow >= 0 && selRow < tableRows.count else { return 1 }
        switch tableRows[selRow] {
        case .unified(let line): return line.newLineNumber ?? line.oldLineNumber ?? 1
        case .sideBySide(let sbs): return sbs.right.lineNumber ?? sbs.left.lineNumber ?? 1
        case .reviewComment(let c): return c.fileAndLine?.line ?? 1
        }
    }

    private func findLocalRepoPath(for pr: PullRequest) -> String? {
        let repoName = pr.repoName
        let repoFull = pr.repoFullName

        if let saved = UserDefaults.standard.string(forKey: "localRepo_\(repoFull)"),
           FileManager.default.fileExists(atPath: saved) {
            return saved
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            FileManager.default.currentDirectoryPath,
            "\(home)/experiments/\(repoName)",
            "\(home)/Developer/\(repoName)",
            "\(home)/Projects/\(repoName)",
            "\(home)/workspace/\(repoName)",
            "\(home)/src/\(repoName)",
            "\(home)/code/\(repoName)",
            "\(home)/\(repoName)"
        ]

        for path in candidates {
            if FileManager.default.fileExists(atPath: "\(path)/.git") || FileManager.default.fileExists(atPath: path) {
                if (path as NSString).lastPathComponent.lowercased() == repoName.lowercased() {
                    UserDefaults.standard.set(path, forKey: "localRepo_\(repoFull)")
                    return path
                }
            }
        }
        return nil
    }

    private func openCurrentFileInLocalIDE() {
        guard filteredFiles.indices.contains(selectedFileIndex), let pr = currentPR else { return }
        let file = filteredFiles[selectedFileIndex]
        let line = currentSelectedLineNumber()

        guard let repoPath = findLocalRepoPath(for: pr) else {
            let panel = NSOpenPanel()
            panel.title = "Locate Local Repository for \(pr.repoFullName)"
            panel.prompt = "Select Folder"
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = false
            panel.allowsMultipleSelection = false
            if panel.runModal() == .OK, let url = panel.url {
                UserDefaults.standard.set(url.path, forKey: "localRepo_\(pr.repoFullName)")
                let fullPath = "\(url.path)/\(file.filename)"
                ExternalEditor.open(filePath: fullPath, line: line)
            }
            return
        }

        let fullPath = "\(repoPath)/\(file.filename)"
        ExternalEditor.open(filePath: fullPath, line: line)
    }

    // MARK: - Context Menus

    private func makeDiffContextMenu() -> NSMenu? {
        guard filteredFiles.indices.contains(selectedFileIndex) else { return nil }
        let file = filteredFiles[selectedFileIndex]
        let selRow = diffTable.selectedRow
        guard selRow >= 0 && selRow < tableRows.count else { return nil }

        let menu = NSMenu()
        let rowItem = tableRows[selRow]
        var lineNum: Int? = nil
        var lineText: String = ""

        switch rowItem {
        case .unified(let line):
            lineNum = line.newLineNumber ?? line.oldLineNumber
            lineText = line.text
        case .sideBySide(let sbs):
            lineNum = sbs.right.lineNumber ?? sbs.left.lineNumber
            lineText = sbs.right.text.isEmpty ? sbs.left.text : sbs.right.text
        case .reviewComment(let c):
            lineNum = c.fileAndLine?.line
            lineText = c.body
        }

        // 1. Copy GitHub Permalink
        if let pr = currentPR, let permalink = file.githubPermalink(repoFullName: pr.repoFullName, prNumber: pr.number, lineNumber: lineNum) {
            let item = NSMenuItem(title: lineNum != nil ? "Copy GitHub Permalink (Line \(lineNum!))" : "Copy GitHub Permalink", action: #selector(copyURLItemAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = permalink.absoluteString
            item.image = Self.symbol("link")
            menu.addItem(item)

            let openItem = NSMenuItem(title: "Open Line on GitHub", action: #selector(openURLItemAction(_:)), keyEquivalent: "")
            openItem.target = self
            openItem.representedObject = permalink
            openItem.image = Self.symbol("arrow.up.right.square")
            menu.addItem(openItem)
        }

        // 2. Open in Local IDE
        let ideItem = NSMenuItem(title: "Open in Local IDE (\(ExternalEditor.preferred.rawValue))", action: #selector(openInIDEClicked), keyEquivalent: "e")
        ideItem.target = self
        ideItem.image = Self.symbol("arrow.up.forward.app")
        menu.addItem(ideItem)

        menu.addItem(NSMenuItem.separator())

        // 3. Copy Relative File Path
        let pathItem = NSMenuItem(title: "Copy File Path", action: #selector(copyTextItemAction(_:)), keyEquivalent: "")
        pathItem.target = self
        pathItem.representedObject = file.filename
        pathItem.image = Self.symbol("doc.on.doc")
        menu.addItem(pathItem)

        // 4. Copy Line Content
        if !lineText.isEmpty {
            let textItem = NSMenuItem(title: "Copy Line Content", action: #selector(copyTextItemAction(_:)), keyEquivalent: "")
            textItem.target = self
            textItem.representedObject = lineText
            textItem.image = Self.symbol("doc.text")
            menu.addItem(textItem)
        }

        return menu
    }

    private func makeFileContextMenu() -> NSMenu? {
        let selRow = fileTable.selectedRow
        guard sidebarItems.indices.contains(selRow) else { return nil }
        guard case .file(let file, _) = sidebarItems[selRow] else { return nil }
        let menu = NSMenu()

        let pathItem = NSMenuItem(title: "Copy File Path", action: #selector(copyTextItemAction(_:)), keyEquivalent: "")
        pathItem.target = self
        pathItem.representedObject = file.filename
        pathItem.image = Self.symbol("doc.on.doc")
        menu.addItem(pathItem)

        if let pr = currentPR, let permalink = file.githubPermalink(repoFullName: pr.repoFullName, prNumber: pr.number) {
            let urlItem = NSMenuItem(title: "Copy GitHub Diff Link", action: #selector(copyURLItemAction(_:)), keyEquivalent: "")
            urlItem.target = self
            urlItem.representedObject = permalink.absoluteString
            urlItem.image = Self.symbol("link")
            menu.addItem(urlItem)
        }

        let ideItem = NSMenuItem(title: "Open in Local IDE", action: #selector(openInIDEClicked), keyEquivalent: "")
        ideItem.target = self
        ideItem.image = Self.symbol("arrow.up.forward.app")
        menu.addItem(ideItem)

        if let pr = currentPR {
            let checkoutItem = NSMenuItem(title: "Copy Git Checkout Command", action: #selector(copyCheckoutCommand), keyEquivalent: "")
            checkoutItem.target = self
            checkoutItem.representedObject = "git fetch origin pull/\(pr.number)/head:pr-\(pr.number) && git checkout pr-\(pr.number)"
            checkoutItem.image = Self.symbol("terminal")
            menu.addItem(checkoutItem)
        }

        menu.addItem(NSMenuItem.separator())

        let isViewed = viewedFilePaths.contains(file.filename)
        let toggleItem = NSMenuItem(title: isViewed ? "Mark as Unviewed" : "Mark as Viewed", action: #selector(toggleSelectedFileViewed), keyEquivalent: "")
        toggleItem.target = self
        toggleItem.image = Self.symbol(isViewed ? "circle" : "checkmark.circle.fill")
        menu.addItem(toggleItem)

        return menu
    }

    @objc private func copyCheckoutCommand(_ sender: NSMenuItem) {
        guard let str = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(str, forType: .string)
    }

    @objc private func copyURLItemAction(_ sender: NSMenuItem) {
        guard let str = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(str, forType: .string)
    }

    @objc private func openURLItemAction(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.openSafeWebURL(url)
    }

    @objc private func copyTextItemAction(_ sender: NSMenuItem) {
        guard let str = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(str, forType: .string)
    }

    @objc private func toggleSelectedFileViewed() {
        let selRow = fileTable.selectedRow
        guard sidebarItems.indices.contains(selRow) else { return }
        if case .file(let file, _) = sidebarItems[selRow] {
            toggleViewed(for: file)
        }
    }

    private func copyPermalinkForSelectedOrCurrent() {
        guard filteredFiles.indices.contains(selectedFileIndex), let pr = currentPR else { return }
        let file = filteredFiles[selectedFileIndex]
        let lineNum = currentSelectedLineNumber()
        if let permalink = file.githubPermalink(repoFullName: pr.repoFullName, prNumber: pr.number, lineNumber: lineNum) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(permalink.absoluteString, forType: .string)
        }
    }

    // MARK: - Keyboard Monitoring & Window Delegate

    func windowDidBecomeKey(_ notification: Notification) {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible else { return event }

            let isTyping = (self.window?.firstResponder as? NSTextView) != nil

            if event.modifierFlags.contains([.command, .shift]) {
                if event.charactersIgnoringModifiers == "r" || event.charactersIgnoringModifiers == "R" {
                    self.showSubmitReviewSheet(); return nil
                }
            } else if event.modifierFlags.contains(.command) {
                if event.charactersIgnoringModifiers == "1" {
                    self.viewMode = .sideBySide; return nil
                } else if event.charactersIgnoringModifiers == "2" {
                    self.viewMode = .inline; return nil
                } else if event.charactersIgnoringModifiers == "w" {
                    self.hide(); return nil
                } else if event.charactersIgnoringModifiers == "o" {
                    self.openOnGitHub(); return nil
                } else if event.charactersIgnoringModifiers == "f" {
                    self.toggleSearchBar(); return nil
                } else if event.charactersIgnoringModifiers == "e" {
                    self.openCurrentFileInLocalIDE(); return nil
                }
            } else if event.modifierFlags.contains(.option) {
                if event.keyCode == 125 { // Option+Down
                    self.jumpToNextHunk(); return nil
                } else if event.keyCode == 126 { // Option+Up
                    self.jumpToPrevHunk(); return nil
                } else if event.charactersIgnoringModifiers == "c" {
                    self.copyPermalinkForSelectedOrCurrent(); return nil
                }
            } else if !isTyping {
                if event.keyCode == 48 { // Tab
                    self.viewMode = self.viewMode == .sideBySide ? .inline : .sideBySide
                    return nil
                } else if event.charactersIgnoringModifiers == "j" {
                    self.jumpToNextHunk(); return nil
                } else if event.charactersIgnoringModifiers == "k" {
                    self.jumpToPrevHunk(); return nil
                } else if event.charactersIgnoringModifiers == "v" {
                    self.toggleViewedCurrentFile(); return nil
                } else if event.charactersIgnoringModifiers == "w" {
                    self.toggleIgnoreWhitespace(); return nil
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
            }
            return event
        }
    }

    func windowWillClose(_ notification: Notification) {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    // MARK: - NSTableViewDataSource & Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === fileTable {
            return sidebarItems.count
        } else {
            return tableRows.count
        }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if tableView === fileTable {
            guard sidebarItems.indices.contains(row) else { return 34 }
            switch sidebarItems[row] {
            case .folder: return 28
            case .file: return 34
            }
        }
        guard tableRows.indices.contains(row) else { return 20 }
        switch tableRows[row] {
        case .unified, .sideBySide:
            return 20
        case .reviewComment(let comment):
            let lines = max(1, comment.body.components(separatedBy: "\n").count)
            var h = CGFloat(42 + lines * 16)
            if activeReplyCommentIDs.contains(comment.id) {
                h += 68
            }
            return min(h, 240)
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === fileTable {
            guard sidebarItems.indices.contains(row) else { return nil }
            switch sidebarItems[row] {
            case .folder(_, let name, let count, let isExpanded, let depth):
                let cell = (tableView.makeView(withIdentifier: .init("folderCell"), owner: self) as? DiffFolderCellView)
                    ?? DiffFolderCellView(frame: .zero)
                cell.identifier = .init("folderCell")
                cell.configure(name: name, fileCount: count, isExpanded: isExpanded, depth: depth, palette: model.palette)
                return cell
            case .file(let file, let depth):
                let isViewed = viewedFilePaths.contains(file.filename)
                let cell = (tableView.makeView(withIdentifier: .init("fileCell"), owner: self) as? DiffFileCellView)
                    ?? DiffFileCellView(frame: .zero)
                cell.identifier = .init("fileCell")
                cell.configure(file: file, isViewed: isViewed, depth: depth, palette: model.palette) { [weak self] in
                    self?.toggleViewed(for: file)
                }
                return cell
            }
        } else {
            guard tableRows.indices.contains(row) else { return nil }
            switch tableRows[row] {
            case .unified(let line):
                let cell = (tableView.makeView(withIdentifier: .init("inlineCell"), owner: self) as? InlineDiffCellView)
                    ?? InlineDiffCellView(frame: .zero)
                cell.identifier = .init("inlineCell")
                cell.configure(line: line, searchQuery: currentSearchQuery, palette: model.palette)
                return cell
            case .sideBySide(let sbs):
                let cell = (tableView.makeView(withIdentifier: .init("sbsCell"), owner: self) as? SideBySideDiffCellView)
                    ?? SideBySideDiffCellView(frame: .zero)
                cell.identifier = .init("sbsCell")
                cell.configure(row: sbs, searchQuery: currentSearchQuery, palette: model.palette)
                return cell
            case .reviewComment(let comment):
                let cell = (tableView.makeView(withIdentifier: .init("commentCell"), owner: self) as? DiffCommentCellView)
                    ?? DiffCommentCellView(frame: .zero)
                cell.identifier = .init("commentCell")
                let isReplying = activeReplyCommentIDs.contains(comment.id)
                cell.configure(comment: comment, isReplying: isReplying, searchQuery: currentSearchQuery, palette: model.palette,
                               onToggleReply: { [weak self] active in
                    guard let self else { return }
                    if active {
                        self.activeReplyCommentIDs.insert(comment.id)
                    } else {
                        self.activeReplyCommentIDs.remove(comment.id)
                    }
                    self.diffTable.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
                }, onSendReply: { [weak self] replyText in
                    guard let self, let pr = self.currentPR else { return }
                    Task { @MainActor in
                        let err = await self.model.reply(to: comment, on: pr, body: replyText)
                        if err == nil {
                            self.activeReplyCommentIDs.remove(comment.id)
                            self.loadDiff(for: pr)
                        }
                    }
                })
                return cell
            }
        }
    }

    private func toggleViewed(for file: PullRequestFile) {
        if viewedFilePaths.contains(file.filename) {
            viewedFilePaths.remove(file.filename)
        } else {
            viewedFilePaths.insert(file.filename)
        }
        saveViewed()
        rebuildSidebarItems()
        updateViewedProgress()
    }

    // MARK: - Attributed Text Token & Keyword Helper

    private static let syntaxKeywords: Set<String> = [
        "func", "let", "var", "class", "struct", "enum", "actor", "protocol", "extension",
        "init", "deinit", "subscript", "typealias", "associatedtype",
        "import", "export", "return", "if", "else", "guard", "switch", "case", "default",
        "for", "while", "repeat", "break", "continue", "fallthrough",
        "do", "try", "catch", "throw", "throws", "rethrows", "defer",
        "async", "await", "public", "private", "fileprivate", "internal", "open", "static",
        "mutating", "nonisolated", "override", "final", "self", "Self", "super",
        "true", "false", "nil", "null", "undefined",
        "def", "lambda", "elif", "except", "finally", "with", "as", "from", "pass", "yield",
        "const", "function", "interface", "declare", "module", "namespace"
    ]

    static func makeAttributedText(
        tokens: [DiffToken]?,
        plainText: String,
        isAddition: Bool,
        isDeletion: Bool,
        searchQuery: String? = nil,
        palette: Palette?
    ) -> NSAttributedString {
        let baseFont = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        let textColor = palette?.text ?? .labelColor
        let keywordColor = palette?.mauve ?? NSColor(red: 0.72, green: 0.45, blue: 0.85, alpha: 1.0)

        let result = NSMutableAttributedString()

        let highlightBg: NSColor
        if isAddition {
            highlightBg = (palette?.green ?? .systemGreen).withAlphaComponent(0.35)
        } else if isDeletion {
            highlightBg = (palette?.red ?? .systemRed).withAlphaComponent(0.35)
        } else {
            highlightBg = .clear
        }

        if let tokens, !tokens.isEmpty {
            for token in tokens {
                var attrs: [NSAttributedString.Key: Any] = [
                    .font: token.isChanged ? NSFont.monospacedSystemFont(ofSize: 11.5, weight: .bold) : baseFont,
                    .foregroundColor: textColor
                ]
                if token.isChanged {
                    attrs[.backgroundColor] = highlightBg
                } else if syntaxKeywords.contains(token.text) {
                    attrs[.foregroundColor] = keywordColor
                }
                result.append(NSAttributedString(string: token.text, attributes: attrs))
            }
        } else {
            result.append(NSAttributedString(string: plainText, attributes: [
                .font: baseFont,
                .foregroundColor: textColor
            ]))
        }

        // Apply search query highlight if present
        if let query = searchQuery, !query.isEmpty {
            let fullText = result.string as NSString
            var searchRange = NSRange(location: 0, length: fullText.length)
            while searchRange.location < fullText.length {
                let foundRange = fullText.range(of: query, options: .caseInsensitive, range: searchRange)
                if foundRange.location != NSNotFound {
                    result.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.4), range: foundRange)
                    result.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: foundRange)
                    result.addAttribute(.underlineColor, value: NSColor.systemOrange, range: foundRange)
                    let nextLoc = foundRange.location + foundRange.length
                    searchRange = NSRange(location: nextLoc, length: fullText.length - nextLoc)
                } else {
                    break
                }
            }
        }

        return result
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

    static func symbol(_ name: String) -> NSImage {
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()
        img.isTemplate = true
        return img
    }
}

// MARK: - External Editor Helper

enum ExternalEditor: String, CaseIterable {
    case vscode = "Visual Studio Code"
    case cursor = "Cursor"
    case xcode = "Xcode"
    case sublime = "Sublime Text"

    var bundleID: String {
        switch self {
        case .vscode: return "com.microsoft.VSCode"
        case .cursor: return "com.todesktop.230313mzl4w4u92"
        case .xcode: return "com.apple.dt.Xcode"
        case .sublime: return "com.sublimetext.4"
        }
    }

    var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    static var preferred: ExternalEditor {
        if let saved = UserDefaults.standard.string(forKey: "preferredExternalEditor"),
           let ed = ExternalEditor(rawValue: saved), ed.isInstalled {
            return ed
        }
        return ExternalEditor.allCases.first(where: \.isInstalled) ?? .vscode
    }

    static func open(filePath: String, line: Int?) {
        let editor = preferred
        let lineNum = line ?? 1

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        switch editor {
        case .vscode:
            task.arguments = ["code", "-g", "\(filePath):\(lineNum)"]
        case .cursor:
            task.arguments = ["cursor", "-g", "\(filePath):\(lineNum)"]
        case .xcode:
            task.arguments = ["xed", "-line", "\(lineNum)", filePath]
        case .sublime:
            task.arguments = ["subl", "\(filePath):\(lineNum)"]
        }

        do {
            try task.run()
        } catch {
            NSWorkspace.shared.open(URL(fileURLWithPath: filePath))
        }
    }
}

// MARK: - Review Submission Modal Sheet

@MainActor
final class ReviewSubmissionSheet: NSWindowController {
    private let verdictControl = NSSegmentedControl()
    private let summaryTextView = NSTextView()
    private let submitButton = NSButton()
    private let cancelButton = NSButton()
    private let errorLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()

    var onSubmit: ((ReviewVerdictEvent, String?) async -> String?)?

    init(pr: PullRequest, palette: Palette?) {
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
                             styleMask: [.titled, .closable],
                             backing: .buffered, defer: false)
        sheet.title = "Submit Review — \(pr.repoFullName)#\(pr.number)"
        super.init(window: sheet)
        setupUI(pr: pr, palette: palette)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupUI(pr: PullRequest, palette: Palette?) {
        guard let window = self.window else { return }
        let content = NSView()
        window.contentView = content

        let titleLabel = NSTextField(labelWithString: "Submit Review for \(pr.repoFullName)#\(pr.number)")
        titleLabel.font = .systemFont(ofSize: 13, weight: .bold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        verdictControl.segmentCount = 3
        verdictControl.setLabel("✓ Approve", forSegment: 0)
        verdictControl.setLabel("💬 Comment", forSegment: 1)
        verdictControl.setLabel("✕ Request Changes", forSegment: 2)
        verdictControl.selectedSegment = 0
        verdictControl.target = self
        verdictControl.action = #selector(verdictChanged)
        verdictControl.translatesAutoresizingMaskIntoConstraints = false

        summaryTextView.font = .systemFont(ofSize: 12)
        summaryTextView.isRichText = false
        summaryTextView.allowsUndo = true

        let scroll = NSScrollView()
        scroll.documentView = summaryTextView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        errorLabel.translatesAutoresizingMaskIntoConstraints = false

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        cancelButton.title = "Cancel"
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        submitButton.title = "Approve PR"
        submitButton.bezelStyle = .rounded
        submitButton.keyEquivalent = "\r"
        submitButton.keyEquivalentModifierMask = .command
        submitButton.target = self
        submitButton.action = #selector(submitClicked)
        submitButton.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(titleLabel)
        content.addSubview(verdictControl)
        content.addSubview(scroll)
        content.addSubview(errorLabel)
        content.addSubview(spinner)
        content.addSubview(cancelButton)
        content.addSubview(submitButton)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),

            verdictControl.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            verdictControl.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            verdictControl.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            verdictControl.heightAnchor.constraint(equalToConstant: 28),

            scroll.topAnchor.constraint(equalTo: verdictControl.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            scroll.bottomAnchor.constraint(equalTo: submitButton.topAnchor, constant: -16),

            errorLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            errorLabel.centerYAnchor.constraint(equalTo: submitButton.centerYAnchor),
            errorLabel.trailingAnchor.constraint(lessThanOrEqualTo: spinner.leadingAnchor, constant: -8),

            spinner.trailingAnchor.constraint(equalTo: cancelButton.leadingAnchor, constant: -8),
            spinner.centerYAnchor.constraint(equalTo: submitButton.centerYAnchor),

            cancelButton.trailingAnchor.constraint(equalTo: submitButton.leadingAnchor, constant: -8),
            cancelButton.centerYAnchor.constraint(equalTo: submitButton.centerYAnchor),

            submitButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            submitButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])

        updateSubmitStyle()
    }

    @objc private func verdictChanged() {
        updateSubmitStyle()
    }

    private func updateSubmitStyle() {
        switch verdictControl.selectedSegment {
        case 0:
            submitButton.title = "Approve PR (⌘↵)"
            submitButton.contentTintColor = .systemGreen
        case 1:
            submitButton.title = "Submit Comment (⌘↵)"
            submitButton.contentTintColor = .systemBlue
        case 2:
            submitButton.title = "Request Changes (⌘↵)"
            submitButton.contentTintColor = .systemRed
        default:
            break
        }
    }

    @objc private func cancelClicked() {
        window?.sheetParent?.endSheet(window!, returnCode: .cancel)
    }

    @objc private func submitClicked() {
        let verdict: ReviewVerdictEvent
        switch verdictControl.selectedSegment {
        case 0: verdict = .approve
        case 1: verdict = .comment
        case 2: verdict = .requestChanges
        default: verdict = .comment
        }

        let body = summaryTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if verdict == .requestChanges && body.isEmpty {
            errorLabel.stringValue = "Message required when requesting changes."
            return
        }

        errorLabel.stringValue = ""
        spinner.startAnimation(nil)
        submitButton.isEnabled = false
        cancelButton.isEnabled = false

        Task { @MainActor in
            let error = await onSubmit?(verdict, body.isEmpty ? nil : body)
            spinner.stopAnimation(nil)
            submitButton.isEnabled = true
            cancelButton.isEnabled = true

            if let error {
                errorLabel.stringValue = error
            } else {
                window?.sheetParent?.endSheet(window!, returnCode: .OK)
            }
        }
    }
}

// MARK: - In-Diff Search Bar View

private final class DiffSearchBarView: NSView, NSSearchFieldDelegate {
    let searchField = NSSearchField()
    let prevButton = NSButton()
    let nextButton = NSButton()
    let matchLabel = NSTextField(labelWithString: "")
    let closeButton = NSButton()

    var onQueryChanged: ((String) -> Void)?
    var onNext: (() -> Void)?
    var onPrev: (() -> Void)?
    var onClose: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.95).cgColor

        searchField.placeholderString = "Find in diff…"
        searchField.font = .systemFont(ofSize: 12)
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchFieldAction)
        searchField.translatesAutoresizingMaskIntoConstraints = false

        prevButton.image = NSImage(systemSymbolName: "chevron.up", accessibilityDescription: nil)
        prevButton.isBordered = false
        prevButton.toolTip = "Previous Match (⇧Enter)"
        prevButton.target = self
        prevButton.action = #selector(prevClicked)
        prevButton.translatesAutoresizingMaskIntoConstraints = false

        nextButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
        nextButton.isBordered = false
        nextButton.toolTip = "Next Match (Enter)"
        nextButton.target = self
        nextButton.action = #selector(nextClicked)
        nextButton.translatesAutoresizingMaskIntoConstraints = false

        matchLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        matchLabel.textColor = .secondaryLabelColor
        matchLabel.translatesAutoresizingMaskIntoConstraints = false

        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
        closeButton.isBordered = false
        closeButton.toolTip = "Close (Esc)"
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        let bottomBorder = NSBox()
        bottomBorder.boxType = .separator
        bottomBorder.translatesAutoresizingMaskIntoConstraints = false

        addSubview(searchField)
        addSubview(matchLabel)
        addSubview(prevButton)
        addSubview(nextButton)
        addSubview(closeButton)
        addSubview(bottomBorder)

        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            searchField.centerYAnchor.constraint(equalTo: centerYAnchor),
            searchField.widthAnchor.constraint(equalToConstant: 220),

            matchLabel.leadingAnchor.constraint(equalTo: searchField.trailingAnchor, constant: 8),
            matchLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            prevButton.leadingAnchor.constraint(equalTo: matchLabel.trailingAnchor, constant: 8),
            prevButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            prevButton.widthAnchor.constraint(equalToConstant: 20),
            prevButton.heightAnchor.constraint(equalToConstant: 20),

            nextButton.leadingAnchor.constraint(equalTo: prevButton.trailingAnchor, constant: 4),
            nextButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            nextButton.widthAnchor.constraint(equalToConstant: 20),
            nextButton.heightAnchor.constraint(equalToConstant: 20),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 18),
            closeButton.heightAnchor.constraint(equalToConstant: 18),

            bottomBorder.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomBorder.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomBorder.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottomBorder.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    func controlTextDidChange(_ obj: Notification) {
        onQueryChanged?(searchField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if NSEvent.modifierFlags.contains(.shift) {
                onPrev?()
            } else {
                onNext?()
            }
            return true
        } else if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            onClose?()
            return true
        }
        return false
    }

    @objc private func searchFieldAction() {
        if NSEvent.modifierFlags.contains(.shift) {
            onPrev?()
        } else {
            onNext?()
        }
    }

    @objc private func prevClicked() { onPrev?() }
    @objc private func nextClicked() { onNext?() }
    @objc private func closeClicked() { onClose?() }
}

// MARK: - Folder Row Cell View for Tree Sidebar

private final class DiffFolderCellView: NSTableCellView {
    private let chevronView = NSImageView()
    private let folderIcon = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let countBadge = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        chevronView.translatesAutoresizingMaskIntoConstraints = false
        chevronView.imageScaling = .scaleProportionallyDown

        folderIcon.translatesAutoresizingMaskIntoConstraints = false
        folderIcon.imageScaling = .scaleProportionallyDown

        nameLabel.font = .systemFont(ofSize: 11.5, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        countBadge.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        countBadge.textColor = .secondaryLabelColor
        countBadge.translatesAutoresizingMaskIntoConstraints = false

        addSubview(chevronView)
        addSubview(folderIcon)
        addSubview(nameLabel)
        addSubview(countBadge)

        NSLayoutConstraint.activate([
            chevronView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            chevronView.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevronView.widthAnchor.constraint(equalToConstant: 12),
            chevronView.heightAnchor.constraint(equalToConstant: 12),

            folderIcon.leadingAnchor.constraint(equalTo: chevronView.trailingAnchor, constant: 4),
            folderIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            folderIcon.widthAnchor.constraint(equalToConstant: 14),
            folderIcon.heightAnchor.constraint(equalToConstant: 14),

            nameLabel.leadingAnchor.constraint(equalTo: folderIcon.trailingAnchor, constant: 6),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: countBadge.leadingAnchor, constant: -4),

            countBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            countBadge.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(name: String, fileCount: Int, isExpanded: Bool, depth: Int, palette: Palette?) {
        chevronView.image = NSImage(systemSymbolName: isExpanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
        chevronView.contentTintColor = palette?.subtext ?? .secondaryLabelColor

        let folderImg = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(paletteColors: [palette?.yellow ?? .systemOrange]))
        folderIcon.image = folderImg

        nameLabel.stringValue = name
        nameLabel.textColor = palette?.text ?? .labelColor
        countBadge.stringValue = "\(fileCount)"
    }
}

// MARK: - File Row Cell View in Left Sidebar

private final class DiffFileCellView: NSTableCellView {
    private let checkButton = NSButton()
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let diffBadge = NSTextField(labelWithString: "")
    private var leadingConstraint: NSLayoutConstraint?
    private var onToggleViewed: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        checkButton.setButtonType(.toggle)
        checkButton.isBordered = false
        checkButton.image = NSImage(systemSymbolName: "circle", accessibilityDescription: nil)
        checkButton.alternateImage = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
        checkButton.target = self
        checkButton.action = #selector(checkClicked)
        checkButton.translatesAutoresizingMaskIntoConstraints = false

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown

        nameLabel.font = .systemFont(ofSize: 11.5, weight: .regular)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        diffBadge.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        diffBadge.translatesAutoresizingMaskIntoConstraints = false

        addSubview(checkButton)
        addSubview(iconView)
        addSubview(nameLabel)
        addSubview(diffBadge)

        let lead = checkButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6)
        self.leadingConstraint = lead

        NSLayoutConstraint.activate([
            lead,
            checkButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            checkButton.widthAnchor.constraint(equalToConstant: 16),
            checkButton.heightAnchor.constraint(equalToConstant: 16),

            iconView.leadingAnchor.constraint(equalTo: checkButton.trailingAnchor, constant: 4),
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

    @objc private func checkClicked() {
        onToggleViewed?()
    }

    func configure(file: PullRequestFile, isViewed: Bool, depth: Int = 0, palette: Palette?, onToggle: @escaping () -> Void) {
        self.onToggleViewed = onToggle
        checkButton.state = isViewed ? .on : .off
        checkButton.contentTintColor = isViewed ? (palette?.green ?? .systemGreen) : .secondaryLabelColor

        leadingConstraint?.constant = CGFloat(6 + depth * 14)

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

        let nameAttr = NSMutableAttributedString()
        if depth == 0 && !file.directoryPath.isEmpty {
            nameAttr.append(NSAttributedString(string: file.directoryPath, attributes: [
                .font: NSFont.systemFont(ofSize: 10.5, weight: .regular),
                .foregroundColor: isViewed ? (palette?.subtext ?? .tertiaryLabelColor) : .secondaryLabelColor
            ]))
        }
        nameAttr.append(NSAttributedString(string: file.baseFilename, attributes: [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
            .foregroundColor: isViewed ? (palette?.subtext ?? .secondaryLabelColor) : (palette?.text ?? .labelColor)
        ]))
        nameLabel.attributedStringValue = nameAttr

        if let rename = file.renameDescription {
            nameLabel.toolTip = rename
        } else {
            nameLabel.toolTip = file.filename
        }

        let badgeAttr = NSMutableAttributedString()
        if file.additions > 0 {
            badgeAttr.append(NSAttributedString(string: "+\(file.additions)", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: palette?.green ?? .systemGreen
            ]))
        }
        if file.deletions > 0 {
            if file.additions > 0 { badgeAttr.append(NSAttributedString(string: " ")) }
            badgeAttr.append(NSAttributedString(string: "-\(file.deletions)", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: palette?.red ?? .systemRed
            ]))
        }
        if file.additions == 0 && file.deletions == 0 {
            badgeAttr.append(NSAttributedString(string: "0", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
                .foregroundColor: palette?.subtext ?? .secondaryLabelColor
            ]))
        }
        diffBadge.attributedStringValue = badgeAttr
    }
}

/// Cell view for Inline (Unified) diff row with intra-line word delta highlighting
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

    func configure(line: UnifiedDiffLine, searchQuery: String? = nil, palette: Palette?) {
        oldNumLabel.stringValue = line.oldLineNumber.map(String.init) ?? ""
        newNumLabel.stringValue = line.newLineNumber.map(String.init) ?? ""

        codeLabel.attributedStringValue = DiffWindow.makeAttributedText(
            tokens: line.tokens,
            plainText: line.text,
            isAddition: line.kind == .addition,
            isDeletion: line.kind == .deletion,
            searchQuery: searchQuery,
            palette: palette
        )

        switch line.kind {
        case .addition:
            prefixLabel.stringValue = "+"
            prefixLabel.textColor = palette?.green ?? .systemGreen
            layer?.backgroundColor = (palette?.green ?? .systemGreen).withAlphaComponent(0.12).cgColor
        case .deletion:
            prefixLabel.stringValue = "-"
            prefixLabel.textColor = palette?.red ?? .systemRed
            layer?.backgroundColor = (palette?.red ?? .systemRed).withAlphaComponent(0.12).cgColor
        case .hunkHeader:
            prefixLabel.stringValue = "@@"
            prefixLabel.textColor = palette?.mauve ?? .systemPurple
            codeLabel.textColor = palette?.mauve ?? .systemPurple
            layer?.backgroundColor = (palette?.mauve ?? .systemPurple).withAlphaComponent(0.11).cgColor
        case .comment:
            prefixLabel.stringValue = "\\"
            prefixLabel.textColor = .secondaryLabelColor
            layer?.backgroundColor = NSColor.clear.cgColor
        case .context:
            prefixLabel.stringValue = ""
            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }
}

/// Cell view for Side-by-Side (Split) diff row with intra-line word delta highlighting
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

    func configure(row: SideBySideDiffRow, searchQuery: String? = nil, palette: Palette?) {
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
        leftCodeLabel.attributedStringValue = DiffWindow.makeAttributedText(
            tokens: row.left.tokens,
            plainText: row.left.text,
            isAddition: false,
            isDeletion: row.left.kind == .deletion,
            searchQuery: searchQuery,
            palette: palette
        )

        if row.left.kind == .deletion {
            leftBgView.layer?.backgroundColor = (palette?.red ?? .systemRed).withAlphaComponent(0.12).cgColor
        } else if row.left == .empty {
            leftBgView.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.04).cgColor
        } else {
            leftBgView.layer?.backgroundColor = NSColor.clear.cgColor
        }

        // Right side
        rightNumLabel.stringValue = row.right.lineNumber.map(String.init) ?? ""
        rightCodeLabel.attributedStringValue = DiffWindow.makeAttributedText(
            tokens: row.right.tokens,
            plainText: row.right.text,
            isAddition: row.right.kind == .addition,
            isDeletion: false,
            searchQuery: searchQuery,
            palette: palette
        )

        if row.right.kind == .addition {
            rightBgView.layer?.backgroundColor = (palette?.green ?? .systemGreen).withAlphaComponent(0.12).cgColor
        } else if row.right == .empty {
            rightBgView.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.04).cgColor
        } else {
            rightBgView.layer?.backgroundColor = NSColor.clear.cgColor
        }
    }
}

/// Cell view for inline review comments overlay on diff lines with interactive reply composer
private final class DiffCommentCellView: NSTableCellView {
    private let container = NSView()
    private let authorLabel = NSTextField(labelWithString: "")
    private let verdictBadge = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    private let replyButton = NSButton()
    private let openBtn = NSButton()

    // Interactive Reply Box
    private let replyContainer = NSView()
    private let replyField = NSTextField()
    private let sendReplyBtn = NSButton()
    private let cancelReplyBtn = NSButton()
    private let replySpinner = NSProgressIndicator()

    private var commentURL: URL?
    private var onToggleReplyHandler: ((Bool) -> Void)?
    private var onSendReplyHandler: ((String) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        container.wantsLayer = true
        container.layer?.cornerRadius = 8
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.separatorColor.cgColor
        container.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        container.translatesAutoresizingMaskIntoConstraints = false

        authorLabel.font = .systemFont(ofSize: 11.5, weight: .bold)
        authorLabel.translatesAutoresizingMaskIntoConstraints = false

        verdictBadge.font = .systemFont(ofSize: 9.5, weight: .semibold)
        verdictBadge.translatesAutoresizingMaskIntoConstraints = false

        bodyLabel.font = .systemFont(ofSize: 11.5, weight: .regular)
        bodyLabel.textColor = .labelColor
        bodyLabel.isSelectable = true
        bodyLabel.translatesAutoresizingMaskIntoConstraints = false

        replyButton.title = "Reply"
        replyButton.image = NSImage(systemSymbolName: "arrowshape.turn.up.left", accessibilityDescription: nil)
        replyButton.bezelStyle = .inline
        replyButton.font = .systemFont(ofSize: 10, weight: .medium)
        replyButton.target = self
        replyButton.action = #selector(replyClicked)
        replyButton.translatesAutoresizingMaskIntoConstraints = false

        openBtn.image = NSImage(systemSymbolName: "arrow.up.right.square", accessibilityDescription: nil) ?? NSImage()
        openBtn.isBordered = false
        openBtn.toolTip = "Open comment on GitHub"
        openBtn.target = self
        openBtn.action = #selector(openCommentURL)
        openBtn.translatesAutoresizingMaskIntoConstraints = false

        // Setup reply container
        replyContainer.translatesAutoresizingMaskIntoConstraints = false
        replyContainer.isHidden = true

        replyField.placeholderString = "Write a reply… (⌘Enter to send)"
        replyField.font = .systemFont(ofSize: 11.5)
        replyField.target = self
        replyField.action = #selector(sendReplyClicked)
        replyField.translatesAutoresizingMaskIntoConstraints = false

        sendReplyBtn.title = "Send"
        sendReplyBtn.bezelStyle = .rounded
        sendReplyBtn.font = .systemFont(ofSize: 10.5, weight: .semibold)
        sendReplyBtn.target = self
        sendReplyBtn.action = #selector(sendReplyClicked)
        sendReplyBtn.translatesAutoresizingMaskIntoConstraints = false

        cancelReplyBtn.title = "Cancel"
        cancelReplyBtn.bezelStyle = .inline
        cancelReplyBtn.font = .systemFont(ofSize: 10.5)
        cancelReplyBtn.target = self
        cancelReplyBtn.action = #selector(cancelReplyClicked)
        cancelReplyBtn.translatesAutoresizingMaskIntoConstraints = false

        replySpinner.style = .spinning
        replySpinner.controlSize = .small
        replySpinner.isDisplayedWhenStopped = false
        replySpinner.translatesAutoresizingMaskIntoConstraints = false

        replyContainer.addSubview(replyField)
        replyContainer.addSubview(sendReplyBtn)
        replyContainer.addSubview(cancelReplyBtn)
        replyContainer.addSubview(replySpinner)

        container.addSubview(authorLabel)
        container.addSubview(verdictBadge)
        container.addSubview(bodyLabel)
        container.addSubview(replyButton)
        container.addSubview(openBtn)
        container.addSubview(replyContainer)
        addSubview(container)

        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 48),
            container.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            container.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            container.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),

            authorLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            authorLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),

            verdictBadge.leadingAnchor.constraint(equalTo: authorLabel.trailingAnchor, constant: 8),
            verdictBadge.centerYAnchor.constraint(equalTo: authorLabel.centerYAnchor),

            replyButton.trailingAnchor.constraint(equalTo: openBtn.leadingAnchor, constant: -6),
            replyButton.centerYAnchor.constraint(equalTo: authorLabel.centerYAnchor),

            openBtn.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            openBtn.centerYAnchor.constraint(equalTo: authorLabel.centerYAnchor),
            openBtn.widthAnchor.constraint(equalToConstant: 16),
            openBtn.heightAnchor.constraint(equalToConstant: 16),

            bodyLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            bodyLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            bodyLabel.topAnchor.constraint(equalTo: authorLabel.bottomAnchor, constant: 4),

            replyContainer.topAnchor.constraint(equalTo: bodyLabel.bottomAnchor, constant: 6),
            replyContainer.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            replyContainer.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            replyContainer.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
            replyContainer.heightAnchor.constraint(equalToConstant: 28),

            replyField.leadingAnchor.constraint(equalTo: replyContainer.leadingAnchor),
            replyField.centerYAnchor.constraint(equalTo: replyContainer.centerYAnchor),
            replyField.trailingAnchor.constraint(equalTo: sendReplyBtn.leadingAnchor, constant: -6),

            sendReplyBtn.trailingAnchor.constraint(equalTo: cancelReplyBtn.leadingAnchor, constant: -4),
            sendReplyBtn.centerYAnchor.constraint(equalTo: replyContainer.centerYAnchor),

            cancelReplyBtn.trailingAnchor.constraint(equalTo: replySpinner.leadingAnchor, constant: -4),
            cancelReplyBtn.centerYAnchor.constraint(equalTo: replyContainer.centerYAnchor),

            replySpinner.trailingAnchor.constraint(equalTo: replyContainer.trailingAnchor),
            replySpinner.centerYAnchor.constraint(equalTo: replyContainer.centerYAnchor),
        ])
    }

    @objc private func openCommentURL() {
        if let url = commentURL {
            NSWorkspace.shared.openSafeWebURL(url)
        }
    }

    @objc private func replyClicked() {
        let willOpen = replyContainer.isHidden
        replyContainer.isHidden = !willOpen
        onToggleReplyHandler?(willOpen)
        if willOpen {
            window?.makeFirstResponder(replyField)
        }
    }

    @objc private func cancelReplyClicked() {
        replyContainer.isHidden = true
        replyField.stringValue = ""
        onToggleReplyHandler?(false)
    }

    @objc private func sendReplyClicked() {
        let text = replyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        replySpinner.startAnimation(nil)
        sendReplyBtn.isEnabled = false
        onSendReplyHandler?(text)
    }

    func configure(
        comment: ReviewComment,
        isReplying: Bool,
        searchQuery: String? = nil,
        palette: Palette?,
        onToggleReply: @escaping (Bool) -> Void,
        onSendReply: @escaping (String) -> Void
    ) {
        self.commentURL = comment.htmlURL
        self.onToggleReplyHandler = onToggleReply
        self.onSendReplyHandler = onSendReply

        authorLabel.stringValue = "@\(comment.author)"
        authorLabel.textColor = palette?.text ?? .labelColor

        switch comment.verdict {
        case .changesRequested:
            verdictBadge.stringValue = "CHANGES REQUESTED"
            verdictBadge.textColor = palette?.red ?? .systemRed
        case .approved:
            verdictBadge.stringValue = "APPROVED"
            verdictBadge.textColor = palette?.green ?? .systemGreen
        case .commented:
            verdictBadge.stringValue = "COMMENT"
            verdictBadge.textColor = palette?.blue ?? .systemBlue
        }

        let bodyAttr = NSMutableAttributedString(string: comment.body, attributes: [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .regular),
            .foregroundColor: palette?.text ?? NSColor.labelColor
        ])
        if let query = searchQuery, !query.isEmpty {
            let full = comment.body as NSString
            var range = NSRange(location: 0, length: full.length)
            while range.location < full.length {
                let found = full.range(of: query, options: .caseInsensitive, range: range)
                if found.location != NSNotFound {
                    bodyAttr.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.4), range: found)
                    let next = found.location + found.length
                    range = NSRange(location: next, length: full.length - next)
                } else {
                    break
                }
            }
        }
        bodyLabel.attributedStringValue = bodyAttr

        replyContainer.isHidden = !isReplying
        sendReplyBtn.isEnabled = true
        replySpinner.stopAnimation(nil)
    }
}
