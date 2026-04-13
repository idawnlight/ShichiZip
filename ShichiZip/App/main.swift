import Cocoa

let delegate: AppDelegate = MainActor.assumeIsolated {
    AppDelegate()
}
MainActor.assumeIsolated {
    NSApplication.shared.delegate = delegate
}
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
