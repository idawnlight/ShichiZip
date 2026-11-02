import Cocoa

@MainActor
extension CompressDialogController {
    @MainActor
    final class CompressDialogContentController {
        let accessoryView: NSView
        private let controls: CompressDialogControls
        private(set) var state: CompressDialogState
        private let availableFormats: [FormatOption]

        var preferredFirstResponder: NSView {
            controls.archivePathField
        }

        var archivePathField: NSComboBox {
            controls.archivePathField
        }

        init(owner: CompressDialogController,
             initialState: CompressDialogState,
             availableFormats: [FormatOption],
             onPasswordChange: @escaping () -> Void)
        {
            state = initialState
            self.availableFormats = availableFormats

            let archivePathField = NSComboBox(frame: NSRect(x: 0, y: 0, width: 360, height: 26))
            archivePathField.usesDataSource = false
            archivePathField.completes = false
            archivePathField.isEditable = true
            archivePathField.addItems(withObjectValues: ArchivePathHistory.entries())
            archivePathField.stringValue = initialState.archivePath
            archivePathField.widthAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true
            archivePathField.setAccessibilityIdentifier("compress.archivePath")

            let browseButton = NSButton(title: SZL10n.string("compress.browse"), target: nil, action: nil)
            browseButton.bezelStyle = .rounded
            browseButton.setAccessibilityIdentifier("compress.browseButton")

            let formatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
            availableFormats.forEach { formatPopup.addItem(withTitle: $0.title) }
            if let selectedIndex = availableFormats.firstIndex(where: { $0.codecName == initialState.formatName }) {
                formatPopup.selectItem(at: selectedIndex)
            }
            formatPopup.target = owner
            formatPopup.action = #selector(CompressDialogController.formatChanged(_:))
            formatPopup.setAccessibilityIdentifier("compress.format")

            let levelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
            levelPopup.target = owner
            levelPopup.action = #selector(CompressDialogController.compressionSettingsChanged(_:))
            levelPopup.setAccessibilityIdentifier("compress.level")

            let methodPopup = NSPopUpButton(frame: .zero, pullsDown: false)
            methodPopup.target = owner
            methodPopup.action = #selector(CompressDialogController.methodChanged(_:))
            methodPopup.setAccessibilityIdentifier("compress.method")

            let dictionaryPopup = NSPopUpButton(frame: .zero, pullsDown: false)
            dictionaryPopup.target = owner
            dictionaryPopup.action = #selector(CompressDialogController.compressionSettingsChanged(_:))
            dictionaryPopup.setAccessibilityIdentifier("compress.dictionary")

            let wordPopup = NSPopUpButton(frame: .zero, pullsDown: false)
            wordPopup.target = owner
            wordPopup.action = #selector(CompressDialogController.compressionSettingsChanged(_:))
            wordPopup.setAccessibilityIdentifier("compress.word")

            let solidPopup = NSPopUpButton(frame: .zero, pullsDown: false)
            CompressDialogController.solidOptions.forEach { solidPopup.addItem(withTitle: $0.title) }
            solidPopup.target = owner
            solidPopup.action = #selector(CompressDialogController.compressionSettingsChanged(_:))
            solidPopup.setAccessibilityIdentifier("compress.solid")

            let threadField = NSComboBox(frame: NSRect(x: 0, y: 0, width: 140, height: 26))
            threadField.usesDataSource = false
            threadField.completes = false
            threadField.isEditable = true
            threadField.addItems(withObjectValues: ["Auto"] + CompressDialogController.threadChoices())
            threadField.stringValue = initialState.threadText
            threadField.delegate = owner
            threadField.setAccessibilityIdentifier("compress.threads")

            let threadInfoLabel = CompressDialogLayout.makeInfoLabel(minWidth: 52)
            let threadControl = NSStackView(views: [threadField, threadInfoLabel])
            threadControl.orientation = .horizontal
            threadControl.alignment = .centerY
            threadControl.spacing = 6

            let memoryUsageOptions = CompressDialogController.makeMemoryUsageOptions(preferredSpec: initialState.memoryUsageSpec)
            let memoryUsagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
            CompressDialogController.populateMemoryUsagePopup(memoryUsagePopup,
                                                              with: memoryUsageOptions,
                                                              selectedSpec: initialState.memoryUsageSpec)
            memoryUsagePopup.target = owner
            memoryUsagePopup.action = #selector(CompressDialogController.compressionSettingsChanged(_:))
            memoryUsagePopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
            memoryUsagePopup.setAccessibilityIdentifier("compress.memoryUsage")

            let memoryLabelTexts = [
                SZL10n.string("benchmark.memoryUsage"),
                SZL10n.string("compress.memoryCompressing"),
                SZL10n.string("compress.memoryDecompressing"),
            ]
            let memoryLabelFont = NSFont.systemFont(ofSize: 12)
            let memoryLabelWidth = ceil(memoryLabelTexts.map {
                ($0 as NSString).size(withAttributes: [.font: memoryLabelFont]).width
            }.max() ?? 152) + 4

            let memoryUsageRow = CompressDialogLayout.makeFormRow(label: SZL10n.string("benchmark.memoryUsage"),
                                                                  control: memoryUsagePopup,
                                                                  labelWidth: memoryLabelWidth)

            let compressionMemoryLabel = CompressDialogLayout.makeInfoLabel(minWidth: 132)
            let decompressionMemoryLabel = CompressDialogLayout.makeInfoLabel(minWidth: 132)
            let compressionMemoryRow = CompressDialogLayout.makeFormRow(label: SZL10n.string("compress.memoryCompressing"),
                                                                        control: compressionMemoryLabel,
                                                                        labelWidth: memoryLabelWidth)
            let decompressionMemoryRow = CompressDialogLayout.makeFormRow(label: SZL10n.string("compress.memoryDecompressing"),
                                                                          control: decompressionMemoryLabel,
                                                                          labelWidth: memoryLabelWidth)

            let splitVolumesField = NSComboBox(frame: NSRect(x: 0, y: 0, width: 180, height: 26))
            splitVolumesField.usesDataSource = false
            splitVolumesField.completes = false
            splitVolumesField.isEditable = true
            splitVolumesField.addItems(withObjectValues: CompressDialogController.splitVolumePresets)
            splitVolumesField.stringValue = initialState.splitVolumes
            splitVolumesField.setAccessibilityIdentifier("compress.splitVolumes")

            let parametersField = NSTextField(frame: NSRect(x: 0, y: 0, width: 180, height: 24))
            parametersField.stringValue = initialState.parameters
            parametersField.placeholderString = "e.g. d=64m fb=273"
            parametersField.setAccessibilityIdentifier("compress.parameters")

            let updateModePopup = NSPopUpButton(frame: .zero, pullsDown: false)
            CompressDialogController.updateModeOptions.forEach { updateModePopup.addItem(withTitle: $0.title) }
            if let selectedIndex = CompressDialogController.updateModeOptions.firstIndex(where: { $0.value == initialState.updateMode }) {
                updateModePopup.selectItem(at: selectedIndex)
            }
            updateModePopup.setAccessibilityIdentifier("compress.updateMode")

            let pathModePopup = NSPopUpButton(frame: .zero, pullsDown: false)
            CompressDialogController.pathModeOptions.forEach { pathModePopup.addItem(withTitle: $0.title) }
            if let selectedIndex = CompressDialogController.pathModeOptions.firstIndex(where: { $0.value == initialState.pathMode }) {
                pathModePopup.selectItem(at: selectedIndex)
            }
            pathModePopup.setAccessibilityIdentifier("compress.pathMode")

            let openSharedCheckbox = NSButton(checkboxWithTitle: SZL10n.string("compress.compressShared"), target: nil, action: nil)
            openSharedCheckbox.state = initialState.openSharedFiles ? .on : .off
            openSharedCheckbox.setAccessibilityIdentifier("compress.openShared")

            let deleteAfterCheckbox = NSButton(checkboxWithTitle: SZL10n.string("compress.deleteAfter"), target: nil, action: nil)
            deleteAfterCheckbox.state = initialState.deleteAfterCompression ? .on : .off
            deleteAfterCheckbox.setAccessibilityIdentifier("compress.deleteAfter")

            let createSFXCheckbox = NSButton(checkboxWithTitle: SZL10n.string("compress.createSFX"),
                                             target: owner,
                                             action: #selector(CompressDialogController.createSFXToggled(_:)))
            createSFXCheckbox.state = initialState.createSFX ? .on : .off
            createSFXCheckbox.setAccessibilityIdentifier("compress.createSFX")

            let excludeMacResourceFilesCheckbox = NSButton(checkboxWithTitle: SZL10n.string("app.compress.excludeMacResources"),
                                                           target: nil,
                                                           action: nil)
            excludeMacResourceFilesCheckbox.state = initialState.excludeMacResourceFiles ? .on : .off
            excludeMacResourceFilesCheckbox.setAccessibilityIdentifier("compress.excludeMacResources")

            let excludeOfficeLockFilesCheckbox = NSButton(checkboxWithTitle: SZL10n.string("app.compress.excludeOfficeLockFiles"),
                                                          target: nil,
                                                          action: nil)
            excludeOfficeLockFilesCheckbox.state = initialState.excludeOfficeLockFiles ? .on : .off
            excludeOfficeLockFilesCheckbox.toolTip = SZL10n.string("app.compress.excludeOfficeLockFilesHelp")
            excludeOfficeLockFilesCheckbox.setAccessibilityIdentifier("compress.excludeOfficeLockFiles")

            let advancedOptionsButton = NSButton(title: SZL10n.string("compress.options"),
                                                 target: owner,
                                                 action: #selector(CompressDialogController.showAdvancedOptions(_:)))
            advancedOptionsButton.bezelStyle = .rounded
            advancedOptionsButton.setContentHuggingPriority(.required, for: .horizontal)
            advancedOptionsButton.setContentCompressionResistancePriority(.required, for: .horizontal)
            advancedOptionsButton.setAccessibilityIdentifier("compress.advancedOptions")

            let advancedOptionsSummaryLabel = NSTextField(labelWithString: "")
            advancedOptionsSummaryLabel.font = .systemFont(ofSize: 11)
            advancedOptionsSummaryLabel.textColor = .secondaryLabelColor
            advancedOptionsSummaryLabel.lineBreakMode = .byTruncatingTail
            advancedOptionsSummaryLabel.cell?.wraps = false
            advancedOptionsSummaryLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
            advancedOptionsSummaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            let advancedOptionsRow = NSStackView(views: [advancedOptionsButton, advancedOptionsSummaryLabel])
            advancedOptionsRow.orientation = .horizontal
            advancedOptionsRow.alignment = .centerY
            advancedOptionsRow.spacing = 8
            advancedOptionsRow.distribution = .fill

            let encryptionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
            encryptionPopup.setAccessibilityIdentifier("compress.encryption")

            let passwordField = SZPasswordField(value: initialState.password,
                                                placeholder: SZL10n.string("app.optional"),
                                                accessibilityIdentifier: "compress.password")
            let confirmationField = SZPasswordField(value: initialState.confirmation,
                                                    placeholder: SZL10n.string("app.reenterPassword"),
                                                    accessibilityIdentifier: "compress.confirmPassword")
            for field in [passwordField, confirmationField] {
                field.widthAnchor.constraint(equalToConstant: 220).isActive = true
                field.heightAnchor.constraint(equalToConstant: 24).isActive = true
                field.textDidChangeHandler = { _ in onPasswordChange() }
            }

            let showPasswordCheckbox = NSButton(checkboxWithTitle: SZL10n.string("password.showPassword"),
                                                target: owner,
                                                action: #selector(CompressDialogController.showPasswordToggled(_:)))
            showPasswordCheckbox.state = initialState.showPassword ? .on : .off
            showPasswordCheckbox.setAccessibilityIdentifier("compress.showPassword")

            let encryptNamesCheckbox = NSButton(checkboxWithTitle: SZL10n.string("compress.encryptFileNames"),
                                                target: nil,
                                                action: nil)
            encryptNamesCheckbox.state = initialState.encryptNames ? .on : .off
            encryptNamesCheckbox.setAccessibilityIdentifier("compress.encryptNames")

            let dictionaryLabel = NSTextField(labelWithString: SZL10n.string("compress.dictionarySize"))
            let wordLabel = NSTextField(labelWithString: SZL10n.string("compress.wordSize"))

            let archivePathRow = CompressDialogLayout.makePathRow(label: SZL10n.string("compress.archive"),
                                                                  pathField: archivePathField,
                                                                  browseButton: browseButton)

            let leftColumn = CompressDialogLayout.makeColumn(rows: [
                CompressDialogLayout.makeFormRow(label: SZL10n.string("compress.archiveFormat"), control: formatPopup),
                CompressDialogLayout.makeFormRow(label: SZL10n.string("compress.compressionLevel"), control: levelPopup),
                CompressDialogLayout.makeFormRow(label: SZL10n.string("compress.compressionMethod"), control: methodPopup),
                CompressDialogLayout.makeFormRow(labelField: dictionaryLabel, control: dictionaryPopup),
                CompressDialogLayout.makeFormRow(labelField: wordLabel, control: wordPopup),
                CompressDialogLayout.makeFormRow(label: SZL10n.string("compress.solidBlockSize"), control: solidPopup),
                CompressDialogLayout.makeFormRow(label: SZL10n.string("compress.cpuThreads"), control: threadControl),
                memoryUsageRow,
                compressionMemoryRow,
                decompressionMemoryRow,
                CompressDialogLayout.makeFormRow(label: SZL10n.string("split.toVolumesBytes"), control: splitVolumesField),
                CompressDialogLayout.makeFormRow(label: SZL10n.string("compress.parameters"), control: parametersField),
            ])

            let optionsColumn = CompressDialogLayout.makeTitledSection(title: SZL10n.string("compress.options"), rows: [
                createSFXCheckbox,
                excludeMacResourceFilesCheckbox,
                excludeOfficeLockFilesCheckbox,
                openSharedCheckbox,
                deleteAfterCheckbox,
                advancedOptionsRow,
            ])

            let encryptionColumn = CompressDialogLayout.makeTitledSection(title: SZL10n.string("compress.encryption"), rows: [
                CompressDialogLayout.makeFormRow(label: SZL10n.string("password.password") + ":", control: passwordField),
                CompressDialogLayout.makeFormRow(label: SZL10n.string("password.reenterPassword"), control: confirmationField),
                showPasswordCheckbox,
                CompressDialogLayout.makeFormRow(label: SZL10n.string("compress.encryptionMethod"), control: encryptionPopup),
                encryptNamesCheckbox,
            ])

            let rightColumn = CompressDialogLayout.makeColumn(rows: [
                CompressDialogLayout.makeFormRow(label: SZL10n.string("compress.updateMode"), control: updateModePopup),
                CompressDialogLayout.makeFormRow(label: SZL10n.string("extract.pathMode"), control: pathModePopup),
                optionsColumn,
                encryptionColumn,
            ])

            leftColumn.widthAnchor.constraint(equalToConstant: CompressDialogController.leftColumnWidth).isActive = true
            rightColumn.widthAnchor.constraint(equalToConstant: CompressDialogController.rightColumnWidth).isActive = true
            optionsColumn.widthAnchor.constraint(equalTo: rightColumn.widthAnchor).isActive = true
            encryptionColumn.widthAnchor.constraint(equalTo: rightColumn.widthAnchor).isActive = true

            let columns = NSStackView(views: [leftColumn, rightColumn])
            columns.orientation = .horizontal
            columns.alignment = .top
            columns.distribution = .fill
            columns.spacing = CompressDialogController.columnSpacing
            columns.widthAnchor.constraint(equalToConstant: CompressDialogController.leftColumnWidth + CompressDialogController.rightColumnWidth + CompressDialogController.columnSpacing).isActive = true

            let accessoryView = NSStackView(views: [archivePathRow, columns])
            accessoryView.orientation = .vertical
            accessoryView.alignment = .leading
            accessoryView.spacing = 16
            accessoryView.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
            accessoryView.widthAnchor.constraint(equalToConstant: CompressDialogController.leftColumnWidth + CompressDialogController.rightColumnWidth + CompressDialogController.columnSpacing).isActive = true

            self.accessoryView = accessoryView
            controls = CompressDialogControls(archivePathField: archivePathField,
                                              browseButton: browseButton,
                                              formatPopup: formatPopup,
                                              levelPopup: levelPopup,
                                              methodPopup: methodPopup,
                                              dictionaryPopup: dictionaryPopup,
                                              wordPopup: wordPopup,
                                              solidPopup: solidPopup,
                                              threadField: threadField,
                                              memoryUsagePopup: memoryUsagePopup,
                                              splitVolumesField: splitVolumesField,
                                              parametersField: parametersField,
                                              updateModePopup: updateModePopup,
                                              pathModePopup: pathModePopup,
                                              encryptionPopup: encryptionPopup,
                                              encryptNamesCheckbox: encryptNamesCheckbox,
                                              createSFXCheckbox: createSFXCheckbox,
                                              excludeMacResourceFilesCheckbox: excludeMacResourceFilesCheckbox,
                                              excludeOfficeLockFilesCheckbox: excludeOfficeLockFilesCheckbox,
                                              openSharedCheckbox: openSharedCheckbox,
                                              deleteAfterCheckbox: deleteAfterCheckbox,
                                              dictionaryLabel: dictionaryLabel,
                                              wordLabel: wordLabel,
                                              threadInfoLabel: threadInfoLabel,
                                              compressionMemoryLabel: compressionMemoryLabel,
                                              decompressionMemoryLabel: decompressionMemoryLabel,
                                              memoryUsageRow: memoryUsageRow,
                                              compressionMemoryRow: compressionMemoryRow,
                                              decompressionMemoryRow: decompressionMemoryRow,
                                              passwordField: passwordField,
                                              confirmationField: confirmationField,
                                              showPasswordCheckbox: showPasswordCheckbox,
                                              advancedOptionsSummaryLabel: advancedOptionsSummaryLabel)
        }

        func updateStateFromControls(advancedOptions: AdvancedOptionsState) {
            state = CompressDialogState(archivePath: controls.archivePathField.stringValue,
                                        format: selectedFormatOption() ?? state.format,
                                        level: selectedLevelOption()?.levelValue ?? state.level,
                                        method: selectedMethodOption(),
                                        dictionarySize: selectedDictionaryOption()?.value ?? 0,
                                        wordSize: selectedWordOption()?.value ?? 0,
                                        solidMode: selectedSolidOption()?.value ?? state.solidMode,
                                        threadText: CompressDialogController.normalizedThreadText(currentThreadText()),
                                        splitVolumes: controls.splitVolumesField.stringValue,
                                        parameters: controls.parametersField.stringValue,
                                        updateMode: selectedUpdateModeOption()?.value ?? state.updateMode,
                                        pathMode: selectedPathModeOption()?.value ?? state.pathMode,
                                        encryption: selectedEncryptionOption()?.value ?? .none,
                                        password: currentPasswordValue(),
                                        confirmation: currentConfirmationValue(),
                                        encryptNames: controls.encryptNamesCheckbox.state == .on,
                                        createSFX: controls.createSFXCheckbox.state == .on,
                                        excludeMacResourceFiles: controls.excludeMacResourceFilesCheckbox.state == .on,
                                        excludeOfficeLockFiles: controls.excludeOfficeLockFilesCheckbox.state == .on,
                                        memoryUsageSpec: selectedMemoryUsageSpecValue(),
                                        openSharedFiles: controls.openSharedCheckbox.state == .on,
                                        deleteAfterCompression: controls.deleteAfterCheckbox.state == .on,
                                        advancedOptions: advancedOptions,
                                        showPassword: controls.showPasswordCheckbox.state == .on)
        }

        func currentPasswordValue() -> String {
            controls.passwordField.stringValue
        }

        func currentConfirmationValue() -> String {
            controls.confirmationField.stringValue
        }

        func currentThreadText() -> String {
            if controls.threadField.indexOfSelectedItem == 0 {
                return "Auto"
            }

            if controls.threadField.indexOfSelectedItem >= 0,
               controls.threadField.indexOfSelectedItem < controls.threadField.numberOfItems,
               let selectedItem = controls.threadField.itemObjectValue(at: controls.threadField.indexOfSelectedItem) as? String
            {
                return selectedItem
            }

            return controls.threadField.stringValue
        }

        func selectedFormatOption() -> FormatOption? {
            let index = controls.formatPopup.indexOfSelectedItem
            guard availableFormats.indices.contains(index) else { return availableFormats.first }
            return availableFormats[index]
        }

        func selectedLevelOption() -> LevelOption? {
            guard let format = selectedFormatOption() else {
                return nil
            }
            let levelOptions = selectedMethodOption()?.levelOptions ?? format.levelOptions
            let index = controls.levelPopup.indexOfSelectedItem
            guard levelOptions.indices.contains(index) else {
                return levelOptions.first
            }
            return levelOptions[index]
        }

        func selectedMethodOption() -> MethodOption? {
            guard let format = selectedFormatOption(),
                  !format.methods.isEmpty
            else {
                return nil
            }
            let index = controls.methodPopup.indexOfSelectedItem
            guard format.methods.indices.contains(index) else {
                return format.methods.first
            }
            return format.methods[index]
        }

        func selectedDictionaryOption() -> Option<UInt64>? {
            guard let method = selectedMethodOption(),
                  !method.dictionaryOptions.isEmpty
            else {
                return nil
            }
            let index = controls.dictionaryPopup.indexOfSelectedItem
            guard method.dictionaryOptions.indices.contains(index) else {
                return method.dictionaryOptions.first
            }
            return method.dictionaryOptions[index]
        }

        func selectedWordOption() -> Option<UInt32>? {
            guard let method = selectedMethodOption(),
                  !method.wordOptions.isEmpty
            else {
                return nil
            }
            let index = controls.wordPopup.indexOfSelectedItem
            guard method.wordOptions.indices.contains(index) else {
                return method.wordOptions.first
            }
            return method.wordOptions[index]
        }

        func selectedSolidOption() -> Option<Bool>? {
            let index = controls.solidPopup.indexOfSelectedItem
            guard CompressDialogController.solidOptions.indices.contains(index) else {
                return CompressDialogController.solidOptions.first
            }
            return CompressDialogController.solidOptions[index]
        }

        func selectedUpdateModeOption() -> Option<SZCompressionUpdateMode>? {
            let index = controls.updateModePopup.indexOfSelectedItem
            guard CompressDialogController.updateModeOptions.indices.contains(index) else {
                return CompressDialogController.updateModeOptions.first
            }
            return CompressDialogController.updateModeOptions[index]
        }

        func selectedPathModeOption() -> Option<SZCompressionPathMode>? {
            let index = controls.pathModePopup.indexOfSelectedItem
            guard CompressDialogController.pathModeOptions.indices.contains(index) else {
                return CompressDialogController.pathModeOptions.first
            }
            return CompressDialogController.pathModeOptions[index]
        }

        func selectedEncryptionOption() -> Option<SZEncryptionMethod>? {
            guard let format = selectedFormatOption(),
                  !format.encryptionOptions.isEmpty
            else {
                return nil
            }
            let index = controls.encryptionPopup.indexOfSelectedItem
            guard format.encryptionOptions.indices.contains(index) else {
                return format.encryptionOptions.first
            }
            return format.encryptionOptions[index]
        }

        func selectedMemoryUsageSpecValue() -> String {
            guard let selectedItem = controls.memoryUsagePopup.selectedItem,
                  let spec = selectedItem.representedObject as? String
            else {
                return ""
            }
            return CompressDialogController.normalizedMemoryUsageSpec(spec)
        }

        var archivePath: String {
            controls.archivePathField.stringValue
        }

        func setArchivePath(_ archivePath: String) {
            controls.archivePathField.stringValue = archivePath
        }

        func setBrowseButtonTarget(_ target: AnyObject?,
                                   action: Selector?)
        {
            controls.browseButton.target = target
            controls.browseButton.action = action
        }

        func setParameters(_ parameters: String) {
            controls.parametersField.stringValue = parameters
        }

        func setAdvancedOptionsSummary(_ summary: String) {
            controls.advancedOptionsSummaryLabel.stringValue = summary
        }

        func selectSolidMode(_ solidMode: Bool) {
            Self.selectOption(CompressDialogController.solidOptions,
                              selectedValue: solidMode,
                              on: controls.solidPopup)
        }

        func isThreadField(_ object: Any?) -> Bool {
            guard let comboBox = object as? NSComboBox else {
                return false
            }
            return comboBox === controls.threadField
        }

        func updatePasswordVisibilityUI() {
            let showsPassword = controls.showPasswordCheckbox.state == .on
            controls.passwordField.showsPassword = showsPassword
            controls.confirmationField.showsPassword = showsPassword
        }

        @discardableResult
        func reloadFormatDependentControls(preferredLevel: Int?,
                                           preferredMethodName: String?,
                                           preferredDictionarySize: UInt64?,
                                           preferredWordSize: UInt32?,
                                           preferredEncryption: SZEncryptionMethod?,
                                           dependencies: CompressDialogContentRefreshDependencies) -> Bool
        {
            guard let format = selectedFormatOption() else { return false }

            if format.methods.isEmpty {
                Self.populate(controls.methodPopup, with: ["Default"])
                controls.methodPopup.selectItem(at: 0)
            } else {
                Self.populate(controls.methodPopup, with: format.methods.map(\.title))
                if let preferredMethodName,
                   let selectedIndex = format.methods.firstIndex(where: { $0.methodName == preferredMethodName })
                {
                    controls.methodPopup.selectItem(at: selectedIndex)
                } else {
                    controls.methodPopup.selectItem(at: 0)
                }
            }

            let levelOptions = dependencies.levelOptions(format, selectedMethodOption())
            Self.populate(controls.levelPopup, with: levelOptions.map(\.title))
            if let preferredLevel,
               let selectedIndex = levelOptions.firstIndex(where: { $0.levelValue == preferredLevel })
            {
                controls.levelPopup.selectItem(at: selectedIndex)
            } else {
                controls.levelPopup.selectItem(at: dependencies.defaultLevelIndex(format, selectedMethodOption()))
            }

            if format.encryptionOptions.isEmpty {
                Self.populate(controls.encryptionPopup, with: ["Not available"])
                controls.encryptionPopup.selectItem(at: 0)
            } else {
                Self.populate(controls.encryptionPopup, with: format.encryptionOptions.map(\.title))
                if let preferredEncryption,
                   let selectedIndex = format.encryptionOptions.firstIndex(where: { $0.value == preferredEncryption })
                {
                    controls.encryptionPopup.selectItem(at: selectedIndex)
                } else {
                    controls.encryptionPopup.selectItem(at: 0)
                }
            }

            return reloadMethodDependentControls(preferredDictionarySize: preferredDictionarySize,
                                                 preferredWordSize: preferredWordSize,
                                                 dependencies: dependencies)
        }

        @discardableResult
        func reloadMethodDependentControls(preferredDictionarySize: UInt64?,
                                           preferredWordSize: UInt32?,
                                           dependencies: CompressDialogContentRefreshDependencies) -> Bool
        {
            let method = selectedMethodOption()
            controls.dictionaryLabel.stringValue = method?.dictionaryLabel ?? SZL10n.string("compress.dictionarySize")
            controls.wordLabel.stringValue = method?.wordLabel ?? SZL10n.string("compress.wordSize")

            let dictionaryOptions = method?.dictionaryOptions ?? []
            if dictionaryOptions.isEmpty {
                Self.populate(controls.dictionaryPopup, with: ["Auto"])
                controls.dictionaryPopup.selectItem(at: 0)
            } else {
                Self.populate(controls.dictionaryPopup, with: dictionaryOptions.map(\.title))
                if let preferredDictionarySize,
                   let selectedIndex = dictionaryOptions.firstIndex(where: { $0.value == preferredDictionarySize })
                {
                    controls.dictionaryPopup.selectItem(at: selectedIndex)
                } else {
                    controls.dictionaryPopup.selectItem(at: 0)
                }
            }

            let wordOptions = method?.wordOptions ?? []
            if wordOptions.isEmpty {
                Self.populate(controls.wordPopup, with: ["Auto"])
                controls.wordPopup.selectItem(at: 0)
            } else {
                Self.populate(controls.wordPopup, with: wordOptions.map(\.title))
                if let preferredWordSize,
                   let selectedIndex = wordOptions.firstIndex(where: { $0.value == preferredWordSize })
                {
                    controls.wordPopup.selectItem(at: selectedIndex)
                } else {
                    controls.wordPopup.selectItem(at: 0)
                }
            }

            return refreshOptionAvailability(dependencies: dependencies)
        }

        @discardableResult
        func refreshOptionAvailability(dependencies: CompressDialogContentRefreshDependencies) -> Bool {
            guard let format = selectedFormatOption() else { return false }

            let method = selectedMethodOption()
            let level = selectedLevelOption()?.levelValue ?? dependencies.defaultLevel(format.codecName, method?.methodName)
            let selectedDictionarySize = selectedDictionaryOption()?.value ?? 0
            let selectedWordSize = selectedWordOption()?.value ?? 0
            let currentThreadText = currentThreadText()
            let memoryUsageSpec = selectedMemoryUsageSpecValue()
            let estimate = dependencies.compressionResourceEstimate(format,
                                                                    method,
                                                                    level,
                                                                    selectedDictionarySize,
                                                                    currentThreadText,
                                                                    memoryUsageSpec)

            refreshDynamicCompressionControlTitles(for: format,
                                                   method: method,
                                                   selectedDictionarySize: selectedDictionarySize,
                                                   selectedWordSize: selectedWordSize,
                                                   currentThreadText: currentThreadText,
                                                   estimate: estimate)

            controls.levelPopup.isEnabled = dependencies.levelOptions(format, method).count > 1
            controls.methodPopup.isEnabled = !format.methods.isEmpty
            controls.dictionaryPopup.isEnabled = !(method?.dictionaryOptions.isEmpty ?? true)
            controls.wordPopup.isEnabled = !(method?.wordOptions.isEmpty ?? true)
            controls.solidPopup.isEnabled = format.supportsSolid
            controls.threadField.isEnabled = format.supportsThreads

            if !format.supportsSolid {
                controls.solidPopup.selectItem(at: 0)
            }
            if !format.supportsThreads {
                controls.threadField.stringValue = "Auto"
            }

            let createSFXWasEnabled = controls.createSFXCheckbox.state == .on
            let canCreateSFX = dependencies.supportsSFX(format, method)
            controls.createSFXCheckbox.isEnabled = canCreateSFX
            if !canCreateSFX {
                controls.createSFXCheckbox.state = .off
            }

            let createSFX = effectiveCreateSFXState(for: format,
                                                    method: method,
                                                    supportsSFX: dependencies.supportsSFX)
            controls.splitVolumesField.isEnabled = !createSFX
            if createSFX {
                controls.splitVolumesField.stringValue = ""
            }

            let encryptionAvailable = !format.encryptionOptions.isEmpty
            controls.encryptionPopup.isEnabled = encryptionAvailable && format.encryptionOptions.count > 1
            controls.passwordField.isEnabled = encryptionAvailable
            controls.confirmationField.isEnabled = encryptionAvailable
            controls.showPasswordCheckbox.isEnabled = encryptionAvailable

            let canEncryptNames = encryptionAvailable && format.supportsEncryptFileNames && !currentPasswordValue().isEmpty
            controls.encryptNamesCheckbox.isEnabled = canEncryptNames
            if !canEncryptNames {
                controls.encryptNamesCheckbox.state = .off
            }

            refreshCompressionResourceSummary(for: format, estimate: estimate)
            dependencies.refreshAdvancedOptionsSummary()
            return createSFXWasEnabled != createSFX
        }

        func refreshCompressionEstimateSummary(dependencies: CompressDialogContentRefreshDependencies) {
            guard let format = selectedFormatOption() else { return }

            let method = selectedMethodOption()
            let level = selectedLevelOption()?.levelValue ?? dependencies.defaultLevel(format.codecName, method?.methodName)
            let estimate = dependencies.compressionResourceEstimate(format,
                                                                    method,
                                                                    level,
                                                                    selectedDictionaryOption()?.value ?? 0,
                                                                    currentThreadText(),
                                                                    selectedMemoryUsageSpecValue())
            refreshCompressionResourceSummary(for: format, estimate: estimate)
        }

        func effectiveCreateSFXState(for format: FormatOption? = nil,
                                     method: MethodOption? = nil,
                                     supportsSFX: (FormatOption?, MethodOption?) -> Bool) -> Bool
        {
            guard controls.createSFXCheckbox.state == .on else {
                return false
            }
            return supportsSFX(format ?? selectedFormatOption(), method ?? selectedMethodOption())
        }

        private func refreshCompressionResourceSummary(for format: FormatOption,
                                                       estimate: CompressionResourceEstimate)
        {
            controls.threadInfoLabel.stringValue = Self.cpuThreadSummary(forThreadedFormat: format.supportsThreads)
            controls.threadInfoLabel.isHidden = !format.supportsThreads
            let showsMemoryUsageControl = estimate.memoryUsageLimit != nil
            controls.memoryUsageRow.isHidden = !showsMemoryUsageControl
            controls.memoryUsagePopup.isEnabled = showsMemoryUsageControl && controls.memoryUsagePopup.numberOfItems > 1

            let showsMemoryUsage = estimate.compressionMemory != nil || estimate.decompressionMemory != nil
            controls.compressionMemoryRow.isHidden = !showsMemoryUsage
            controls.decompressionMemoryRow.isHidden = !showsMemoryUsage
            controls.compressionMemoryLabel.stringValue = estimate.compressionMemory.map(CompressDialogController.memoryUsageText(for:)) ?? "?"
            controls.decompressionMemoryLabel.stringValue = estimate.decompressionMemory.map(CompressDialogController.memoryUsageText(for:)) ?? "?"

            let exceedsMemoryLimit = {
                guard let compressionMemory = estimate.compressionMemory,
                      let memoryUsageLimit = estimate.memoryUsageLimit
                else {
                    return false
                }
                return compressionMemory > memoryUsageLimit
            }()
            controls.compressionMemoryLabel.textColor = exceedsMemoryLimit ? .systemRed : .secondaryLabelColor
            controls.decompressionMemoryLabel.textColor = .secondaryLabelColor
        }

        private func refreshDynamicCompressionControlTitles(for format: FormatOption,
                                                            method: MethodOption?,
                                                            selectedDictionarySize: UInt64,
                                                            selectedWordSize: UInt32,
                                                            currentThreadText: String,
                                                            estimate: CompressionResourceEstimate)
        {
            if let method, !method.dictionaryOptions.isEmpty {
                let titles = method.dictionaryOptions.enumerated().map { index, option in
                    if index == 0 {
                        return Self.autoDictionaryTitle(for: estimate.resolvedDictionarySize,
                                                        fallback: option.title)
                    }
                    return option.title
                }
                Self.updatePopupTitlesIfNeeded(controls.dictionaryPopup, titles: titles)
                Self.selectOption(method.dictionaryOptions,
                                  selectedValue: selectedDictionarySize,
                                  on: controls.dictionaryPopup)
            } else {
                Self.updatePopupTitlesIfNeeded(controls.dictionaryPopup, titles: ["Auto"])
                controls.dictionaryPopup.selectItem(at: 0)
            }

            if let method, !method.wordOptions.isEmpty {
                let titles = method.wordOptions.enumerated().map { index, option in
                    if index == 0 {
                        return Self.autoWordTitle(for: estimate.resolvedWordSize,
                                                  fallback: option.title)
                    }
                    return option.title
                }
                Self.updatePopupTitlesIfNeeded(controls.wordPopup, titles: titles)
                Self.selectOption(method.wordOptions,
                                  selectedValue: selectedWordSize,
                                  on: controls.wordPopup)
            } else {
                Self.updatePopupTitlesIfNeeded(controls.wordPopup, titles: ["Auto"])
                controls.wordPopup.selectItem(at: 0)
            }

            guard format.supportsThreads else {
                return
            }

            let items = [Self.autoThreadTitle(for: estimate.resolvedNumThreads)] + CompressDialogController.threadChoices()
            Self.updateComboBoxItemsIfNeeded(controls.threadField, items: items)

            let normalizedThreadText = CompressDialogController.normalizedThreadText(currentThreadText)
            if normalizedThreadText == "Auto" {
                if controls.threadField.indexOfSelectedItem != 0 || controls.threadField.stringValue != items[0] {
                    controls.threadField.selectItem(at: 0)
                }
            } else if let itemIndex = items.firstIndex(of: normalizedThreadText) {
                if controls.threadField.indexOfSelectedItem != itemIndex || controls.threadField.stringValue != normalizedThreadText {
                    controls.threadField.selectItem(at: itemIndex)
                }
            } else if controls.threadField.stringValue != normalizedThreadText {
                controls.threadField.stringValue = normalizedThreadText
            }
        }

        private static func populate(_ popup: NSPopUpButton,
                                     with titles: [String])
        {
            popup.removeAllItems()
            popup.addItems(withTitles: titles)
        }

        private static func selectOption<Value: Equatable>(_ options: [Option<Value>],
                                                           selectedValue: Value,
                                                           on popup: NSPopUpButton)
        {
            if let selectedIndex = options.firstIndex(where: { $0.value == selectedValue }) {
                popup.selectItem(at: selectedIndex)
            } else {
                popup.selectItem(at: 0)
            }
        }

        private static func updatePopupTitlesIfNeeded(_ popup: NSPopUpButton,
                                                      titles: [String])
        {
            if popup.itemTitles != titles {
                populate(popup, with: titles)
            }
        }

        private static func updateComboBoxItemsIfNeeded(_ comboBox: NSComboBox,
                                                        items: [String])
        {
            if comboBoxItems(from: comboBox) != items {
                comboBox.removeAllItems()
                comboBox.addItems(withObjectValues: items)
            }
        }

        private static func comboBoxItems(from comboBox: NSComboBox) -> [String] {
            (0 ..< comboBox.numberOfItems).compactMap { comboBox.itemObjectValue(at: $0) as? String }
        }

        private static func cpuThreadCounts() -> (available: Int, total: Int) {
            let processInfo = ProcessInfo.processInfo
            return (available: max(1, processInfo.activeProcessorCount),
                    total: max(1, processInfo.processorCount))
        }

        private static func cpuThreadSummary(forThreadedFormat isThreaded: Bool) -> String {
            guard isThreaded else {
                return ""
            }

            let counts = cpuThreadCounts()
            if counts.available == counts.total {
                return "/ \(counts.total)"
            }
            return "/ \(counts.available) / \(counts.total)"
        }

        private static func autoDictionaryTitle(for bytes: UInt64?,
                                                fallback: String) -> String
        {
            guard let bytes, bytes > 0 else {
                return fallback
            }
            return "Auto: \(CompressDialogController.memoryUsageText(for: bytes))"
        }

        private static func autoWordTitle(for value: UInt32?,
                                          fallback: String) -> String
        {
            guard let value, value > 0 else {
                return fallback
            }
            return "Auto: \(value)"
        }

        private static func autoThreadTitle(for value: UInt32?) -> String {
            guard let value, value > 0 else {
                return "Auto"
            }
            return "Auto: \(value)"
        }
    }
}
