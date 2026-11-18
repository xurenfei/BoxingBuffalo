import AppKit
import Combine
import FatXCore

final class MainWindowController: NSWindowController, NSToolbarDelegate {

    private let model: AppModel
    private let splitController: MainSplitViewController
    private var lockButton: NSButton?
    private var cancellables = Set<AnyCancellable>()

    init(model: AppModel) {
        self.model = model
        self.splitController = MainSplitViewController(model: model)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "BoxingBuffalo"
        window.titlebarAppearsTransparent = false
        window.minSize = NSSize(width: 820, height: 460)
        window.center()
        window.setFrameAutosaveName("BoxingBuffaloMainWindow")

        super.init(window: window)


        window.contentViewController = splitController
        window.toolbar = makeToolbar()
        window.toolbarStyle = .unified

        splitController.onRequestSearchFocus = { [weak self] in
            self?.focusSearchField()
        }

        // Must come last: assigning `contentViewController` shrinks the window to
        // the view's fitting size, silently discarding the size set earlier.
        if window.frame.width < 1040 || window.frame.height < 620 {
            window.setContentSize(NSSize(width: 1180, height: 740))
            window.center()
        }

        // The padlock mirrors the volume's real open mode, so a successful
        // unlock is visible instead of being masked by a hard-coded label.
        model.$volumes
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateLockButton() }
            .store(in: &cancellables)
        model.$selectedVolumeID
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateLockButton() }
            .store(in: &cancellables)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Toolbar

    private enum ItemID {
        static let up = NSToolbarItem.Identifier("up")
        static let root = NSToolbarItem.Identifier("root")
        static let refresh = NSToolbarItem.Identifier("refresh")
        static let upload = NSToolbarItem.Identifier("upload")
        static let newFolder = NSToolbarItem.Identifier("newFolder")
        static let lock = NSToolbarItem.Identifier("lock")
        static let deleted = NSToolbarItem.Identifier("deleted")
        static let inspector = NSToolbarItem.Identifier("inspector")
        static let search = NSToolbarItem.Identifier("search")
    }

    private func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "BoxingBuffaloToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        return toolbar
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ItemID.up, ItemID.root, ItemID.refresh, .space,
         ItemID.upload, ItemID.newFolder, ItemID.lock,
         .flexibleSpace, ItemID.deleted, ItemID.search, ItemID.inspector]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case ItemID.up:
            return makeButtonItem(id: itemIdentifier, symbol: "chevron.up",
                                  label: "上一级", action: #selector(handleUp))
        case ItemID.root:
            return makeButtonItem(id: itemIdentifier, symbol: "house",
                                  label: "根目录", action: #selector(handleRoot))
        case ItemID.refresh:
            return makeButtonItem(id: itemIdentifier, symbol: "arrow.clockwise",
                                  label: "刷新", action: #selector(handleRefresh))
        case ItemID.upload:
            return makeButtonItem(id: itemIdentifier, symbol: "square.and.arrow.up",
                                  label: "上传文件", action: #selector(handleUpload))
        case ItemID.newFolder:
            return makeButtonItem(id: itemIdentifier, symbol: "folder.badge.plus",
                                  label: "新建文件夹", action: #selector(handleNewFolder))
        case ItemID.lock:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            let button = NSButton()
            button.bezelStyle = .texturedRounded
            button.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "写入权限")
            button.target = self
            button.action = #selector(handleUnlockWrite)
            button.toolTip = "只读：点此申请设备写权限"
            item.view = button
            item.label = "写入权限"
            lockButton = button
            updateLockButton()
            return item
        case ItemID.deleted:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            let button = NSButton()
            button.setButtonType(.toggle)
            button.bezelStyle = .texturedRounded
            button.image = NSImage(systemSymbolName: "trash.slash", accessibilityDescription: "显示已删除")
            button.target = self
            button.action = #selector(handleToggleDeleted(_:))
            button.toolTip = "显示已删除项目（数据恢复用）"
            item.view = button
            item.label = "已删除"
            return item
        case ItemID.search:
            let item = NSSearchToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "筛选"
            item.searchField.placeholderString = "在当前目录筛选"
            item.searchField.target = self
            item.searchField.action = #selector(handleSearch(_:))
            item.searchField.sendsSearchStringImmediately = true
            return item
        case ItemID.inspector:
            return makeButtonItem(id: itemIdentifier, symbol: "sidebar.right",
                                  label: "检查器", action: #selector(handleToggleInspector))
        default:
            return nil
        }
    }

    private func makeButtonItem(id: NSToolbarItem.Identifier,
                                symbol: String,
                                label: String,
                                action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        let button = NSButton()
        button.bezelStyle = .texturedRounded
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.target = self
        button.action = action
        button.toolTip = label
        item.view = button
        item.label = label
        return item
    }

    // MARK: - Actions

    @objc private func handleUp() { model.goUp() }
    @objc private func handleRoot() { model.goToRoot() }
    @objc private func handleRefresh() { model.reloadEntries() }
    @objc private func handleToggleInspector() { splitController.toggleInspector() }
    @objc private func handleUpload() { splitController.uploadFiles() }
    @objc private func handleNewFolder() { splitController.promptNewFolder() }
    @objc func deleteSelection() { splitController.deleteSelection() }

    private func updateLockButton() {
        guard let button = lockButton else { return }
        let symbol = model.canWrite ? "lock.open.fill" : "lock.fill"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "写入权限")
        button.contentTintColor = model.canWrite ? .systemGreen : .systemOrange
        if model.selectedVolume == nil {
            button.toolTip = "先选一个分区"
        } else if model.canWrite {
            button.toolTip = "已解锁写入（每次写入仍会确认）"
        } else {
            button.toolTip = "只读：点此申请设备写权限（一次管理员授权）"
        }
    }

    @objc private func handleUnlockWrite() {
        if model.canWrite {
            model.statusMessage = "\(model.selectedVolume?.originName ?? "当前卷") 已经是读写模式。"
        } else {
            model.requestWritePermission()
        }
    }

    /// Menu commands route through here so the same confirmation dialogs run
    /// whether the action started from the toolbar, the menu or a key binding.
    func uploadFiles() { splitController.uploadFiles() }
    func promptNewFolder() { splitController.promptNewFolder() }

    @objc private func handleToggleDeleted(_ sender: NSButton) {
        model.showDeletedEntries = sender.state == .on
        model.reloadEntries()
    }

    @objc private func handleSearch(_ sender: NSSearchField) {
        model.searchText = sender.stringValue
    }

    private func focusSearchField() {
        guard let toolbar = window?.toolbar else { return }
        for item in toolbar.items {
            if let searchItem = item as? NSSearchToolbarItem {
                window?.makeFirstResponder(searchItem.searchField)
                return
            }
        }
    }
}

// MARK: - Split

final class MainSplitViewController: NSSplitViewController {
    private let model: AppModel
    private let sidebarVC: SidebarViewController
    private let browserVC: BrowserViewController
    private let inspectorVC: InspectorViewController
    private var inspectorItem: NSSplitViewItem?
    var onRequestSearchFocus: (() -> Void)?

    init(model: AppModel) {
        self.model = model
        self.sidebarVC = SidebarViewController(model: model)
        self.browserVC = BrowserViewController(model: model)
        self.inspectorVC = InspectorViewController(model: model)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarVC)
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 340
        sidebarItem.canCollapse = true

        let browserItem = NSSplitViewItem(viewController: browserVC)
        browserItem.minimumThickness = 420

        let inspector = NSSplitViewItem(inspectorWithViewController: inspectorVC)
        inspector.minimumThickness = 220
        inspector.maximumThickness = 320
        inspector.canCollapse = true
        inspector.isCollapsed = false
        inspectorItem = inspector

        addSplitViewItem(sidebarItem)
        addSplitViewItem(browserItem)
        addSplitViewItem(inspector)
    }

    func toggleInspector() {
        guard let inspectorItem else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            inspectorItem.animator().isCollapsed.toggle()
        }
    }

    func uploadFiles() { browserVC.uploadFiles() }
    func promptNewFolder() { browserVC.promptNewFolder() }
    func deleteSelection() { browserVC.confirmAndDelete() }
}
