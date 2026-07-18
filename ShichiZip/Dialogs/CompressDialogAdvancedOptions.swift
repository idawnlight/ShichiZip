import Cocoa

@MainActor
extension CompressDialogController {
    private static let knownTimePrecisionValues: [SZCompressionTimePrecision] = [
        SZCompressionTimePrecision(rawValue: 0)!,
        SZCompressionTimePrecision(rawValue: 1)!,
        SZCompressionTimePrecision(rawValue: 2)!,
        SZCompressionTimePrecision(rawValue: 3)!,
    ]

    func advancedOptionsSummary(for state: AdvancedOptionsState,
                                capabilities: AdvancedOptionsCapabilities) -> String
    {
        var parts: [String] = []

        if state.timePrecision.isSet {
            parts.append("tp\(state.timePrecision.value.rawValue)")
        }

        appendBoolPairSummary("tm",
                              state: state.storeModificationTime,
                              to: &parts)
        appendBoolPairSummary("tc",
                              state: state.storeCreationTime,
                              to: &parts)
        appendBoolPairSummary("ta",
                              state: state.storeAccessTime,
                              to: &parts)
        appendBoolPairSummary("-stl",
                              state: state.setArchiveTimeToLatestFile,
                              to: &parts)

        if capabilities.supportsSymbolicLinks, state.storeSymbolicLinks {
            parts.append("SL")
        }
        if capabilities.supportsHardLinks, state.storeHardLinks {
            parts.append("HL")
        }
        if capabilities.supportsAlternateDataStreams, state.storeAlternateDataStreams {
            parts.append("AS")
        }
        if capabilities.supportsFileSecurity, state.storeFileSecurity {
            parts.append("Sec")
        }

        return parts.joined(separator: " ")
    }

    private func appendBoolPairSummary(_ name: String,
                                       state: AdvancedBoolPairState,
                                       to parts: inout [String])
    {
        guard state.isSet else {
            return
        }
        parts.append(state.value ? name : "\(name)-")
    }

    func defaultAdvancedOptionsState(for format: FormatOption,
                                     methodName: String?) -> AdvancedOptionsState
    {
        let capabilities = baseAdvancedOptionsCapabilities(for: format,
                                                           methodName: methodName)
        return AdvancedOptionsState(storeSymbolicLinks: false,
                                    storeHardLinks: false,
                                    storeAlternateDataStreams: false,
                                    storeFileSecurity: false,
                                    preserveSourceAccessTime: false,
                                    storeModificationTime: AdvancedBoolPairState(isSet: false,
                                                                                 value: capabilities.supportsModificationTime && capabilities.defaultModificationTime),
                                    storeCreationTime: AdvancedBoolPairState(isSet: false,
                                                                             value: capabilities.supportsCreationTime && capabilities.defaultCreationTime),
                                    storeAccessTime: AdvancedBoolPairState(isSet: false,
                                                                           value: capabilities.supportsAccessTime && capabilities.defaultAccessTime),
                                    setArchiveTimeToLatestFile: AdvancedBoolPairState(isSet: false,
                                                                                      value: false),
                                    timePrecision: AdvancedTimePrecisionState(isSet: false,
                                                                              value: capabilities.defaultTimePrecision))
    }

    func baseAdvancedOptionsCapabilities(for format: FormatOption,
                                         methodName: String?) -> AdvancedOptionsCapabilities
    {
        let info = supportedFormatInfoByName[format.codecName.lowercased()]
        let supportedTimePrecisions = Self.knownTimePrecisionValues.filter { value in
            guard let info,
                  value.rawValue >= 0
            else {
                return false
            }
            let bit = UInt32(value.rawValue)
            return (info.supportedTimePrecisionMask & (UInt32(1) << bit)) != 0
        }

        var defaultTimePrecision = info?.defaultTimePrecision ?? SZCompressionTimePrecision(rawValue: -1)!
        if defaultTimePrecision.rawValue < 0
            || !supportedTimePrecisions.contains(where: { $0.rawValue == defaultTimePrecision.rawValue }),
            let firstSupportedTimePrecision = supportedTimePrecisions.first
        {
            defaultTimePrecision = firstSupportedTimePrecision
        }

        var capabilities = AdvancedOptionsCapabilities(
            supportsSymbolicLinks: info?.supportsSymbolicLinks ?? false,
            supportsHardLinks: info?.supportsHardLinks ?? false,
            supportsAlternateDataStreams: info?.supportsAlternateDataStreams ?? false,
            supportsFileSecurity: info?.supportsFileSecurity ?? false,
            supportsModificationTime: info?.supportsModificationTime ?? true,
            supportsCreationTime: info?.supportsCreationTime ?? false,
            supportsAccessTime: info?.supportsAccessTime ?? false,
            defaultModificationTime: info?.defaultsModificationTime ?? true,
            defaultCreationTime: info?.defaultsCreationTime ?? false,
            defaultAccessTime: info?.defaultsAccessTime ?? false,
            keepsName: info?.keepsName ?? false,
            supportedTimePrecisions: supportedTimePrecisions,
            defaultTimePrecision: defaultTimePrecision,
        )

        if format.codecName.caseInsensitiveCompare("tar") == .orderedSame {
            capabilities.supportsCreationTime = false
            capabilities.defaultCreationTime = false
            let isPosix = methodName?.caseInsensitiveCompare("POSIX") == .orderedSame
            capabilities.supportsAccessTime = capabilities.supportsAccessTime && isPosix
            capabilities.defaultAccessTime = capabilities.defaultAccessTime && isPosix
        }

        return capabilities
    }

    func adjustedAdvancedOptionsCapabilities(_ capabilities: AdvancedOptionsCapabilities,
                                             timePrecision: SZCompressionTimePrecision,
                                             format: FormatOption,
                                             methodName: String?) -> AdvancedOptionsCapabilities
    {
        var adjustedCapabilities = capabilities
        let effectiveTimePrecision = timePrecision.rawValue < 0 ? capabilities.defaultTimePrecision : timePrecision

        if format.codecName.caseInsensitiveCompare("zip") == .orderedSame,
           effectiveTimePrecision.rawValue != 0
        {
            adjustedCapabilities.supportsCreationTime = false
            adjustedCapabilities.defaultCreationTime = false
            adjustedCapabilities.supportsAccessTime = false
            adjustedCapabilities.defaultAccessTime = false
        }

        if format.codecName.caseInsensitiveCompare("tar") == .orderedSame {
            adjustedCapabilities.supportsCreationTime = false
            adjustedCapabilities.defaultCreationTime = false
            let isPosix = methodName?.caseInsensitiveCompare("POSIX") == .orderedSame
            adjustedCapabilities.supportsAccessTime = adjustedCapabilities.supportsAccessTime && isPosix
            adjustedCapabilities.defaultAccessTime = adjustedCapabilities.defaultAccessTime && isPosix
        }

        return adjustedCapabilities
    }

    func effectiveAdvancedOptions(for format: FormatOption,
                                  method: MethodOption?,
                                  baseState: AdvancedOptionsState) -> (state: AdvancedOptionsState, capabilities: AdvancedOptionsCapabilities)
    {
        let baseCapabilities = baseAdvancedOptionsCapabilities(for: format,
                                                               methodName: method?.methodName)
        var state = baseState
        if baseCapabilities.supportedTimePrecisions.isEmpty {
            state.timePrecision = AdvancedTimePrecisionState(isSet: false,
                                                             value: SZCompressionTimePrecision(rawValue: -1)!)
        } else if !baseCapabilities.supportedTimePrecisions.contains(where: { $0.rawValue == state.timePrecision.value.rawValue }) {
            state.timePrecision = AdvancedTimePrecisionState(isSet: false,
                                                             value: baseCapabilities.defaultTimePrecision)
        }

        let capabilities = adjustedAdvancedOptionsCapabilities(baseCapabilities,
                                                               timePrecision: state.timePrecision.value,
                                                               format: format,
                                                               methodName: method?.methodName)

        return (state, capabilities)
    }

    func makeTimePrecisionOptions(for capabilities: AdvancedOptionsCapabilities) -> [Option<SZCompressionTimePrecision>] {
        capabilities.supportedTimePrecisions.map {
            Option(title: timePrecisionTitle(for: $0), value: $0)
        }
    }

    private func timePrecisionTitle(for precision: SZCompressionTimePrecision) -> String {
        switch precision.rawValue {
        case 0:
            "100 \(SZL10n.string("time.nanosecondsAbbrev")) : Windows"
        case 1:
            "1 \(SZL10n.string("time.secondsAbbrev")) : Unix"
        case 2:
            "2 \(SZL10n.string("time.secondsAbbrev")) : DOS"
        case 3:
            "1 \(SZL10n.string("time.nanosecondsAbbrev")) : Linux"
        default:
            "Automatic"
        }
    }

    private func compressionBool1Setting(for value: Bool,
                                         supported: Bool) -> SZCompressionBoolSetting
    {
        guard supported, value else {
            return SZCompressionBoolSetting(rawValue: -1)!
        }
        return SZCompressionBoolSetting(rawValue: 1)!
    }

    private func compressionBoolPairSetting(for state: AdvancedBoolPairState,
                                            supported: Bool) -> SZCompressionBoolSetting
    {
        guard supported, state.isSet else {
            return SZCompressionBoolSetting(rawValue: -1)!
        }
        return SZCompressionBoolSetting(rawValue: state.value ? 1 : 0)!
    }

    func applyAdvancedOptions(_ state: AdvancedOptionsState,
                              capabilities: AdvancedOptionsCapabilities,
                              to settings: SZCompressionSettings)
    {
        settings.storeSymbolicLinks = compressionBool1Setting(for: state.storeSymbolicLinks,
                                                              supported: capabilities.supportsSymbolicLinks)
        settings.storeHardLinks = compressionBool1Setting(for: state.storeHardLinks,
                                                          supported: capabilities.supportsHardLinks)
        settings.storeAlternateDataStreams = compressionBool1Setting(for: state.storeAlternateDataStreams,
                                                                     supported: capabilities.supportsAlternateDataStreams)
        settings.storeFileSecurity = compressionBool1Setting(for: state.storeFileSecurity,
                                                             supported: capabilities.supportsFileSecurity)
        settings.preserveSourceAccessTime = compressionBool1Setting(for: state.preserveSourceAccessTime,
                                                                    supported: true)
        settings.storeModificationTime = compressionBoolPairSetting(for: state.storeModificationTime,
                                                                    supported: capabilities.supportsModificationTime)
        settings.storeCreationTime = compressionBoolPairSetting(for: state.storeCreationTime,
                                                                supported: capabilities.supportsCreationTime)
        settings.storeAccessTime = compressionBoolPairSetting(for: state.storeAccessTime,
                                                              supported: capabilities.supportsAccessTime)
        settings.setArchiveTimeToLatestFile = compressionBoolPairSetting(for: state.setArchiveTimeToLatestFile,
                                                                         supported: true)
        settings.timePrecision = capabilities.supportedTimePrecisions.isEmpty || !state.timePrecision.isSet
            ? SZCompressionTimePrecision(rawValue: -1)!
            : state.timePrecision.value
    }

    @MainActor
    private final class ActionHandler: NSObject {
        private let handler: () -> Void

        init(handler: @escaping () -> Void) {
            self.handler = handler
        }

        @objc func invoke(_: Any?) {
            handler()
        }
    }

    @MainActor
    struct CompressDialogAdvancedOptionsPresenter {
        let parentWindow: NSWindow?
        let baseAdvancedOptionsCapabilities: (FormatOption, String?) -> AdvancedOptionsCapabilities
        let adjustedAdvancedOptionsCapabilities: (AdvancedOptionsCapabilities, SZCompressionTimePrecision, FormatOption, String?) -> AdvancedOptionsCapabilities
        let effectiveAdvancedOptions: (FormatOption, MethodOption?, AdvancedOptionsState) -> (state: AdvancedOptionsState, capabilities: AdvancedOptionsCapabilities)
        let makeTimePrecisionOptions: (AdvancedOptionsCapabilities) -> [Option<SZCompressionTimePrecision>]

        func run(for format: FormatOption,
                 method: MethodOption?,
                 initialState: AdvancedOptionsState) async -> AdvancedOptionsState?
        {
            let baseCapabilities = baseAdvancedOptionsCapabilities(format,
                                                                   method?.methodName)
            let effectiveInitialState = effectiveAdvancedOptions(format,
                                                                 method,
                                                                 initialState).state
            let timePrecisionOptions = makeTimePrecisionOptions(baseCapabilities)

            let setColumnWidth: CGFloat = 34

            func makeSetCheckbox() -> NSButton {
                let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
                checkbox.setContentHuggingPriority(.required, for: .horizontal)
                checkbox.setContentCompressionResistancePriority(.required, for: .horizontal)
                checkbox.controlSize = .small
                return checkbox
            }

            func makeColonLabel() -> NSTextField {
                let label = NSTextField(labelWithString: ":")
                label.textColor = .secondaryLabelColor
                label.alignment = .center
                label.widthAnchor.constraint(equalToConstant: 6).isActive = true
                return label
            }

            func makeSetColumn(setCheckbox: NSButton,
                               colonLabel: NSTextField) -> NSStackView
            {
                let column = NSStackView(views: [setCheckbox, colonLabel])
                column.orientation = .horizontal
                column.alignment = .centerY
                column.spacing = 4
                column.widthAnchor.constraint(equalToConstant: setColumnWidth).isActive = true
                return column
            }

            func makeBoolPairRow(title: String,
                                 state: AdvancedBoolPairState) -> (setCheckbox: NSButton, colonLabel: NSTextField, setColumn: NSStackView, valueCheckbox: NSButton, row: NSStackView)
            {
                let setCheckbox = makeSetCheckbox()
                setCheckbox.state = state.isSet ? .on : .off

                let colonLabel = makeColonLabel()
                let setColumn = makeSetColumn(setCheckbox: setCheckbox,
                                              colonLabel: colonLabel)

                let valueCheckbox = NSButton(checkboxWithTitle: title,
                                             target: nil,
                                             action: nil)
                valueCheckbox.state = state.value ? .on : .off

                let row = NSStackView(views: [setColumn, valueCheckbox])
                row.orientation = .horizontal
                row.alignment = .centerY
                row.spacing = 6
                return (setCheckbox, colonLabel, setColumn, valueCheckbox, row)
            }

            func selectTimePrecision(_ precision: SZCompressionTimePrecision) {
                if let selectedIndex = timePrecisionOptions.firstIndex(where: { $0.value.rawValue == precision.rawValue }) {
                    timePrecisionPopup.selectItem(at: selectedIndex)
                } else if !timePrecisionOptions.isEmpty {
                    timePrecisionPopup.selectItem(at: 0)
                }
            }

            func currentSelectedTimePrecision() -> SZCompressionTimePrecision {
                guard !timePrecisionOptions.isEmpty else {
                    return baseCapabilities.defaultTimePrecision
                }

                let selectedIndex = max(0, timePrecisionPopup.indexOfSelectedItem)
                guard timePrecisionOptions.indices.contains(selectedIndex) else {
                    return timePrecisionOptions[0].value
                }
                return timePrecisionOptions[selectedIndex].value
            }

            let symbolicLinksCheckbox = NSButton(checkboxWithTitle: SZL10n.string("compress.storeSymbolicLinks"),
                                                 target: nil,
                                                 action: nil)
            symbolicLinksCheckbox.state = effectiveInitialState.storeSymbolicLinks ? .on : .off

            let hardLinksCheckbox = NSButton(checkboxWithTitle: SZL10n.string("compress.storeHardLinks"),
                                             target: nil,
                                             action: nil)
            hardLinksCheckbox.state = effectiveInitialState.storeHardLinks ? .on : .off

            let alternateDataStreamsCheckbox = NSButton(checkboxWithTitle: SZL10n.string("compress.storeAlternateDataStreams"),
                                                        target: nil,
                                                        action: nil)
            alternateDataStreamsCheckbox.state = effectiveInitialState.storeAlternateDataStreams ? .on : .off

            let fileSecurityCheckbox = NSButton(checkboxWithTitle: SZL10n.string("compress.storeFileSecurity"),
                                                target: nil,
                                                action: nil)
            fileSecurityCheckbox.state = effectiveInitialState.storeFileSecurity ? .on : .off

            let preserveAccessTimeCheckbox = NSButton(checkboxWithTitle: SZL10n.string("time.doNotChangeAccessTime"),
                                                      target: nil,
                                                      action: nil)
            preserveAccessTimeCheckbox.state = effectiveInitialState.preserveSourceAccessTime ? .on : .off

            let timePrecisionSetCheckbox = makeSetCheckbox()
            timePrecisionSetCheckbox.state = effectiveInitialState.timePrecision.isSet ? .on : .off
            let timePrecisionColonLabel = makeColonLabel()
            let timePrecisionSetColumn = makeSetColumn(setCheckbox: timePrecisionSetCheckbox,
                                                       colonLabel: timePrecisionColonLabel)

            let timePrecisionLabel = NSTextField(labelWithString: SZL10n.string("time.timestampPrecision"))
            timePrecisionLabel.textColor = .labelColor

            let timePrecisionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
            timePrecisionPopup.addItems(withTitles: timePrecisionOptions.map(\.title))
            selectTimePrecision(effectiveInitialState.timePrecision.value)
            timePrecisionPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

            let timePrecisionContent = NSStackView(views: [timePrecisionLabel, timePrecisionPopup])
            timePrecisionContent.orientation = .horizontal
            timePrecisionContent.alignment = .centerY
            timePrecisionContent.spacing = 8

            let timePrecisionRow = NSStackView(views: [timePrecisionSetColumn, timePrecisionContent])
            timePrecisionRow.orientation = .horizontal
            timePrecisionRow.alignment = .centerY
            timePrecisionRow.spacing = 6

            let modificationTimeRow = makeBoolPairRow(title: SZL10n.string("time.storeModificationTime"),
                                                      state: effectiveInitialState.storeModificationTime)
            let creationTimeRow = makeBoolPairRow(title: SZL10n.string("time.storeCreationTime"),
                                                  state: effectiveInitialState.storeCreationTime)
            let accessTimeRow = makeBoolPairRow(title: SZL10n.string("time.storeLastAccessTime"),
                                                state: effectiveInitialState.storeAccessTime)
            let archiveTimeRow = makeBoolPairRow(title: SZL10n.string("time.setArchiveTimeToLatest"),
                                                 state: effectiveInitialState.setArchiveTimeToLatestFile)

            let typeLabel = NSTextField(labelWithString: Self.optionsTypeDescription(for: format,
                                                                                     method: method))
            typeLabel.font = .systemFont(ofSize: 12)
            typeLabel.textColor = .secondaryLabelColor

            let metadataSection = CompressDialogLayout.makeTitledSection(title: "NTFS", rows: [
                symbolicLinksCheckbox,
                hardLinksCheckbox,
                alternateDataStreamsCheckbox,
                fileSecurityCheckbox,
            ])

            let timeSection = CompressDialogLayout.makeTitledSection(title: SZL10n.string("time.time"), rows: [
                timePrecisionRow,
                modificationTimeRow.row,
                creationTimeRow.row,
                accessTimeRow.row,
                archiveTimeRow.row,
                preserveAccessTimeCheckbox,
            ])

            let contentStack = NSStackView(views: [typeLabel, metadataSection, timeSection])
            contentStack.orientation = .vertical
            contentStack.alignment = .leading
            contentStack.spacing = 12
            contentStack.translatesAutoresizingMaskIntoConstraints = false

            let wrapper = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 320))
            wrapper.translatesAutoresizingMaskIntoConstraints = false
            wrapper.addSubview(contentStack)

            NSLayoutConstraint.activate([
                wrapper.widthAnchor.constraint(equalToConstant: 520),
                contentStack.topAnchor.constraint(equalTo: wrapper.topAnchor),
                contentStack.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
                contentStack.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
                contentStack.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
            ])

            func configureSimpleCheckbox(_ checkbox: NSButton,
                                         supported: Bool)
            {
                checkbox.isHidden = !supported
                checkbox.isEnabled = supported
            }

            func configureBoolPairRow(_ row: (setCheckbox: NSButton, colonLabel: NSTextField, setColumn: NSStackView, valueCheckbox: NSButton, row: NSStackView),
                                      supported: Bool,
                                      defaultValue: Bool,
                                      showSetCheckbox: Bool)
            {
                row.row.isHidden = !supported
                row.valueCheckbox.isHidden = !supported
                row.setCheckbox.isHidden = !supported || !showSetCheckbox
                row.colonLabel.isHidden = row.setCheckbox.isHidden

                guard supported else {
                    return
                }

                if row.setCheckbox.state != .on {
                    row.valueCheckbox.state = defaultValue ? .on : .off
                }
                row.valueCheckbox.isEnabled = row.setCheckbox.state == .on
            }

            let refreshControls = {
                if !timePrecisionOptions.isEmpty,
                   timePrecisionSetCheckbox.state != .on
                {
                    selectTimePrecision(baseCapabilities.defaultTimePrecision)
                }

                let selectedTimePrecision = currentSelectedTimePrecision()
                let capabilities = adjustedAdvancedOptionsCapabilities(baseCapabilities,
                                                                       selectedTimePrecision,
                                                                       format,
                                                                       method?.methodName)

                configureSimpleCheckbox(symbolicLinksCheckbox,
                                        supported: capabilities.supportsSymbolicLinks)
                configureSimpleCheckbox(hardLinksCheckbox,
                                        supported: capabilities.supportsHardLinks)
                configureSimpleCheckbox(alternateDataStreamsCheckbox,
                                        supported: capabilities.supportsAlternateDataStreams)
                configureSimpleCheckbox(fileSecurityCheckbox,
                                        supported: capabilities.supportsFileSecurity)

                metadataSection.isHidden = !capabilities.hasMetadataControls

                let showPrecisionRow = !timePrecisionOptions.isEmpty
                timePrecisionRow.isHidden = !showPrecisionRow
                let showPrecisionSetCheckbox = timePrecisionSetCheckbox.state == .on || timePrecisionOptions.count > 1
                timePrecisionSetCheckbox.isHidden = !showPrecisionSetCheckbox
                timePrecisionColonLabel.isHidden = timePrecisionSetCheckbox.isHidden
                timePrecisionSetCheckbox.isEnabled = timePrecisionOptions.count > 1 || timePrecisionSetCheckbox.state == .on
                timePrecisionPopup.isEnabled = timePrecisionSetCheckbox.state == .on && timePrecisionOptions.count > 1

                configureBoolPairRow(modificationTimeRow,
                                     supported: capabilities.supportsModificationTime,
                                     defaultValue: capabilities.defaultModificationTime,
                                     showSetCheckbox: capabilities.keepsName || modificationTimeRow.setCheckbox.state == .on)
                configureBoolPairRow(creationTimeRow,
                                     supported: capabilities.supportsCreationTime,
                                     defaultValue: capabilities.defaultCreationTime,
                                     showSetCheckbox: true)
                configureBoolPairRow(accessTimeRow,
                                     supported: capabilities.supportsAccessTime,
                                     defaultValue: capabilities.defaultAccessTime,
                                     showSetCheckbox: true)
                configureBoolPairRow(archiveTimeRow,
                                     supported: true,
                                     defaultValue: false,
                                     showSetCheckbox: true)
            }

            let refreshHandler = ActionHandler(handler: refreshControls)
            let refreshControlsList: [NSControl] = [
                timePrecisionSetCheckbox,
                modificationTimeRow.setCheckbox,
                creationTimeRow.setCheckbox,
                accessTimeRow.setCheckbox,
                archiveTimeRow.setCheckbox,
            ]
            for item in refreshControlsList {
                item.target = refreshHandler
                item.action = #selector(ActionHandler.invoke(_:))
            }
            timePrecisionPopup.target = refreshHandler
            timePrecisionPopup.action = #selector(ActionHandler.invoke(_:))
            refreshControls()

            let controller = SZModalDialogController(style: .informational,
                                                     title: SZL10n.string("compress.options"),
                                                     message: nil,
                                                     actions: [
                                                         SZDialogAction(title: SZL10n.string("common.cancel"),
                                                                        roles: .cancel),
                                                         SZDialogAction(title: SZL10n.string("common.ok"),
                                                                        roles: .default),
                                                     ],
                                                     accessoryView: wrapper,
                                                     preferredFirstResponder: nil)
            let buttonIndex = await controller.modalResult(for: parentWindow)
            withExtendedLifetime(refreshHandler) {}
            guard buttonIndex == 1 else {
                return nil
            }

            let updatedState = AdvancedOptionsState(
                storeSymbolicLinks: symbolicLinksCheckbox.state == .on,
                storeHardLinks: hardLinksCheckbox.state == .on,
                storeAlternateDataStreams: alternateDataStreamsCheckbox.state == .on,
                storeFileSecurity: fileSecurityCheckbox.state == .on,
                preserveSourceAccessTime: preserveAccessTimeCheckbox.state == .on,
                storeModificationTime: AdvancedBoolPairState(isSet: modificationTimeRow.setCheckbox.state == .on,
                                                             value: modificationTimeRow.valueCheckbox.state == .on),
                storeCreationTime: AdvancedBoolPairState(isSet: creationTimeRow.setCheckbox.state == .on,
                                                         value: creationTimeRow.valueCheckbox.state == .on),
                storeAccessTime: AdvancedBoolPairState(isSet: accessTimeRow.setCheckbox.state == .on,
                                                       value: accessTimeRow.valueCheckbox.state == .on),
                setArchiveTimeToLatestFile: AdvancedBoolPairState(isSet: archiveTimeRow.setCheckbox.state == .on,
                                                                  value: archiveTimeRow.valueCheckbox.state == .on),
                timePrecision: AdvancedTimePrecisionState(isSet: timePrecisionSetCheckbox.state == .on,
                                                          value: currentSelectedTimePrecision()),
            )
            return effectiveAdvancedOptions(format,
                                            method,
                                            updatedState).state
        }

        private static func optionsTypeDescription(for format: FormatOption,
                                                   method: MethodOption?) -> String
        {
            var description = "\(SZL10n.string("column.type")): \(format.title)"
            if format.codecName.caseInsensitiveCompare("tar") == .orderedSame,
               let methodName = method?.methodName,
               !methodName.isEmpty
            {
                description += ": \(methodName)"
            }
            return description
        }
    }
}
