import AppKit
import Combine
import UniformTypeIdentifiers
import FatXCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: MainWindowController?
    private var cancellables = Set<AnyCancellable>()
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        let controller = MainWindowController(model: model)
        controller.showWindow(nil)
        windowController = controller
        NSApp.activate(ignoringOtherApps: true)

        // Errors used to be written into AppModel and never read by anything,
        // so a failed unlock looked like "nothing happened". Show every one.
        model.$errorMessage
            .receive(on: RunLoop.main)
            .sink { [weak self] message in
                guard let message, !message.isEmpty else { return }
                self?.model.errorMessage = nil
                self?.presentError(message)
            }
            .store(in: &cancellables)

        model.refreshDevices()
        if !openLaunchArguments() {
            model.reopenLastDevice()
        }
    }

    private func presentError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "BoxingBuffalo 没能完成这一步"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        let needsFDA = message.contains("完全磁盘访问权限") || message.contains("EPERM")
        if needsFDA {
            alert.addButton(withTitle: "打开隐私设置")
        } else if message.contains("写权限") || message.contains("只读") {
            alert.addButton(withTitle: "重试解锁")
        }
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        if needsFDA {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
        } else {
            model.requestWritePermission()
        }
    }

    /// Supports `BoxingBuffalo /dev/rdisk8` and `BoxingBuffalo some-image.bin`, which makes
    /// the app scriptable and testable without clicking.
    @discardableResult
    private func openLaunchArguments() -> Bool {
        for argument in CommandLine.arguments.dropFirst() where !argument.hasPrefix("-") {
            if argument.hasPrefix("/dev/") {
                let id = argument.replacingOccurrences(of: "/dev/", with: "")
                    .replacingOccurrences(of: "rdisk", with: "disk")
                if let device = model.devices.first(where: { $0.id == id }) {
                    model.mount(device: device)
                    return true
                }
            } else if FileManager.default.fileExists(atPath: argument) {
                model.openImage(url: URL(fileURLWithPath: argument))
                return true
            }
        }
        return false
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        for filename in filenames {
            if filename.hasPrefix("/dev/") {
                let id = filename.replacingOccurrences(of: "/dev/", with: "")
                    .replacingOccurrences(of: "rdisk", with: "disk")
                if let device = model.devices.first(where: { $0.id == id }) {
                    model.mount(device: device)
                }
            } else {
                model.openImage(url: URL(fileURLWithPath: filename))
            }
        }
        sender.reply(toOpenOrPrint: .success)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { windowController?.showWindow(nil) }
        return true
    }

    // MARK: - Menu

    private func buildMenu() {
        let mainMenu = NSMenu()

        // Application menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 BoxingBuffalo",
                        action: #selector(showAbout),
                        keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 BoxingBuffalo",
                        action: #selector(NSApplication.hide(_:)),
                        keyEquivalent: "h")
        appMenu.addItem(withTitle: "隐藏其他",
                        action: #selector(NSApplication.hideOtherApplications(_:)),
                        keyEquivalent: "h").keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 BoxingBuffalo",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // File
        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "文件")
        let openItem = NSMenuItem(title: "打开镜像文件…",
                                  action: #selector(openImage),
                                  keyEquivalent: "o")
        openItem.target = self
        fileMenu.addItem(openItem)

        let sampleItem = NSMenuItem(title: "生成示例卷",
                                    action: #selector(openSample),
                                    keyEquivalent: "n")
        sampleItem.keyEquivalentModifierMask = [.command, .shift]
        sampleItem.target = self
        fileMenu.addItem(sampleItem)

        fileMenu.addItem(.separator())

        let uploadItem = NSMenuItem(title: "上传文件到当前目录…",
                                    action: #selector(uploadFiles),
                                    keyEquivalent: "u")
        uploadItem.target = self
        fileMenu.addItem(uploadItem)

        let folderItem = NSMenuItem(title: "新建文件夹…",
                                    action: #selector(newFolder),
                                    keyEquivalent: "n")
        folderItem.keyEquivalentModifierMask = [.command, .shift]
        folderItem.target = self
        fileMenu.addItem(folderItem)

        fileMenu.addItem(.separator())

        let refreshItem = NSMenuItem(title: "刷新设备列表",
                                     action: #selector(refreshDevices),
                                     keyEquivalent: "r")
        refreshItem.target = self
        fileMenu.addItem(refreshItem)

        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "关闭窗口",
                         action: #selector(NSWindow.performClose(_:)),
                         keyEquivalent: "w")
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // Edit
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // Browse
        let browseMenuItem = NSMenuItem()
        let browseMenu = NSMenu(title: "浏览")
        let upItem = NSMenuItem(title: "上一级", action: #selector(goUp), keyEquivalent: "↑")
        upItem.keyEquivalentModifierMask = [.command]
        upItem.target = self
        browseMenu.addItem(upItem)

        let rootItem = NSMenuItem(title: "回到分区根目录", action: #selector(goRoot), keyEquivalent: "↑")
        rootItem.keyEquivalentModifierMask = [.command, .shift]
        rootItem.target = self
        browseMenu.addItem(rootItem)

        browseMenu.addItem(.separator())
        let reloadItem = NSMenuItem(title: "刷新目录", action: #selector(reloadEntries), keyEquivalent: "r")
        reloadItem.keyEquivalentModifierMask = [.command, .option]
        reloadItem.target = self
        browseMenu.addItem(reloadItem)

        browseMenu.addItem(.separator())
        let deleteItem = NSMenuItem(title: "删除选中项",
                                    action: #selector(deleteSelection(_:)),
                                    keyEquivalent: "\u{8}")
        deleteItem.keyEquivalentModifierMask = []
        deleteItem.target = self
        browseMenu.addItem(deleteItem)

        browseMenu.addItem(.separator())
        let deletedItem = NSMenuItem(title: "显示已删除项目",
                                     action: #selector(toggleDeleted),
                                     keyEquivalent: "d")
        deletedItem.keyEquivalentModifierMask = [.command, .shift]
        deletedItem.target = self
        browseMenu.addItem(deletedItem)

        browseMenuItem.submenu = browseMenu
        mainMenu.addItem(browseMenuItem)

        // Window
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "最小化",
                           action: #selector(NSWindow.performMiniaturize(_:)),
                           keyEquivalent: "m")
        windowMenu.addItem(withTitle: "缩放",
                           action: #selector(NSWindow.performZoom(_:)),
                           keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "BoxingBuffalo"
        alert.informativeText = """
        Xbox 360 FATX 卷浏览器 · macOS 原生版

        默认以只读方式打开磁盘。要写入，先点锁图标申请设备写权限（一次管理员授权），
        之后每次上传、新建、删除都会单独确认并留下日志。
        FATX 解析逻辑参考 Party Buffalo 的 CLKsFATXLib（GPL）重写为 Swift。
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    @objc private func openImage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "选择一个 FATX 镜像文件或分区转储"
        panel.prompt = "打开"
        panel.allowedContentTypes = [.data, .diskImage]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.openImage(url: url)
    }

    @objc private func openSample() {
        model.openSampleVolume()
    }

    @objc private func refreshDevices() {
        model.refreshDevices()
    }

    @objc private func goUp() {
        model.goUp()
    }

    @objc private func goRoot() {
        model.goToRoot()
    }

    @objc private func reloadEntries() {
        model.reloadEntries()
    }

    @objc private func toggleDeleted() {
        model.showDeletedEntries.toggle()
        model.reloadEntries()
    }

    @objc private func uploadFiles() {
        windowController?.uploadFiles()
    }

    @objc private func newFolder() {
        windowController?.promptNewFolder()
    }

    @objc func deleteSelection(_ sender: Any?) {
        windowController?.deleteSelection()
    }
}
