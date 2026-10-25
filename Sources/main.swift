import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = AppController()
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("---- PiPGlass \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "?") launched (pid \(getpid()))")
        controller.start()

        // Put Firefox's PiP window back if we're killed with SIGTERM/SIGINT.
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in
                Log.info("signal \(sig): restoring and exiting")
                self?.controller.parker.restore()
                exit(0)
            }
            src.resume()
            signalSources.append(src)
        }
        #if PIPGLASS_DEBUG
        // Self-test hooks (see Debug.swift).
        for (sig, action) in [(SIGUSR1, { [weak self] in self?.controller.writeDebugSnapshots() }),
                              (SIGUSR2, { [weak self] in self?.controller.runDebugCommand() })] as [(Int32, () -> Void)] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { MainActor.assumeIsolated { action() } }
            src.resume()
            signalSources.append(src)
        }
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.parker.restore()
        Log.info("---- PiPGlass terminating")
    }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
