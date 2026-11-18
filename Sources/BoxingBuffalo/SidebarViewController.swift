import AppKit
import Combine
import FatXCore

/// Sidebar: attached disks on top, mounted FATX volumes underneath.
final class SidebarViewController: NSViewController {

    private enum Row {
        case header(String)
        case device(StorageDevice)
        case volume(MountedVolume)
        case empty(String)
    }

    private let model: AppModel
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let footerStatus = NSTextField(labelWithString: "")
    private let unlockButton = NSButton(title: "解锁写入…", target: nil, action: nil)
    private var rows: [Row] = []
    private var cancellables = Set<AnyCancellable>()
    private var isBuildingRows = false

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowSizeStyle = .custom
        tableView.style = .sourceList
        tableView.selectionHighlightStyle = .regular
        tableView.allowsEmptySelection = true
        tableView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(handleSingleClick)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)

        // Footer: the live permission state, not a fixed slogan. Earlier this
        // said "只读模式" no matter what, which made a successful unlock look
        // like a failed one.
        let footer = NSView()
        footer.translatesAutoresizingMaskIntoConstraints = false
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        footerStatus.font = .systemFont(ofSize: 10)
        footerStatus.textColor = .tertiaryLabelColor
        footerStatus.lineBreakMode = .byTruncatingTail
        footerStatus.translatesAutoresizingMaskIntoConstraints = false
        unlockButton.bezelStyle = .inline
        unlockButton.controlSize = .small
        unlockButton.font = .systemFont(ofSize: 10)
        unlockButton.target = self
        unlockButton.action = #selector(handleUnlockWrite)
        unlockButton.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(separator)
        footer.addSubview(footerStatus)
        footer.addSubview(unlockButton)
        container.addSubview(footer)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor),

            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 30),

            separator.topAnchor.constraint(equalTo: footer.topAnchor),
            separator.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: footer.trailingAnchor),

            footerStatus.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 14),
            footerStatus.centerYAnchor.constraint(equalTo: footer.centerYAnchor, constant: 2),
            footerStatus.trailingAnchor.constraint(lessThanOrEqualTo: unlockButton.leadingAnchor, constant: -6),

            unlockButton.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -10),
            unlockButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor, constant: 2),
        ])

        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        bind()
    }

    private func bind() {
        model.$devices
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildRows() }
            .store(in: &cancellables)

        model.$volumes
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.rebuildRows()
                self?.updateFooter()
            }
            .store(in: &cancellables)

        model.$selectedVolumeID
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.syncSelection()
                self?.updateFooter()
            }
            .store(in: &cancellables)

        updateFooter()
    }

    /// Footer mirrors the volume's actual open mode. The unlock button is the
    /// single obvious place to ask for write access; the toolbar lock does the
    /// same thing.
    private func updateFooter() {
        guard let volume = model.selectedVolume else {
            footerStatus.stringValue = model.volumes.isEmpty ? "未挂载分区" : "未选择分区"
            footerStatus.textColor = .tertiaryLabelColor
            unlockButton.isHidden = true
            return
        }
        if volume.isWritable {
            footerStatus.stringValue = volume.isRawDevice ? "读写模式 · 写入前会再次确认" : "镜像可写 · 写入前会再次确认"
            footerStatus.textColor = .systemGreen
            unlockButton.isHidden = true
        } else if volume.isRawDevice {
            footerStatus.stringValue = "只读模式 · 缺少设备写权限"
            footerStatus.textColor = .systemOrange
            unlockButton.isHidden = !volume.isRawDevice
            unlockButton.isEnabled = !model.isScanning && !model.isWriting
            unlockButton.title = "解锁写入…"
        } else {
            footerStatus.stringValue = "只读模式"
            footerStatus.textColor = .tertiaryLabelColor
            unlockButton.isHidden = true
        }
    }

    @objc private func handleUnlockWrite() {
        model.requestWritePermission()
    }

    private func rebuildRows() {
        var built: [Row] = []
        built.append(.header("外接设备"))
        if model.devices.isEmpty {
            built.append(.empty("没检测到外接磁盘，点工具栏刷新"))
        } else {
            for device in model.devices { built.append(.device(device)) }
        }

        if !model.volumes.isEmpty {
            built.append(.header("已挂载分区"))
            for volume in model.volumes { built.append(.volume(volume)) }
        }

        rows = built
        isBuildingRows = true
        tableView.reloadData()
        isBuildingRows = false
        syncSelection()
    }

    private func syncSelection() {
        guard let id = model.selectedVolumeID else { return }
        if let index = rows.firstIndex(where: {
            if case let .volume(volume) = $0 { return volume.id == id }
            return false
        }) {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
    }

    @objc private func handleSingleClick() {
        guard !isBuildingRows else { return }
        let row = tableView.clickedRow
        guard row >= 0, row < rows.count else { return }
        switch rows[row] {
        case let .device(device):
            model.mount(device: device)
        case let .volume(volume):
            model.selectVolume(volume.id)
        default:
            break
        }
    }
}

extension SidebarViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case .header: return 22
        case .empty: return 26
        default: return 36
        }
    }
}

extension SidebarViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .volume = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case let .header(title):
            let cell = NSTableCellView()
            let label = NSTextField(labelWithString: title.uppercased())
            label.font = .systemFont(ofSize: 10, weight: .semibold)
            label.textColor = .secondaryLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell

        case let .empty(message):
            let cell = NSTableCellView()
            let label = NSTextField(labelWithString: message)
            label.font = .systemFont(ofSize: 10)
            label.textColor = .tertiaryLabelColor
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell

        case let .device(device):
            return makeTwoLineCell(
                symbol: device.isRemovable ? "sdcard" : "externaldrive",
                title: device.displayName,
                subtitle: device.subtitle,
                tint: .secondaryLabelColor
            )

        case let .volume(volume):
            return makeTwoLineCell(
                symbol: "square.stack.3d.up",
                title: volume.label,
                subtitle: "\(FatXVolume.friendlySize(volume.volume.partitionSize)) · \(volume.originName)",
                tint: .controlAccentColor
            )
        }
    }

    private func makeTwoLineCell(symbol: String,
                                 title: String,
                                 subtitle: String,
                                 tint: NSColor) -> NSView {
        let cell = NSTableCellView()

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = tint
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        icon.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let subtitleLabel = NSTextField(labelWithString: subtitle)
        subtitleLabel.font = .systemFont(ofSize: 10)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        cell.addSubview(icon)
        cell.addSubview(titleLabel)
        cell.addSubview(subtitleLabel)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),

            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
            titleLabel.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            titleLabel.topAnchor.constraint(equalTo: cell.topAnchor, constant: 4),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
        ])
        return cell
    }
}
