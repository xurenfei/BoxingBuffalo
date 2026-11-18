import AppKit
import Combine
import Quartz
import FatXCore

/// Main browser pane: breadcrumb path bar, file table, status bar.
final class BrowserViewController: NSViewController {

    private let model: AppModel
    private var cancellables = Set<AnyCancellable>()

    private let pathBar = NSStackView()
    private let pathScroll = NSScrollView()
    private let tableView = NSTableView()
    private let tableScroll = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let geometryLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let writeBar = NSProgressIndicator()
    private let writeDetail = NSTextField(labelWithString: "")
    private var lastWriteSample: (date: Date, bytes: Int64)?
    private var writeSpeed: Double = 0          // bytes/second, smoothed
    // The status label's right edge has to move left while an upload is in
    // progress, otherwise the progress text can sit on top of the file name.
    private var statusTrailingToGeometry: NSLayoutConstraint!
    private var statusTrailingToWriteDetail: NSLayoutConstraint!
    private let cancelButton = NSButton(frame: .zero)
    private var writeBarTrailingToEdge: NSLayoutConstraint!
    private var writeBarTrailingToCancel: NSLayoutConstraint!

    private var rows: [FatXEntry] = []
    private var suppressSelectionCallback = false

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Layout

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true

        // --- Path bar ---
        pathBar.orientation = .horizontal
        pathBar.spacing = 3
        pathBar.alignment = .centerY
        pathBar.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        pathBar.translatesAutoresizingMaskIntoConstraints = false

        pathScroll.documentView = pathBar
        pathScroll.hasHorizontalScroller = false
        pathScroll.hasVerticalScroller = false
        pathScroll.drawsBackground = false
        pathScroll.translatesAutoresizingMaskIntoConstraints = false
        pathScroll.heightAnchor.constraint(equalToConstant: 30).isActive = true

        // --- Table ---
        configureTable()
        tableScroll.documentView = tableView
        tableScroll.hasVerticalScroller = true
        tableScroll.autohidesScrollers = true
        tableScroll.drawsBackground = true
        tableScroll.backgroundColor = .textBackgroundColor
        tableScroll.translatesAutoresizingMaskIntoConstraints = false

        // --- Status bar ---
        statusLabel.font = .systemFont(ofSize: 10)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        geometryLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        geometryLabel.textColor = .tertiaryLabelColor
        geometryLabel.alignment = .right
        geometryLabel.translatesAutoresizingMaskIntoConstraints = false

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        // Deterministic bar for uploads; indeterminate spinner for the short
        // metadata operations (new folder / delete / rename).
        writeBar.style = .bar
        writeBar.isIndeterminate = false
        writeBar.minValue = 0
        writeBar.maxValue = 100
        writeBar.doubleValue = 0
        writeBar.controlSize = .small
        writeBar.isHidden = true
        writeBar.translatesAutoresizingMaskIntoConstraints = false

        writeDetail.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        writeDetail.textColor = .secondaryLabelColor
        writeDetail.alignment = .right
        writeDetail.lineBreakMode = .byTruncatingTail
        writeDetail.isHidden = true
        writeDetail.translatesAutoresizingMaskIntoConstraints = false

        cancelButton.title = "取消"
        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .small
        cancelButton.font = .systemFont(ofSize: 10)
        cancelButton.target = self
        cancelButton.action = #selector(handleCancel)
        cancelButton.isHidden = true
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        let statusBar = NSView()
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        let statusSeparator = NSBox()
        statusSeparator.boxType = .separator
        statusSeparator.translatesAutoresizingMaskIntoConstraints = false
        statusBar.addSubview(statusSeparator)
        statusBar.addSubview(statusLabel)
        statusBar.addSubview(geometryLabel)
        statusBar.addSubview(spinner)
        statusBar.addSubview(writeBar)
        statusBar.addSubview(writeDetail)
        statusBar.addSubview(cancelButton)

        // --- Empty state ---
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.maximumNumberOfLines = 3
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = true

        let pathSeparator = NSBox()
        pathSeparator.boxType = .separator
        pathSeparator.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(pathScroll)
        container.addSubview(pathSeparator)
        container.addSubview(tableScroll)
        container.addSubview(emptyLabel)
        container.addSubview(statusBar)

        statusTrailingToGeometry = statusLabel.trailingAnchor
            .constraint(lessThanOrEqualTo: geometryLabel.leadingAnchor, constant: -8)
        statusTrailingToWriteDetail = statusLabel.trailingAnchor
            .constraint(lessThanOrEqualTo: writeDetail.leadingAnchor, constant: -8)
        writeBarTrailingToEdge = writeBar.trailingAnchor
            .constraint(equalTo: statusBar.trailingAnchor, constant: -12)
        writeBarTrailingToCancel = writeBar.trailingAnchor
            .constraint(equalTo: cancelButton.leadingAnchor, constant: -8)

        NSLayoutConstraint.activate([
            pathScroll.topAnchor.constraint(equalTo: container.topAnchor),
            pathScroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            pathScroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            pathSeparator.topAnchor.constraint(equalTo: pathScroll.bottomAnchor),
            pathSeparator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            pathSeparator.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            tableScroll.topAnchor.constraint(equalTo: pathSeparator.bottomAnchor),
            tableScroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tableScroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tableScroll.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: tableScroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: tableScroll.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 340),

            statusBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 26),

            statusSeparator.topAnchor.constraint(equalTo: statusBar.topAnchor),
            statusSeparator.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor),
            statusSeparator.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor),

            statusLabel.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 12),
            statusLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor, constant: 1),
            statusTrailingToGeometry,

            spinner.trailingAnchor.constraint(equalTo: geometryLabel.leadingAnchor, constant: -8),
            spinner.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),

            geometryLabel.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor, constant: -12),
            geometryLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor, constant: 1),

            writeBarTrailingToEdge,
            writeBar.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            writeBar.widthAnchor.constraint(equalToConstant: 150),

            writeDetail.trailingAnchor.constraint(equalTo: writeBar.leadingAnchor, constant: -8),
            writeDetail.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor, constant: 1),
            writeDetail.widthAnchor.constraint(lessThanOrEqualToConstant: 300),

            cancelButton.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor, constant: -12),
            cancelButton.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
        ])

        view = container
    }

    private func configureTable() {
        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameColumn.title = "名称"
        nameColumn.width = 340
        nameColumn.minWidth = 140
        nameColumn.sortDescriptorPrototype = NSSortDescriptor(key: "name", ascending: true)
        tableView.addTableColumn(nameColumn)

        let sizeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))
        sizeColumn.title = "大小"
        sizeColumn.width = 92
        sizeColumn.sortDescriptorPrototype = NSSortDescriptor(key: "size", ascending: true)
        tableView.addTableColumn(sizeColumn)

        let dateColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("modified"))
        dateColumn.title = "修改时间"
        dateColumn.width = 136
        dateColumn.sortDescriptorPrototype = NSSortDescriptor(key: "modified", ascending: true)
        tableView.addTableColumn(dateColumn)

        // Finder-style: no zebra bands. NSTableView paints them across the whole
        // empty area too, which reads as phantom rows under the list.
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.rowSizeStyle = .default
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = false
        tableView.allowsColumnResizing = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(handleDoubleClick)
        tableView.registerForDraggedTypes([.fileURL])
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)
        tableView.setDraggingSourceOperationMask(.copy, forLocal: true)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        bind()
    }

    // MARK: - Binding

    private func bind() {
        model.$entries
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reloadTable() }
            .store(in: &cancellables)

        model.$searchText
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reloadTable() }
            .store(in: &cancellables)

        model.$showDeletedEntries
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reloadTable() }
            .store(in: &cancellables)

        model.$selectedVolumeID
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildPathBar() }
            .store(in: &cancellables)

        model.$path
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildPathBar() }
            .store(in: &cancellables)

        model.$statusMessage
            .receive(on: RunLoop.main)
            .sink { [weak self] message in self?.statusLabel.stringValue = message }
            .store(in: &cancellables)

        model.$volumes
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateGeometryLabel() }
            .store(in: &cancellables)

        model.$isLoadingEntries
            .receive(on: RunLoop.main)
            .sink { [weak self] loading in
                guard let self else { return }
                if loading { self.spinner.startAnimation(nil) } else { self.spinner.stopAnimation(nil) }
            }
            .store(in: &cancellables)

        model.$isWriting
            .receive(on: RunLoop.main)
            .sink { [weak self] writing in self?.setWritingVisible(writing) }
            .store(in: &cancellables)

        model.$writeLabel
            .receive(on: RunLoop.main)
            .sink { [weak self] label in
                guard let self, self.model.isWriting else { return }
                self.statusLabel.stringValue = label
            }
            .store(in: &cancellables)

        model.$writeProgress
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateWriteProgress() }
            .store(in: &cancellables)

        model.$writeBytes
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateWriteProgress() }
            .store(in: &cancellables)

        model.$writeIsCancellable
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateCancelVisibility() }
            .store(in: &cancellables)

        rebuildPathBar()
    }

    // MARK: - Write progress

    private func setWritingVisible(_ writing: Bool) {
        // Keep the file name clear of the progress readout on narrow windows.
        if writing {
            statusTrailingToGeometry.isActive = false
            statusTrailingToWriteDetail.isActive = true
        } else {
            statusTrailingToWriteDetail.isActive = false
            statusTrailingToGeometry.isActive = true
        }
        writeBar.isHidden = !writing
        writeDetail.isHidden = !writing
        geometryLabel.isHidden = writing
        spinner.isHidden = writing
        if writing {
            cancelButton.title = "取消"
            spinner.stopAnimation(nil)
            geometryLabel.stringValue = ""
            statusLabel.stringValue = model.writeLabel
            lastWriteSample = nil
            writeSpeed = 0
            writeBar.doubleValue = 0
            writeBar.isIndeterminate = true
            writeBar.startAnimation(nil)
            writeDetail.stringValue = "准备中…"
        } else {
            writeBar.stopAnimation(nil)
            writeBar.isIndeterminate = false
            statusLabel.stringValue = model.statusMessage
            updateGeometryLabel()
            if model.isLoadingEntries { spinner.startAnimation(nil) }
        }
        updateCancelVisibility()
    }

    private func updateCancelVisibility() {
        let show = model.isWriting && model.writeIsCancellable
        cancelButton.isHidden = !show
        cancelButton.isEnabled = show
        // Keep the bar hard against the right edge when no button is present.
        if show {
            writeBarTrailingToEdge.isActive = false
            writeBarTrailingToCancel.isActive = true
        } else {
            writeBarTrailingToCancel.isActive = false
            writeBarTrailingToEdge.isActive = true
        }
    }

    @objc private func handleCancel() {
        guard model.isWriting, model.writeIsCancellable else { return }
        cancelButton.isEnabled = false
        cancelButton.title = "取消中"
        model.cancelWrite()
    }

    private func updateWriteProgress() {
        guard model.isWriting else { return }
        let bytes = model.writeBytes
        guard bytes.total > 0 else {
            writeDetail.stringValue = model.writeLabel.isEmpty ? "处理中…" : model.writeLabel
            return
        }
        writeBar.stopAnimation(nil)
        writeBar.isIndeterminate = false
        writeBar.doubleValue = min(100, max(0, model.writeProgress * 100))
        trackSpeed(written: bytes.written)

        let pct = Int((model.writeProgress * 100).rounded())
        var text = "\(pct)% · \(FatXVolume.friendlySize(bytes.written)) / \(FatXVolume.friendlySize(bytes.total))"
        if writeSpeed > 0 {
            text += String(format: " · %.1f MB/s", writeSpeed / 1_048_576)
            let remaining = max(0, bytes.total - bytes.written)
            let seconds = Int64(Double(remaining) / max(1.0, writeSpeed))
            if seconds > 0 { text += " · 剩 \(shortDuration(seconds))" }
        }
        writeDetail.stringValue = text
    }

    private func trackSpeed(written: Int64) {
        let now = Date()
        if let last = lastWriteSample {
            let dt = now.timeIntervalSince(last.date)
            if dt >= 0.25, written >= last.bytes {
                let instant = Double(written - last.bytes) / dt
                writeSpeed = writeSpeed <= 0 ? instant : writeSpeed * 0.7 + instant * 0.3
                lastWriteSample = (now, written)
            }
        } else {
            lastWriteSample = (now, written)
        }
    }

    private func shortDuration(_ seconds: Int64) -> String {
        if seconds < 60 { return "\(seconds) 秒" }
        if seconds < 3600 { return "\(seconds / 60) 分 \(seconds % 60) 秒" }
        return "\(seconds / 3600) 小时 \((seconds % 3600) / 60) 分"
    }

    private func updateGeometryLabel() {
        guard let volume = model.selectedVolume else {
            geometryLabel.stringValue = ""
            return
        }
        geometryLabel.stringValue = String(
            format: "%@ · 簇 %d KB · %d 簇",
            volume.layout.rawValue,
            volume.volume.clusterSize / 1024,
            volume.volume.totalClusters
        )
    }

    // MARK: - Path bar

    private func rebuildPathBar() {
        pathBar.arrangedSubviews.forEach {
            pathBar.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        guard model.selectedVolume != nil else {
            let label = NSTextField(labelWithString: "未挂载分区")
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            pathBar.addArrangedSubview(label)
            return
        }

        let steps = model.breadcrumb
        for (index, step) in steps.enumerated() {
            if index > 0 {
                let chevron = NSImageView()
                chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
                chevron.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 7, weight: .semibold)
                chevron.contentTintColor = .tertiaryLabelColor
                chevron.widthAnchor.constraint(equalToConstant: 8).isActive = true
                pathBar.addArrangedSubview(chevron)
            }

            let isLast = index == steps.count - 1
            let button = PathButton(title: step.name, isTerminal: isLast, isRoot: index == 0)
            button.target = self
            button.action = #selector(handlePathButton(_:))
            button.tag = index
            pathBar.addArrangedSubview(button)
        }

        updateGeometryLabel()
    }

    @objc private func handlePathButton(_ sender: NSButton) {
        let steps = model.breadcrumb
        guard sender.tag >= 0, sender.tag < steps.count else { return }
        let step = steps[sender.tag]
        if sender.tag == 0 {
            model.goToRoot()
        } else {
            model.jump(to: step)
        }
    }

    // MARK: - Table

    private func reloadTable() {
        rows = model.filteredEntries
        suppressSelectionCallback = true
        tableView.reloadData()
        suppressSelectionCallback = false

        // Restore selection by entry id where possible.
        let ids = model.selection
        var indexes = IndexSet()
        for (index, entry) in rows.enumerated() where ids.contains(entry.id) {
            indexes.insert(index)
        }
        tableView.selectRowIndexes(indexes, byExtendingSelection: false)

        let nothingMounted = model.selectedVolume == nil
        emptyLabel.isHidden = !rows.isEmpty || model.isLoadingEntries
        if nothingMounted {
            emptyLabel.stringValue = "没有挂载任何分区\n\n从左边选一个外接磁盘，或用「文件 › 打开镜像文件…」"
            emptyLabel.isHidden = false
        } else if rows.isEmpty && !model.isLoadingEntries {
            emptyLabel.stringValue = model.searchText.isEmpty
                ? "这个目录是空的"
                : "没有匹配「\(model.searchText)」的项目"
        }
    }

    @objc private func handleDoubleClick() {
        let row = tableView.clickedRow
        guard row >= 0, row < rows.count else { return }
        let entry = rows[row]
        if entry.isDirectory {
            model.enter(entry)
        } else {
            preview(entry)
        }
    }

    private func preview(_ entry: FatXEntry) {
        guard let url = model.writeTempFileForPreview(entry) else { return }
        QuickLookHelper.shared.present(url: url, from: view.window)
    }

    @objc private func handleContextExtract(_ sender: NSMenuItem) {
        extractSelection()
    }

    private func extractSelection() {
        let selection = model.selectedEntries
        let targets = selection.isEmpty ? rows : selection
        guard !targets.isEmpty else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "提取到这里"
        panel.message = "把 \(targets.count) 个项目提取到哪个文件夹"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.extract(entries: targets, to: url)
    }

    // MARK: - Writing

    /// Rows the user actually has selected. `model.selectedEntries` goes
    /// through the filtered list, which can be empty right after a sort or a
    /// filter change even though rows are highlighted.
    private var highlightedEntries: [FatXEntry] {
        tableView.selectedRowIndexes.compactMap { $0 < rows.count ? rows[$0] : nil }
            .filter { !$0.isDeleted }
    }

    private var destinationDescription: String {
        model.breadcrumb.map(\.name).joined(separator: " / ")
    }

    func uploadFiles() {
        guard model.selectedVolume != nil else {
            model.errorMessage = "先选一个分区，再上传文件。"
            return
        }
        guard model.canWrite else {
            promptUnlockWrite()
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "上传"
        panel.message = "可以混选文件和文件夹；文件夹会按原结构递归写入 \(destinationDescription)"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        confirmUpload(urls: panel.urls)
    }

    /// Writes always go through an explicit confirmation that names the target
    /// directory, the byte count and any file that has to be renamed or skipped
    /// because FATX cannot store non-ASCII names or >4 GB files. Folders are
    /// listed as a single line with their recursive totals.
    private func confirmUpload(urls: [URL]) {
        let plan: UploadPlan
        do {
            plan = try FolderUploadPlanner.plan(urls: urls)
        } catch {
            model.errorMessage = "整理上传清单失败：\((error as? LocalizedError)?.errorDescription ?? "\(error)")"
            return
        }
        guard plan.fileCount > 0 || plan.folderCount > 0 else {
            model.errorMessage = "选中的项目没有可写入的内容（全部被跳过）。"
            return
        }
        let isRawDevice = model.selectedVolume?.source.isRawDevice ?? false

        var lines: [String] = []
        for node in plan.roots.prefix(8) {
            var line: String
            if node.isDirectory {
                line = "[目录] \(node.remoteName)/  \(node.fileCount) 个文件 · \(node.folderCount - 1) 个子目录 · \(FatXVolume.friendlySize(node.totalBytes))"
            } else {
                line = "• \(node.remoteName)  \(FatXVolume.friendlySize(node.totalBytes))"
            }
            if node.remoteName != node.localName { line += "  ← \(node.localName)（改名）" }
            lines.append(line)
        }
        if plan.roots.count > 8 { lines.append("• …另外 \(plan.roots.count - 8) 项") }
        if !plan.warnings.isEmpty {
            lines.append("")
            lines.append("注意：")
            for warning in plan.warnings.prefix(5) { lines.append("• \(warning)") }
            if plan.warnings.count > 5 { lines.append("• …另外 \(plan.warnings.count - 5) 条提示") }
        }

        let what = plan.folderCount > 0
            ? "\(plan.fileCount) 个文件 / \(plan.folderCount) 个文件夹"
            : "\(plan.fileCount) 个文件"
        let alert = NSAlert()
        alert.messageText = "写入\(what)到「\(destinationDescription)」？"
        alert.informativeText = """
        \(lines.joined(separator: "\n"))

        合计 \(FatXVolume.friendlySize(plan.totalBytes))。文件夹按原结构递归创建；同名文件会被覆盖，同名目录会合并。
        """ + (isRawDevice ? "\n\n⚠️ 目标是真实 Xbox 硬盘，写入会直接修改 FAT 链与目录项，无法撤销。请确认盘上的存档已备份。" : "")
        alert.alertStyle = isRawDevice ? .critical : .warning
        alert.addButton(withTitle: "写入")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        model.upload(urls: urls)
    }

    func promptNewFolder() {
        guard model.canWrite else {
            promptUnlockWrite()
            return
        }
        let alert = NSAlert()
        alert.messageText = "在「\(destinationDescription)」新建文件夹"
        alert.informativeText = "FATX 只支持 ASCII 名称，最长 42 字节。"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "New Folder"
        alert.accessoryView = field
        alert.addButton(withTitle: "新建")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        model.createFolder(named: name)
    }

    func confirmAndDelete() {
        guard model.canWrite else {
            promptUnlockWrite()
            return
        }
        let targets = highlightedEntries
        guard !targets.isEmpty else { return }
        let isRawDevice = model.selectedVolume?.source.isRawDevice ?? false

        let alert = NSAlert()
        let what = targets.count == 1 ? "「\(targets[0].name)」" : "\(targets.count) 个项目"
        alert.messageText = "删除\(what)？"
        alert.informativeText = """
        目录里会把它们标记为已删除（0xE5）并释放占用的簇。Xbox 360 上会立即消失。
        """ + (isRawDevice ? "\n\n⚠️ 目标是真实 Xbox 硬盘，此操作无法撤销。" : "")
        alert.alertStyle = isRawDevice ? .critical : .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        model.delete(entries: targets)
    }

    private func promptRename(_ entry: FatXEntry) {
        guard model.canWrite else {
            promptUnlockWrite()
            return
        }
        let alert = NSAlert()
        alert.messageText = "重命名「\(entry.name)」"
        alert.informativeText = "FATX 只支持 ASCII 名称，最长 42 字节。"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = entry.name
        alert.accessoryView = field
        alert.addButton(withTitle: "重命名")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != entry.name else { return }
        model.rename(entry, to: name)
    }

    private func promptUnlockWrite() {
        let alert = NSAlert()
        alert.messageText = "这块盘当前是只读打开的"
        alert.informativeText = """
        写入需要设备节点的写权限。点「解锁写入」会请求一次管理员授权，只改 /dev/rdisk 的权限位，不碰盘上数据；随后会自动重新挂载。
        """
        alert.addButton(withTitle: "解锁写入")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        model.requestWritePermission()
    }

}

// MARK: - Table data source / delegate

extension BrowserViewController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first, let key = descriptor.key else { return }
        switch key {
        case "name": model.sortField = .name
        case "size": model.sortField = .size
        case "modified": model.sortField = .modified
        default: break
        }
        model.sortAscending = descriptor.ascending
        reloadTable()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelectionCallback else { return }
        let selected = tableView.selectedRowIndexes.compactMap { index -> String? in
            index < rows.count ? rows[index].id : nil
        }
        model.selection = Set(selected)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count, let tableColumn else { return nil }
        let entry = rows[row]

        switch tableColumn.identifier.rawValue {
        case "name":
            let cell = NSTableCellView()
            let icon = NSImageView()
            icon.image = NSImage(systemSymbolName: symbol(for: entry), accessibilityDescription: nil)
            icon.contentTintColor = tint(for: entry)
            icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
            icon.translatesAutoresizingMaskIntoConstraints = false

            let label = NSTextField(labelWithString: entry.name)
            label.font = .systemFont(ofSize: 12)
            label.lineBreakMode = .byTruncatingMiddle
            label.textColor = entry.isDeleted ? .secondaryLabelColor : .labelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            if entry.isDeleted {
                label.attributedStringValue = NSAttributedString(
                    string: entry.name,
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 12),
                        .foregroundColor: NSColor.secondaryLabelColor,
                        .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    ]
                )
            }

            cell.addSubview(icon)
            cell.addSubview(label)
            cell.imageView = icon
            cell.textField = label

            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 15),
                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell

        case "size":
            let label = NSTextField(labelWithString: entry.isDirectory ? "—" : FatXVolume.friendlySize(Int64(entry.size)))
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            label.textColor = .secondaryLabelColor
            label.alignment = .right
            label.translatesAutoresizingMaskIntoConstraints = false
            let cell = NSTableCellView()
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                label.leadingAnchor.constraint(greaterThanOrEqualTo: cell.leadingAnchor),
            ])
            return cell

        case "modified":
            let label = NSTextField(labelWithString: dateString(entry))
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            label.textColor = .tertiaryLabelColor
            label.alignment = .right
            label.translatesAutoresizingMaskIntoConstraints = false
            let cell = NSTableCellView()
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                label.leadingAnchor.constraint(greaterThanOrEqualTo: cell.leadingAnchor),
            ])
            return cell

        default:
            return nil
        }
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard row < rows.count else { return nil }
        let entry = rows[row]
        guard !entry.isDirectory, entry.size < 32 << 20 else { return nil }
        guard let url = model.writeTempFileForPreview(entry) else { return nil }
        return url as NSURL
    }

    // MARK: Drop target

    func tableView(_ tableView: NSTableView,
                   validateDrop info: any NSDraggingInfo,
                   proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        // Files dragged out of this very table are extraction, not an upload.
        if let source = info.draggingSource as? NSTableView, source === tableView { return [] }
        guard model.canWrite else { return [] }
        guard info.draggingPasteboard.canReadObject(forClasses: [NSURL.self],
                                                    options: [.urlReadingFileURLsOnly: true]) == true else {
            return []
        }
        // Dropping onto a folder row means "put it inside that folder".
        if dropOperation == .on, row >= 0, row < rows.count, rows[row].isDirectory {
            return .copy
        }
        tableView.setDropRow(-1, dropOperation: .on)
        return .copy
    }

    func tableView(_ tableView: NSTableView,
                   acceptDrop info: any NSDraggingInfo,
                   row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                             options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }

        if dropOperation == .on, row >= 0, row < rows.count, rows[row].isDirectory {
            // Browse into the folder first so the confirmation names the right
            // destination, then upload there.
            let folder = rows[row]
            model.enter(folder)
            DispatchQueue.main.async { [weak self] in
                self?.confirmUpload(urls: urls)
            }
            return true
        }
        confirmUpload(urls: urls)
        return true
    }

    // MARK: Cell helpers

    private func symbol(for entry: FatXEntry) -> String {
        if entry.isDirectory { return "folder.fill" }
        switch (entry.name as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "bmp", "tga", "dds": return "photo.fill"
        case "sav", "gpd": return "gamecontroller.fill"
        case "bin", "dat", "pak", "xex", "xzp": return "shippingbox.fill"
        case "txt", "ini", "cfg", "xml", "json": return "doc.text.fill"
        case "ttf", "otf": return "character.cursor.ibeam"
        default: return "doc.fill"
        }
    }

    private func tint(for entry: FatXEntry) -> NSColor {
        if entry.isDirectory { return .controlAccentColor }
        switch (entry.name as NSString).pathExtension.lowercased() {
        case "sav", "gpd": return .systemGreen
        case "jpg", "jpeg", "png", "bmp", "tga", "dds": return .systemPurple
        case "xex", "xzp", "bin": return .systemOrange
        default: return .secondaryLabelColor
        }
    }

    private func dateString(_ entry: FatXEntry) -> String {
        guard let date = entry.modified ?? entry.created else { return "—" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

// MARK: - Context menu

extension BrowserViewController: NSMenuDelegate {
    override func rightMouseDown(with event: NSEvent) {
        let point = tableView.convert(event.locationInWindow, from: nil)
        let row = tableView.row(at: point)
        if row >= 0 {
            if !tableView.selectedRowIndexes.contains(row) {
                tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
            let menu = buildContextMenu(forRow: row)
            NSMenu.popUpContextMenu(menu, with: event, for: tableView)
        } else if model.canWrite {
            // Empty area: the useful actions are the ones that create things.
            NSMenu.popUpContextMenu(buildEmptyAreaMenu(), with: event, for: tableView)
        } else {
            super.rightMouseDown(with: event)
        }
    }

    private func buildEmptyAreaMenu() -> NSMenu {
        let menu = NSMenu()
        let upload = NSMenuItem(title: "上传文件到此处…",
                                action: #selector(handleUploadHere(_:)),
                                keyEquivalent: "")
        upload.target = self
        menu.addItem(upload)
        let folder = NSMenuItem(title: "新建文件夹…",
                                action: #selector(handleNewFolder(_:)),
                                keyEquivalent: "")
        folder.target = self
        menu.addItem(folder)
        return menu
    }

    private func buildContextMenu(forRow row: Int) -> NSMenu {
        let menu = NSMenu()
        let entry = rows[row]
        let targets = model.selectedEntries.isEmpty ? [entry] : model.selectedEntries

        let extractTitle = targets.count > 1 ? "提取 \(targets.count) 项到…" : "提取到…"
        let extractItem = NSMenuItem(title: extractTitle, action: #selector(handleContextExtract(_:)), keyEquivalent: "")
        extractItem.target = self
        menu.addItem(extractItem)

        if entry.isDirectory, targets.count == 1 {
            let enterItem = NSMenuItem(title: "进入目录", action: #selector(handleEnterFromMenu(_:)), keyEquivalent: "")
            enterItem.target = self
            menu.addItem(enterItem)
        } else if !entry.isDirectory, targets.count == 1 {
            let previewItem = NSMenuItem(title: "快速查看", action: #selector(handlePreviewFromMenu(_:)), keyEquivalent: "")
            previewItem.target = self
            menu.addItem(previewItem)
        }

        if model.canWrite {
            menu.addItem(.separator())
            if targets.count == 1, !entry.isDeleted {
                let renameItem = NSMenuItem(title: "重命名…",
                                            action: #selector(handleRename(_:)),
                                            keyEquivalent: "")
                renameItem.target = self
                menu.addItem(renameItem)
            }
            let deleteTitle = targets.count > 1 ? "删除 \(targets.count) 项" : "删除"
            let deleteItem = NSMenuItem(title: deleteTitle,
                                        action: #selector(handleDelete(_:)),
                                        keyEquivalent: "")
            deleteItem.target = self
            menu.addItem(deleteItem)
        }

        menu.addItem(.separator())

        let copyItem = NSMenuItem(title: "拷贝名称", action: #selector(handleCopyName(_:)), keyEquivalent: "")
        copyItem.target = self
        menu.addItem(copyItem)

        return menu
    }

    @objc private func handleUploadHere(_ sender: Any?) {
        uploadFiles()
    }

    @objc private func handleNewFolder(_ sender: Any?) {
        promptNewFolder()
    }

    @objc private func handleDelete(_ sender: Any?) {
        confirmAndDelete()
    }

    @objc private func handleRename(_ sender: Any?) {
        guard let entry = model.selectedEntries.first ?? rows.first(where: {
            tableView.selectedRow >= 0 && tableView.selectedRow < rows.count ? $0.id == rows[tableView.selectedRow].id : false
        }) else { return }
        promptRename(entry)
    }

    @objc private func handleEnterFromMenu(_ sender: NSMenuItem) {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard row >= 0, row < rows.count else { return }
        model.enter(rows[row])
    }

    @objc private func handlePreviewFromMenu(_ sender: NSMenuItem) {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard row >= 0, row < rows.count else { return }
        preview(rows[row])
    }

    @objc private func handleCopyName(_ sender: NSMenuItem) {
        let selection = model.selectedEntries
        let names = selection.isEmpty
            ? (tableView.selectedRow >= 0 && tableView.selectedRow < rows.count ? [rows[tableView.selectedRow].name] : [])
            : selection.map(\.name)
        guard !names.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(names.joined(separator: "\n"), forType: .string)
    }
}

// MARK: - Path button

final class PathButton: NSButton {
    private let isTerminal: Bool
    private let isRoot: Bool

    init(title: String, isTerminal: Bool, isRoot: Bool) {
        self.isTerminal = isTerminal
        self.isRoot = isRoot
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .inline
        isBordered = false
        font = .systemFont(ofSize: 12, weight: isTerminal ? .semibold : .regular)
        contentTintColor = isTerminal ? .labelColor : .secondaryLabelColor
        if isRoot {
            image = NSImage(systemSymbolName: "internaldrive", accessibilityDescription: nil)
            imagePosition = .imageLeading
        }
        setButtonType(.momentaryChange)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width += 4
        return size
    }
}

// MARK: - Quick Look

final class QuickLookHelper: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookHelper()
    private var url: URL?

    func present(url: URL, from window: NSWindow?) {
        self.url = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        url == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        url as NSURL?
    }
}
