import SwiftUI
import AppKit

@main struct QingSweepApp: App {
    @NSApplicationDelegateAdaptor(QingSweepApplicationDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    @ObservedObject private var language = LanguageSettings.shared
    var body: some Scene {
        Window(L("轻扫 · 磁盘与内存"), id: "main") {
            ContentView().environmentObject(model).onAppear { delegate.model = model }
        }.defaultSize(width: 1360, height: 760)
            .windowResizability(.contentMinSize)
            .commands {
                CommandGroup(replacing: .newItem) {}
                CommandGroup(after: .appInfo) { Button(L("检查更新…")) { UpdateChecker.shared.check() } }
                CommandMenu(L("扫描")) {
                    Button(L("重新扫描"), action: model.rescan).keyboardShortcut("r", modifiers: .command).disabled(model.busy)
                    Button(L("扫描个人大文件"), action: model.personalScan).disabled(model.busy)
                    Button(L("查找长期未用的大文件"), action: model.unusedLargeFileScan).disabled(model.busy)
                    Button(L("选择文件夹…"), action: model.chooseFolder).keyboardShortcut("o", modifiers: .command).disabled(model.busy)
                    Divider()
                    Button(L("停止扫描"), action: model.cancelScan).disabled(!model.scanning)
                }
            }
    }
}
