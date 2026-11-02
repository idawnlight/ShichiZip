import Cocoa

@MainActor
extension CompressDialogController {
    static let formLabelWidth: CGFloat = 126
    static let leftColumnWidth: CGFloat = 320
    static let rightColumnWidth: CGFloat = 364
    static let columnSpacing: CGFloat = 20

    static var updateModeOptions: [Option<SZCompressionUpdateMode>] {
        [
            Option(title: SZL10n.string("update.addReplace"), value: .add),
            Option(title: SZL10n.string("update.updateAdd"), value: .update),
            Option(title: SZL10n.string("update.freshen"), value: .fresh),
            Option(title: SZL10n.string("update.synchronize"), value: .sync),
        ]
    }

    static var pathModeOptions: [Option<SZCompressionPathMode>] {
        [
            Option(title: SZL10n.string("extract.relativePathnames"), value: .relativePaths),
            Option(title: SZL10n.string("extract.fullPathnames"), value: .fullPaths),
            Option(title: SZL10n.string("extract.absolutePathnames"), value: .absolutePaths),
        ]
    }

    static let splitVolumePresets = [
        "10M",
        "100M",
        "1000M",
        "650M - CD",
        "700M - CD",
        "4092M - FAT",
        "4480M - DVD",
        "8128M - DVD DL",
        "23040M - BD",
    ]

    @MainActor
    enum CompressDialogLayout {
        static func makePathRow(label: String,
                                pathField: NSComboBox,
                                browseButton: NSButton) -> NSView
        {
            let labelField = NSTextField(labelWithString: label)
            labelField.alignment = .right
            labelField.font = .systemFont(ofSize: 12)
            labelField.setContentHuggingPriority(.required, for: .horizontal)
            labelField.widthAnchor.constraint(equalToConstant: 96).isActive = true

            let stack = NSStackView(views: [labelField, pathField, browseButton])
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.spacing = 8
            return stack
        }

        static func makeFormRow(label: String,
                                control: NSView) -> NSView
        {
            makeFormRow(labelField: NSTextField(labelWithString: label),
                        control: control,
                        labelWidth: CompressDialogController.formLabelWidth)
        }

        static func makeFormRow(label: String,
                                control: NSView,
                                labelWidth: CGFloat) -> NSView
        {
            makeFormRow(labelField: NSTextField(labelWithString: label),
                        control: control,
                        labelWidth: labelWidth)
        }

        static func makeFormRow(labelField: NSTextField,
                                control: NSView) -> NSView
        {
            makeFormRow(labelField: labelField,
                        control: control,
                        labelWidth: CompressDialogController.formLabelWidth)
        }

        static func makeFormRow(labelField: NSTextField,
                                control: NSView,
                                labelWidth: CGFloat) -> NSView
        {
            labelField.alignment = .right
            labelField.font = .systemFont(ofSize: 12)
            labelField.setContentHuggingPriority(.required, for: .horizontal)
            labelField.widthAnchor.constraint(equalToConstant: labelWidth).isActive = true

            let stack = NSStackView(views: [labelField, control])
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.spacing = 8
            return stack
        }

        static func makeInfoLabel(minWidth: CGFloat) -> NSTextField {
            let label = NSTextField(labelWithString: "")
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.widthAnchor.constraint(greaterThanOrEqualToConstant: minWidth).isActive = true
            return label
        }

        static func makeColumn(rows: [NSView]) -> NSStackView {
            let stack = NSStackView(views: rows)
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 8
            return stack
        }

        static func makeTitledSection(title: String,
                                      rows: [NSView]) -> NSView
        {
            let titleLabel = NSTextField(labelWithString: title)
            titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
            titleLabel.textColor = .secondaryLabelColor

            let content = NSStackView(views: rows)
            content.translatesAutoresizingMaskIntoConstraints = false
            content.orientation = .vertical
            content.alignment = .leading
            content.spacing = 8

            let panel = NSView(frame: .zero)
            panel.translatesAutoresizingMaskIntoConstraints = false
            panel.wantsLayer = true
            panel.layer?.cornerRadius = 8
            panel.layer?.borderWidth = 1
            panel.layer?.borderColor = NSColor.separatorColor.cgColor
            panel.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.45).cgColor
            panel.addSubview(content)

            NSLayoutConstraint.activate([
                content.topAnchor.constraint(equalTo: panel.topAnchor, constant: 10),
                content.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 10),
                content.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -10),
                content.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -10),
            ])

            let section = NSStackView(views: [titleLabel, panel])
            section.orientation = .vertical
            section.alignment = .leading
            section.spacing = 6
            return section
        }
    }
}
