import Cocoa

final class FileManagerPaneStatusView: NSStackView {
    let summaryLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(labelWithString: "")
    private let spacer = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        orientation = .horizontal
        alignment = .centerY
        spacing = 12

        configure(summaryLabel, lineBreakMode: .byTruncatingTail)
        summaryLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        summaryLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        summaryLabel.setAccessibilityIdentifier("fileManager.statusLabel")

        configure(detailLabel, lineBreakMode: .byTruncatingMiddle)
        detailLabel.alignment = .right
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.setContentHuggingPriority(.required, for: .horizontal)
        detailLabel.setAccessibilityIdentifier("fileManager.statusDetailLabel")
        detailLabel.isHidden = true

        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)

        addArrangedSubview(summaryLabel)
        addArrangedSubview(spacer)
        addArrangedSubview(detailLabel)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setContent(_ content: FileManagerStatusBarContent) {
        summaryLabel.stringValue = content.summary
        summaryLabel.toolTip = content.summary

        detailLabel.stringValue = content.detail ?? ""
        detailLabel.toolTip = content.detail
        detailLabel.isHidden = content.detail == nil
    }

    func clear() {
        summaryLabel.stringValue = ""
        summaryLabel.toolTip = nil
        detailLabel.stringValue = ""
        detailLabel.toolTip = nil
        detailLabel.isHidden = true
    }

    private func configure(_ label: NSTextField,
                           lineBreakMode: NSLineBreakMode)
    {
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = lineBreakMode
        label.maximumNumberOfLines = 1
        label.cell?.wraps = false
        label.cell?.usesSingleLineMode = true
        label.cell?.truncatesLastVisibleLine = true
    }
}

final class FileManagerPaneView: NSView {
    let upButton: NSButton
    let locationIconView: NSImageView
    let pathField: NSTextField
    let tableView: FileManagerTableView
    let scrollView: NSScrollView
    let statusView: FileManagerPaneStatusView

    init(currentDirectory: URL,
         addressBarIconSize: CGFloat,
         listRowHeight: CGFloat)
    {
        upButton = NSButton(image: NSImage(systemSymbolName: "chevron.up", accessibilityDescription: SZL10n.string("view.upOneLevel"))!, target: nil, action: nil)
        locationIconView = NSImageView()
        pathField = NSTextField()
        tableView = FileManagerTableView()
        scrollView = NSScrollView()
        statusView = FileManagerPaneStatusView()

        super.init(frame: NSRect(x: 0, y: 0, width: 500, height: 600))

        configureUpButton()
        configureLocationIcon(currentDirectory: currentDirectory)
        configurePathField(currentDirectory: currentDirectory)
        configureTableView(rowHeight: listRowHeight)
        configureScrollView()
        configureStatusView()
        installLayout(addressBarIconSize: addressBarIconSize)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configureUpButton() {
        upButton.translatesAutoresizingMaskIntoConstraints = false
        upButton.bezelStyle = .accessoryBarAction
        upButton.isBordered = false
        upButton.refusesFirstResponder = true
        upButton.setAccessibilityIdentifier("fileManager.upButton")
        addSubview(upButton)
    }

    private func configureLocationIcon(currentDirectory: URL) {
        locationIconView.translatesAutoresizingMaskIntoConstraints = false
        locationIconView.imageScaling = .scaleProportionallyDown
        locationIconView.refusesFirstResponder = true
        locationIconView.image = NSWorkspace.shared.icon(forFile: currentDirectory.path)
        addSubview(locationIconView)
    }

    private func configurePathField(currentDirectory: URL) {
        pathField.translatesAutoresizingMaskIntoConstraints = false
        pathField.usesSingleLineMode = true
        pathField.lineBreakMode = .byTruncatingHead
        pathField.cell?.usesSingleLineMode = true
        pathField.cell?.wraps = false
        pathField.cell?.isScrollable = true
        pathField.isAutomaticTextCompletionEnabled = false
        pathField.stringValue = currentDirectory.path
        pathField.setAccessibilityIdentifier("fileManager.pathField")
        addSubview(pathField)
    }

    private func configureTableView(rowHeight: CGFloat) {
        tableView.pressureConfiguration = NSPressureConfiguration(pressureBehavior: .primaryDeepClick)
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnResizing = true
        tableView.allowsColumnReordering = true
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.rowSizeStyle = .custom
        tableView.rowHeight = rowHeight
        tableView.intercellSpacing = NSSize(width: tableView.intercellSpacing.width, height: 0)
        tableView.setAccessibilityIdentifier("fileManager.tableView")
    }

    private func configureScrollView() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        addSubview(scrollView)
    }

    private func configureStatusView() {
        statusView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusView)
    }

    private func installLayout(addressBarIconSize: CGFloat) {
        NSLayoutConstraint.activate([
            upButton.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            upButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            upButton.widthAnchor.constraint(equalToConstant: 24),
            upButton.heightAnchor.constraint(equalToConstant: 24),

            locationIconView.leadingAnchor.constraint(equalTo: upButton.trailingAnchor, constant: 6),
            locationIconView.centerYAnchor.constraint(equalTo: pathField.centerYAnchor),
            locationIconView.widthAnchor.constraint(equalToConstant: addressBarIconSize),
            locationIconView.heightAnchor.constraint(equalToConstant: addressBarIconSize),

            pathField.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            pathField.leadingAnchor.constraint(equalTo: locationIconView.trailingAnchor, constant: 6),
            pathField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            pathField.heightAnchor.constraint(equalToConstant: 24),

            scrollView.topAnchor.constraint(equalTo: pathField.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: statusView.topAnchor, constant: -2),

            statusView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            statusView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            statusView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            statusView.heightAnchor.constraint(equalToConstant: 16),
        ])
    }
}

private struct FileManagerPaneTableCellConfiguration {
    let text: String
    let isDirectory: Bool
    let iconPath: String
    let isHidden: Bool

    init(item: FileManagerPaneItem,
         columnID: FileManagerColumnID,
         dateFormatter: DateFormatter)
    {
        switch item {
        case .parent:
            text = FileManagerItemPresentation.parentRowListCellText(for: columnID)
            isDirectory = true
            iconPath = ""
            isHidden = false
        case let .archive(archiveItem):
            text = FileManagerItemPresentation.listCellText(for: archiveItem,
                                                            columnID: columnID,
                                                            dateFormatter: dateFormatter)
            isDirectory = archiveItem.isDirectory
            iconPath = archiveItem.name
            isHidden = archiveItem.isHidden
        case let .filesystem(fileSystemItem):
            text = FileManagerItemPresentation.listCellText(for: fileSystemItem,
                                                            columnID: columnID,
                                                            dateFormatter: dateFormatter)
            isDirectory = fileSystemItem.isDirectory
            iconPath = fileSystemItem.url.path
            isHidden = fileSystemItem.isHidden
        }
    }
}

@MainActor
enum FileManagerPaneTableCellRenderer {
    typealias IconImageProvider = (FileManagerPaneItem, Bool, String) -> NSImage?

    static func view(in tableView: NSTableView,
                     for item: FileManagerPaneItem,
                     tableColumn: NSTableColumn,
                     columns: [FileManagerColumn],
                     fallbackColumns: [FileManagerColumn],
                     dateFormatter: DateFormatter,
                     owner: Any?,
                     iconSize: NSSize,
                     showsRealFileIcons: Bool,
                     iconImageProvider: IconImageProvider) -> NSView
    {
        let columnID = FileManagerColumnID(rawValue: tableColumn.identifier.rawValue)
        let cellID = NSUserInterfaceItemIdentifier(columnID.rawValue)
        let cell = tableCell(in: tableView,
                             identifier: cellID,
                             owner: owner,
                             showsIcon: columnID == .name)
        let column = columns.first(where: { $0.id == columnID })
            ?? fallbackColumns.first(where: { $0.id == columnID })
            ?? FileManagerColumn.definition(for: columnID)
        let configuration = FileManagerPaneTableCellConfiguration(item: item,
                                                                  columnID: columnID,
                                                                  dateFormatter: dateFormatter)

        cell.textField?.alignment = column.alignment
        cell.textField?.font = column.font
        cell.textField?.lineBreakMode = columnID == .name ? .byTruncatingMiddle : .byTruncatingTail
        cell.textField?.stringValue = column.normalizedDisplayString(configuration.text)
        cell.textField?.textColor = columnID == .name && !configuration.isHidden
            ? .labelColor
            : .secondaryLabelColor
        cell.textField?.alphaValue = configuration.isHidden ? 0.7 : 1.0

        if columnID == .name {
            configureIcon(cell.imageView,
                          for: item,
                          configuration: configuration,
                          iconSize: iconSize,
                          showsRealFileIcons: showsRealFileIcons,
                          iconImageProvider: iconImageProvider)
        }

        return cell
    }

    private static func tableCell(in tableView: NSTableView,
                                  identifier: NSUserInterfaceItemIdentifier,
                                  owner: Any?,
                                  showsIcon: Bool) -> NSTableCellView
    {
        if let reused = tableView.makeView(withIdentifier: identifier, owner: owner) as? NSTableCellView {
            return reused
        }

        let cell = NSTableCellView()
        cell.identifier = identifier

        let textField = NSTextField(labelWithString: "")
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.lineBreakMode = .byTruncatingMiddle
        cell.addSubview(textField)
        cell.textField = textField

        if showsIcon {
            let imageView = NSImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.imageScaling = .scaleProportionallyDown
            imageView.imageAlignment = .alignCenter
            cell.addSubview(imageView)
            cell.imageView = imageView

            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 16),
                imageView.heightAnchor.constraint(equalToConstant: 16),
                textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 4),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        } else {
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }

        return cell
    }

    private static func configureIcon(_ imageView: NSImageView?,
                                      for item: FileManagerPaneItem,
                                      configuration: FileManagerPaneTableCellConfiguration,
                                      iconSize: NSSize,
                                      showsRealFileIcons: Bool,
                                      iconImageProvider: IconImageProvider)
    {
        imageView?.image = iconImageProvider(item,
                                             configuration.isDirectory,
                                             configuration.iconPath)
        imageView?.alphaValue = configuration.isHidden ? 0.5 : 1.0
        switch item {
        case .parent:
            imageView?.contentTintColor = .secondaryLabelColor
        default:
            if showsRealFileIcons {
                imageView?.contentTintColor = nil
            } else {
                imageView?.contentTintColor = configuration.isDirectory ? .systemBlue : .secondaryLabelColor
            }
        }
        imageView?.image?.size = iconSize
    }
}
