import AppKit
import KeyboardShortcuts
import SwiftUI

extension KeyboardShortcuts.Name {
    static let saveSelection = Self("saveSelection")
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    let store: ClipStore

    private init() {
        do {
            store = try ClipStore()
        } catch {
            fatalError("Voca: 无法打开数据库：\(error)")
        }
    }

    func handleHotkey() {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = CaptureEngine.shared.capture()
            DispatchQueue.main.async {
                AppModel.shared.handle(result)
            }
        }
    }

    private func handle(_ result: CaptureResult) {
        switch result {
        case .success(let text, let appName, let bundleID):
            let capped = String(text.prefix(10_000))
            if store.isRecentDuplicate(text: capped, bundleID: bundleID) {
                ToastController.shared.show("重复内容，未再次保存")
                return
            }
            do {
                try store.insert(text: capped, appName: appName, bundleID: bundleID)
                let suffix = appName.map { " · 来自 \($0)" } ?? ""
                ToastController.shared.show("已保存\(suffix)")
            } catch {
                ToastController.shared.show("保存失败：\(error.localizedDescription)")
            }
        case .emptySelection:
            ToastController.shared.show("未检测到选中文本")
        case .notTrusted:
            ToastController.shared.show("需要辅助功能权限，正在打开系统设置…")
            CaptureEngine.shared.requestTrust()
        case .secureField:
            ToastController.shared.show("已跳过安全输入框（密码）")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        KeyboardShortcuts.onKeyUp(for: .saveSelection) {
            AppModel.shared.handleHotkey()
        }
    }
}

@main
struct VocaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
        // 首次启动给默认快捷键 ⌥⇧S，用户可随时在菜单栏改
        if KeyboardShortcuts.getShortcut(for: .saveSelection) == nil {
            KeyboardShortcuts.setShortcut(
                KeyboardShortcuts.Shortcut(.s, modifiers: [.option, .shift]),
                for: .saveSelection
            )
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(model.store)
        } label: {
            Image(systemName: "text.quote")
        }
        .menuBarExtraStyle(.window)

        Window("Voca 记录", id: "records") {
            RecordsView()
                .environmentObject(model.store)
        }
        .defaultSize(width: 560, height: 480)
    }
}

// MARK: - 菜单栏面板

struct MenuBarView: View {
    @EnvironmentObject private var store: ClipStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "text.quote")
                    .foregroundStyle(.secondary)
                Text("Voca").font(.headline)
                Spacer()
                Text("\(store.clips.count) 条")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            KeyboardShortcuts.Recorder("保存快捷键：", name: .saveSelection)

            Divider()

            Button {
                openWindow(id: "records")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("查看全部记录", systemImage: "list.bullet.rectangle")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button(role: .destructive) {
                NSApp.terminate(nil)
            } label: {
                Label("退出 Voca", systemImage: "power")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .frame(width: 260)
    }
}

// MARK: - 记录窗口

struct RecordsView: View {
    @EnvironmentObject private var store: ClipStore
    @State private var search = ""

    var body: some View {
        NavigationStack {
            Group {
                if store.clips.isEmpty {
                    Text(
                        search.isEmpty
                            ? "还没有记录\n在任意 App 选中文字，按保存快捷键试试"
                            : "没有匹配的记录"
                    )
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(store.clips) { clip in
                        ClipRow(clip: clip)
                    }
                    .listStyle(.inset)
                }
            }
            .navigationTitle("Voca 记录")
            .searchable(text: $search, placement: .toolbar, prompt: "搜索全文")
            .onChange(of: search) { _, newValue in
                store.reload(search: newValue)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(role: .destructive) {
                        store.deleteAll()
                    } label: {
                        Label("清空全部", systemImage: "trash")
                    }
                    .disabled(store.clips.isEmpty)
                }
            }
            .onAppear {
                store.reload(search: search)
            }
        }
    }
}

struct ClipRow: View {
    let clip: Clip
    @EnvironmentObject private var store: ClipStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(clip.text)
                .font(.system(size: 13))
                .lineLimit(4)
                .truncationMode(.tail)
                .textSelection(.enabled)

            HStack(spacing: 8) {
                Label(clip.appName ?? "未知来源", systemImage: "app.dashed")
                Spacer()
                Text(clip.createdAt.formatted(date: .abbreviated, time: .shortened))
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(clip.text, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("复制全文")
                Button {
                    store.delete(clip)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("删除")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("复制全文") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(clip.text, forType: .string)
            }
            Button("删除", role: .destructive) {
                store.delete(clip)
            }
        }
    }
}
