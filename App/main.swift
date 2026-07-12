// ホストアプリ: QL 拡張の入れ物 + 開発用の単体ビューア。
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windows: [NSWindow] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let fileItem = NSMenuItem(); menu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Open…", action: #selector(openDocument), keyEquivalent: "o")
        fileItem.submenu = fileMenu
        NSApp.mainMenu = menu
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // コマンドライン引数でファイル指定された場合（開発用）
        let args = ProcessInfo.processInfo.arguments.dropFirst()
        for arg in args where arg.hasSuffix(".ifc") {
            openViewer(URL(fileURLWithPath: arg))
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(openViewer)
    }

    @objc private func openDocument() {
        let panel = NSOpenPanel()
        panel.allowsOtherFileTypes = true
        if panel.runModal() == .OK, let url = panel.url { openViewer(url) }
    }

    private func openViewer(_ url: URL) {
        let vc = ViewerViewController()
        let window = NSWindow(contentViewController: vc)
        window.title = url.lastPathComponent
        window.setContentSize(NSSize(width: 1000, height: 700))
        window.makeKeyAndOrderFront(nil)
        windows.append(window)
        vc.start(url: url)
    }
}

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
