import SwiftUI

struct RootView: View {
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            ComposeView()
                .tabItem { Label("集字", systemImage: "character.book.closed") }
                .tag(0)
            LibraryView()
                .tabItem { Label("字库", systemImage: "square.grid.3x3.square") }
                .tag(1)
            AboutView()
                .tabItem { Label("关于", systemImage: "info.circle") }
                .tag(2)
        }
    }
}

struct AboutView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("怎么用") {
                    Label("在「字库」导入碑帖扫描图，切字后填上释文", systemImage: "1.circle")
                    Label("释文按阅读顺序逐字对齐，自动给每个格子打上 label", systemImage: "2.circle")
                    Label("回「集字」页输入文字，点任意一个字可换候选", systemImage: "3.circle")
                    Label("导出时按笔迹外框归一化，字与字视觉大小一致", systemImage: "4.circle")
                }
                Section("排版") {
                    Text("竖排右起是默认；落款画在左侧，印章按右起两行排。")
                        .font(.footnote)
                }
                Section("建议的图片") {
                    Text("故宫数字文物库、Wikimedia Commons 的拓本类目、公有领域碑帖扫描件。单页分辨率 2000px 以上切出来的字更干净。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("版本") {
                    Text("JiZi 1.0.0 · 本地运行，不联网，字库都在自己手机里")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("关于")
        }
    }
}
