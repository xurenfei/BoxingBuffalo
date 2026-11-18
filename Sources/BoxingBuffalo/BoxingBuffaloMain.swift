import AppKit

/// Entry point.
///
/// Deliberately not `main.swift`: top-level code there is not main-actor
/// isolated, and `AppDelegate` is (it owns a `@MainActor` model), so
/// constructing it from the top level is rejected by Swift 6 strict
/// concurrency. `@main` lets us mark the entry point `@MainActor` instead.
///
/// `NSApplication.delegate` is an unowned reference, so the delegate has to be
/// parked in a static property or it is deallocated the moment `main` returns.
@main
@MainActor
struct BoxingBuffaloMain {
    private static var retainedDelegate: AppDelegate?

    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        retainedDelegate = delegate
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
    }
}
