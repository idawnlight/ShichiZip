import Cocoa

class SettingsWindowController: NSWindowController {

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "ShichiZip Settings"
        window.center()
        self.init(window: window)
        setupUI()
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        let tabView = NSTabView()
        tabView.translatesAutoresizingMaskIntoConstraints = false

        // General tab
        let generalTab = NSTabViewItem(identifier: "general")
        generalTab.label = "General"
        let generalView = createGeneralTab()
        generalTab.view = generalView
        tabView.addTabViewItem(generalTab)

        // Performance tab
        let perfTab = NSTabViewItem(identifier: "performance")
        perfTab.label = "Performance"
        let perfView = createPerformanceTab()
        perfTab.view = perfView
        tabView.addTabViewItem(perfTab)

        // File Associations tab
        let assocTab = NSTabViewItem(identifier: "associations")
        assocTab.label = "File Associations"
        let assocView = createAssociationsTab()
        assocTab.view = assocView
        tabView.addTabViewItem(assocTab)

        contentView.addSubview(tabView)

        NSLayoutConstraint.activate([
            tabView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            tabView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            tabView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            tabView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
        ])
    }

    private func createGeneralTab() -> NSView {
        let view = NSView()

        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 10

        // Default format
        let fmtLabel = NSTextField(labelWithString: "Default archive format:")
        let fmtPopup = NSPopUpButton(title: "", target: nil, action: nil)
        fmtPopup.addItems(withTitles: ["7z", "zip", "tar.gz"])
        grid.addRow(with: [fmtLabel, fmtPopup])

        // Default level
        let levelLabel = NSTextField(labelWithString: "Default compression level:")
        let levelPopup = NSPopUpButton(title: "", target: nil, action: nil)
        levelPopup.addItems(withTitles: ["Normal", "Maximum", "Ultra", "Fast", "Fastest", "Store"])
        grid.addRow(with: [levelLabel, levelPopup])

        // Temp folder
        let tempLabel = NSTextField(labelWithString: "Temp folder:")
        let tempPath = NSPathControl()
        tempPath.pathStyle = .standard
        tempPath.url = URL(fileURLWithPath: NSTemporaryDirectory())
        grid.addRow(with: [tempLabel, tempPath])

        // Open after extract
        let openCheckbox = NSButton(checkboxWithTitle: "Open destination after extraction", target: nil, action: nil)
        openCheckbox.state = .on
        grid.addRow(with: [NSView(), openCheckbox])

        view.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])

        return view
    }

    private func createPerformanceTab() -> NSView {
        let view = NSView()

        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 10

        let threadLabel = NSTextField(labelWithString: "Max CPU threads:")
        let threadField = NSTextField()
        threadField.placeholderString = "Auto"
        grid.addRow(with: [threadLabel, threadField])

        let memLabel = NSTextField(labelWithString: "Memory limit (MB):")
        let memField = NSTextField()
        memField.placeholderString = "No limit"
        grid.addRow(with: [memLabel, memField])

        view.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])

        return view
    }

    private func createAssociationsTab() -> NSView {
        let view = NSView()

        let label = NSTextField(wrappingLabelWithString: "Select file types to associate with ShichiZip. Double-click an archive file in Finder to open it in ShichiZip.")
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)

        let extensions = ["7z", "zip", "tar", "gz", "bz2", "xz", "rar", "cab", "iso", "dmg", "wim", "lzh", "arj", "cpio", "rpm", "deb", "zst"]

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true

        let stackView = NSStackView()
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 4

        for ext in extensions {
            let checkbox = NSButton(checkboxWithTitle: ".\(ext)", target: nil, action: nil)
            checkbox.state = .on
            stackView.addArrangedSubview(checkbox)
        }

        scrollView.documentView = stackView
        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),

            scrollView.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
        ])

        return view
    }
}
