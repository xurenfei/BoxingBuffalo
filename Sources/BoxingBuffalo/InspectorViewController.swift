import AppKit
import Combine
import FatXCore

/// Right-hand inspector: selected entry details on top, volume geometry below.
final class InspectorViewController: NSViewController {

    private let model: AppModel
    private let scrollView = NSScrollView()
    private let contentStack = NSStackView()
    private var cancellables = Set<AnyCancellable>()

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = NSView()

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 5
        contentStack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        let flipped = FlippedView()
        flipped.translatesAutoresizingMaskIntoConstraints = false
        flipped.addSubview(contentStack)

        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: flipped.topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: flipped.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: flipped.trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: flipped.bottomAnchor),
        ])

        scrollView.documentView = flipped
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // The document view only joins a real hierarchy once the scroll view is
        // installed, so width has to be pinned to the clip view — pinning it to
        // `container` inside the same batch raises "no common ancestor" and
        // aborts app launch.
        NSLayoutConstraint.activate([
            flipped.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            flipped.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            flipped.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
        ])

        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        Publishers.Merge3(
            model.$selection.map { _ in () },
            model.$entries.map { _ in () },
            model.$selectedVolumeID.map { _ in () }
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] in self?.rebuild() }
        .store(in: &cancellables)

        rebuild()
    }

    private func rebuild() {
        contentStack.arrangedSubviews.forEach {
            contentStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        let selected = model.filteredEntries.filter { model.selection.contains($0.id) }

        if let entry = selected.first {
            addEntrySection(entry, extraCount: selected.count - 1)
            addSeparator()
        }

        addGeometrySection()
    }

    // MARK: - Entry section

    private func addEntrySection(_ entry: FatXEntry, extraCount: Int) {
        let header = NSStackView()
        header.orientation = .horizontal
        header.spacing = 6
        header.alignment = .centerY

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: entry.isDirectory ? "folder.fill" : "doc.fill",
                             accessibilityDescription: nil)
        icon.contentTintColor = entry.isDirectory ? .controlAccentColor : .secondaryLabelColor
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)

        let title = NSTextField(wrappingLabelWithString: entry.name)
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.maximumNumberOfLines = 3
        title.lineBreakMode = .byTruncatingMiddle

        header.addArrangedSubview(icon)
        header.addArrangedSubview(title)
        contentStack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -28).isActive = true

        if entry.isDeleted {
            let warning = NSTextField(labelWithString: "已删除 · 数据可能仍可恢复")
            warning.font = .systemFont(ofSize: 10)
            warning.textColor = .systemOrange
            contentStack.addArrangedSubview(warning)
        }

        addInfoRow("类型", entry.isDirectory ? "目录" : "文件")
        if !entry.isDirectory {
            addInfoRow("大小", "\(FatXVolume.friendlySize(Int64(entry.size)))  (\(entry.size) 字节)")
        }
        addInfoRow("起始簇", "\(entry.startingCluster)")
        addInfoRow("目录项", "0x" + String(entry.entryOffset, radix: 16).uppercased())

        if let created = entry.created { addInfoRow("创建", format(created)) }
        if let modified = entry.modified { addInfoRow("修改", format(modified)) }
        if let accessed = entry.accessed { addInfoRow("访问", format(accessed)) }
        if !entry.flags.humanReadable.isEmpty {
            addInfoRow("属性", entry.flags.humanReadable.joined(separator: " · "))
        }
        if extraCount > 0 {
            addInfoRow("", "另有 \(extraCount) 个选中项")
        }
    }

    // MARK: - Geometry section

    private func addGeometrySection() {
        let title = NSTextField(labelWithString: "分区几何")
        title.font = .systemFont(ofSize: 10, weight: .semibold)
        title.textColor = .secondaryLabelColor
        contentStack.addArrangedSubview(title)
        contentStack.setCustomSpacing(8, after: title)

        guard let volume = model.selectedVolume else {
            addInfoRow("", "未挂载")
            return
        }

        for (key, value) in volume.volume.geometrySummary {
            addInfoRow(key, value)
        }

        let layoutLabel = NSTextField(labelWithString: volume.layout.rawValue)
        layoutLabel.font = .systemFont(ofSize: 10)
        layoutLabel.textColor = .tertiaryLabelColor
        contentStack.addArrangedSubview(layoutLabel)
        contentStack.setCustomSpacing(8, after: layoutLabel)

        let access = volume.isWritable ? "可写" : "只读"
        let sourceLabel = NSTextField(wrappingLabelWithString: "来源：\(volume.originName)（\(access)）")
        sourceLabel.font = .systemFont(ofSize: 10)
        sourceLabel.textColor = .tertiaryLabelColor
        sourceLabel.maximumNumberOfLines = 2
        contentStack.addArrangedSubview(sourceLabel)
    }

    // MARK: - Helpers

    private func addInfoRow(_ key: String, _ value: String) {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 6
        row.alignment = .top

        let keyLabel = NSTextField(labelWithString: key)
        keyLabel.font = .systemFont(ofSize: 10)
        keyLabel.textColor = .secondaryLabelColor
        keyLabel.alignment = .left
        keyLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        keyLabel.widthAnchor.constraint(equalToConstant: 52).isActive = true

        let valueLabel = NSTextField(wrappingLabelWithString: value)
        valueLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        valueLabel.textColor = .labelColor
        valueLabel.maximumNumberOfLines = 3
        valueLabel.lineBreakMode = .byTruncatingMiddle
        valueLabel.isSelectable = true

        row.addArrangedSubview(keyLabel)
        row.addArrangedSubview(valueLabel)
        contentStack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -28).isActive = true
    }

    private func addSeparator() {
        let box = NSBox()
        box.boxType = .separator
        box.heightAnchor.constraint(equalToConstant: 1).isActive = true
        contentStack.addArrangedSubview(box)
        box.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -28).isActive = true
        contentStack.setCustomSpacing(12, after: box)
    }

    private func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}

/// NSStackView inside an NSScrollView needs a flipped container or content
/// anchors to the wrong edge.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
