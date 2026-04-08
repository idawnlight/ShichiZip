import Cocoa

/// Sets up the main application menu bar programmatically
enum MainMenu {

    static func setup() {
    let mainMenu = NSMenu(title: "Main Menu")

    let appMenu = NSMenu(title: "ShichiZip")
    addTopLevelMenu(appMenu, to: mainMenu)
    addItem(to: appMenu,
        title: "About ShichiZip",
        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
        target: NSApp)
    appMenu.addItem(.separator())
    addItem(to: appMenu,
        title: "Preferences…",
        action: #selector(AppDelegate.showPreferences(_:)),
        keyEquivalent: ",",
        target: NSApp.delegate)
    appMenu.addItem(.separator())

    let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
    let servicesMenu = NSMenu(title: "Services")
    servicesItem.submenu = servicesMenu
    NSApp.servicesMenu = servicesMenu
    appMenu.addItem(servicesItem)

    appMenu.addItem(.separator())
    addItem(to: appMenu,
        title: "Hide ShichiZip",
        action: #selector(NSApplication.hide(_:)),
        keyEquivalent: "h",
        target: NSApp)
    addItem(to: appMenu,
        title: "Hide Others",
        action: #selector(NSApplication.hideOtherApplications(_:)),
        keyEquivalent: "h",
        modifiers: [.command, .option],
        target: NSApp)
    addItem(to: appMenu,
        title: "Show All",
        action: #selector(NSApplication.unhideAllApplications(_:)),
        target: NSApp)
    appMenu.addItem(.separator())
    addItem(to: appMenu,
        title: "Quit ShichiZip",
        action: #selector(NSApplication.terminate(_:)),
        keyEquivalent: "q",
        target: NSApp)

    let fileMenu = NSMenu(title: "File")
    addTopLevelMenu(fileMenu, to: mainMenu)
    addItem(to: fileMenu,
        title: "Open",
        action: #selector(FileManagerWindowController.openSelectedItem(_:)))
    addItem(to: fileMenu,
        title: "Open Archive…",
        action: #selector(AppDelegate.openArchives(_:)),
        keyEquivalent: "o",
        target: NSApp.delegate)
    fileMenu.addItem(.separator())
    addItem(to: fileMenu,
        title: "Add",
        action: #selector(FileManagerWindowController.addToArchive(_:)))
    addItem(to: fileMenu,
        title: "Extract…",
        action: #selector(FileManagerWindowController.extractArchive(_:)))
    addItem(to: fileMenu,
        title: "Extract Here",
        action: #selector(FileManagerWindowController.extractHere(_:)))
    addItem(to: fileMenu,
        title: "Test",
        action: #selector(FileManagerWindowController.testArchive(_:)))
    fileMenu.addItem(.separator())
    addItem(to: fileMenu,
        title: "Rename",
        action: #selector(FileManagerWindowController.renameSelection(_:)))
    addItem(to: fileMenu,
        title: "Copy To…",
        action: #selector(FileManagerWindowController.copyFiles(_:)))
    addItem(to: fileMenu,
        title: "Move To…",
        action: #selector(FileManagerWindowController.moveFiles(_:)))
    addItem(to: fileMenu,
        title: "Delete",
        action: #selector(FileManagerWindowController.deleteFiles(_:)))
    fileMenu.addItem(.separator())
    addItem(to: fileMenu,
        title: "Properties",
        action: #selector(FileManagerWindowController.showProperties(_:)))
    fileMenu.addItem(.separator())
    addItem(to: fileMenu,
        title: "Create Folder",
        action: #selector(FileManagerWindowController.createFolder(_:)))
    fileMenu.addItem(.separator())
    addItem(to: fileMenu,
        title: "Close",
        action: #selector(NSWindow.performClose(_:)),
        keyEquivalent: "w")

    let editMenu = NSMenu(title: "Edit")
    addTopLevelMenu(editMenu, to: mainMenu)
    addItem(to: editMenu,
        title: "Select All",
        action: #selector(FileManagerWindowController.selectAllItems(_:)),
        keyEquivalent: "a")
    addItem(to: editMenu,
        title: "Deselect All",
        action: #selector(FileManagerWindowController.deselectAllItems(_:)),
        keyEquivalent: "a",
        modifiers: [.command, .shift])
    addItem(to: editMenu,
        title: "Invert Selection",
        action: #selector(FileManagerWindowController.invertSelection(_:)))

    let viewMenu = NSMenu(title: "View")
    addTopLevelMenu(viewMenu, to: mainMenu)
    addItem(to: viewMenu,
        title: "Up One Level",
        action: #selector(FileManagerWindowController.goUpOneLevel(_:)))
    addItem(to: viewMenu,
        title: "Refresh",
        action: #selector(FileManagerWindowController.refreshActivePane(_:)),
        keyEquivalent: "r")
    viewMenu.addItem(.separator())
    addItem(to: viewMenu,
        title: "Sort by Name",
        action: #selector(FileManagerWindowController.sortByName(_:)))
    addItem(to: viewMenu,
        title: "Sort by Size",
        action: #selector(FileManagerWindowController.sortBySize(_:)))
    addItem(to: viewMenu,
        title: "Sort by Modified",
        action: #selector(FileManagerWindowController.sortByModifiedDate(_:)))
    addItem(to: viewMenu,
        title: "Sort by Created",
        action: #selector(FileManagerWindowController.sortByCreatedDate(_:)))
    viewMenu.addItem(.separator())
    addItem(to: viewMenu,
        title: "2 Panels",
        action: #selector(FileManagerWindowController.toggleDualPane(_:)))
    viewMenu.addItem(.separator())
    addItem(to: viewMenu,
        title: "Enter Full Screen",
        action: #selector(NSWindow.toggleFullScreen(_:)),
        keyEquivalent: "f",
        modifiers: [.command, .control])

    let toolsMenu = NSMenu(title: "Tools")
    addTopLevelMenu(toolsMenu, to: mainMenu)
    addItem(to: toolsMenu,
        title: "Options…",
        action: #selector(AppDelegate.showPreferences(_:)),
        target: NSApp.delegate)
    toolsMenu.addItem(.separator())
    addItem(to: toolsMenu,
        title: "Benchmark",
        action: #selector(AppDelegate.showBenchmark(_:)),
        keyEquivalent: "b",
        modifiers: [.command, .shift],
        target: NSApp.delegate)

    let windowMenu = NSMenu(title: "Window")
    addTopLevelMenu(windowMenu, to: mainMenu)
    addItem(to: windowMenu,
        title: "File Manager",
        action: #selector(AppDelegate.showFileManager(_:)),
        target: NSApp.delegate)
    windowMenu.addItem(.separator())
    addItem(to: windowMenu,
        title: "Minimize",
        action: #selector(NSWindow.performMiniaturize(_:)),
        keyEquivalent: "m")
    addItem(to: windowMenu,
        title: "Zoom",
        action: #selector(NSWindow.performZoom(_:)))
    windowMenu.addItem(.separator())
    addItem(to: windowMenu,
        title: "Bring All to Front",
        action: #selector(NSApplication.arrangeInFront(_:)),
        target: NSApp)
    NSApp.windowsMenu = windowMenu

    let helpMenu = NSMenu(title: "Help")
    addTopLevelMenu(helpMenu, to: mainMenu)
    addItem(to: helpMenu,
        title: "ShichiZip Help",
        action: #selector(NSApplication.showHelp(_:)),
        keyEquivalent: "?",
        target: NSApp)
    NSApp.helpMenu = helpMenu

    NSApp.mainMenu = mainMenu
    }

    @discardableResult
    private static func addItem(to menu: NSMenu,
                title: String,
                action: Selector?,
                keyEquivalent: String = "",
                modifiers: NSEvent.ModifierFlags = [.command],
                target: AnyObject? = nil) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
    item.target = target
    if !keyEquivalent.isEmpty {
        item.keyEquivalentModifierMask = modifiers
    }
    menu.addItem(item)
    return item
    }

    private static func addTopLevelMenu(_ submenu: NSMenu, to mainMenu: NSMenu) {
    let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
    item.submenu = submenu
    mainMenu.addItem(item)
    }
}
