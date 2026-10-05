import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var model: AppRouterModel

    /// 只存下标、不存副本：既省掉一次数组拷贝，也让 List 只为命中的 App 建行。
    /// 三个计数同理改为读 Model 的缓存（原来每帧要全量 filter 三遍）。
    private var filteredIndices: [Int] {
        guard !model.searchText.isEmpty else { return Array(model.apps.indices) }
        let q = model.searchText.lowercased()
        return model.apps.indices.filter { i in
            model.apps[i].name.lowercased().contains(q)
                || model.apps[i].executableName.lowercased().contains(q)
        }
    }

    /// 总开关绑定：UI 切换走 setAppRoutingEnabled（内部直接改存储值不会触发这里，避免循环）
    private var modeBinding: Binding<Bool> {
        Binding(
            get: { model.appRoutingEnabled },
            set: { model.setAppRoutingEnabled($0) }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            modeCard

            if !model.prerequisiteWarning.isEmpty {
                prerequisiteBanner
            }

            if model.appRoutingEnabled {
                if !model.apps.isEmpty { searchBar }
                content
            } else {
                originalRulesView
            }

            Divider()

            actionBar

            if model.appRoutingEnabled
                && (model.countRouted > 0 || !model.rulesPreviewText.isEmpty) {
                rulesPreview
            }
        }
        .frame(minWidth: 720, minHeight: 560)
        .onAppear { if model.apps.isEmpty { model.scan() } }
    }

    // ── 顶部标题栏 ──
    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch")
                .font(.title3)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("按软件分流")
                    .font(.system(size: 15, weight: .semibold))
                Text("出口组：\(model.proxyTargetName)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()

            if model.isScanning {
                ProgressView()
                    .controlSize(.small)
                Text("扫描中…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if model.appRoutingEnabled && !model.apps.isEmpty {
                statPill(icon: "app.badge", text: "\(model.apps.count) 个 App")
                if model.countProxy > 0 {
                    statPill(
                        icon: "paperplane.fill", text: "代理 \(model.countProxy)", highlighted: true)
                }
                if model.countDirect > 0 {
                    statPill(
                        icon: "bolt.horizontal.fill", text: "直连 \(model.countDirect)",
                        directStyle: true)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private func statPill(
        icon: String, text: String, highlighted: Bool = false, directStyle: Bool = false
    ) -> some View {
        let color: Color = directStyle ? .green : (highlighted ? .accentColor : .secondary)
        return HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10))
            Text(text)
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(
                    directStyle
                        ? Color.green.opacity(0.12)
                        : (highlighted ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.05))
                )
        )
    }

    // ── 模式开关卡片 ──
    private var modeCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: model.appRoutingEnabled ? "app.badge.checkmark" : "network")
                    .font(.title2)
                    .foregroundStyle(model.appRoutingEnabled ? Color.accentColor : Color.secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("App 规则分流")
                        .font(.system(size: 14, weight: .semibold))
                    Text(
                        model.appRoutingEnabled
                            ? "已开启：改动立即生效，可逐 App 选原规则 / 直连 / 代理"
                            : "已关闭：全部流量走原有机场规则"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: modeBinding)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(model.appRoutingEnabled ? Color.accentColor.opacity(0.06) : Color.clear)

            // 开关关闭但 profile 里仍有生效规则时给出提示（用户有权知道，并可一键恢复）
            if !model.appRoutingEnabled && model.hasWrittenRules {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 11))
                    Text("当前上次保存的 App 规则生效中（点 恢复原配置 可清除）")
                        .font(.caption)
                    Spacer()
                }
                .foregroundStyle(.orange)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }
        }
    }

    // ── 前置条件告警条（TUN / find-process-mode 不满足时）──
    // 换一台电脑后这两个前提未必满足，不满足时规则会静默失效，必须显式告诉用户。
    private var prerequisiteBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
            Text(model.prerequisiteWarning)
                .font(.caption)
            Spacer()
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.10))
    }

    // ── 原有规则说明页 ──
    private var originalRulesView: some View {
        VStack(spacing: 14) {
            Image(systemName: "network")
                .font(.system(size: 46))
                .foregroundStyle(.tertiary)
            Text(
                model.hasWrittenRules
                    ? "当前使用原有机场规则+上次自定义规则"
                    : "当前使用原有机场规则"
            )
            .font(.headline)
            Text("打开上方「App 规则分流」开关，\n即可为每个 App 单独选择直连或代理，改动立即生效。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // ── 搜索栏 ──
    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索 App（名称或进程名）", text: $model.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if !model.searchText.isEmpty {
                Text("\(filteredIndices.count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
                Button {
                    model.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("清除搜索")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.1))
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // ── 中间内容区（App 规则模式）──
    @ViewBuilder
    private var content: some View {
        if model.isScanning && model.apps.isEmpty {
            loadingView
        } else if model.apps.isEmpty {
            emptyAppsView
        } else if filteredIndices.isEmpty {
            emptySearchView
        } else {
            appList
        }
    }

    private var loadingView: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("正在扫描已安装的应用…")
                .foregroundStyle(.secondary)
            Text("扫描 /Applications、/System/Applications、~/Applications")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyAppsView: some View {
        VStack(spacing: 12) {
            Image(systemName: "app.dashed")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            Text("没有找到任何 App")
                .font(.headline)
            Text("请确认系统已安装应用，然后重新扫描")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button {
                model.scan(force: true)
            } label: {
                Label("重新扫描", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptySearchView: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("没有匹配「\(model.searchText)」的 App")
                .foregroundStyle(.secondary)
            Text("试试名称或进程名的其他关键词")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var appList: some View {
        List {
            ForEach(filteredIndices, id: \.self) { i in
                AppRow(app: $model.apps[i])
                    .listRowBackground(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(rowBackground(for: model.apps[i]))
                            .padding(.horizontal, 6)
                    )
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }

    /// 行背景只看策略，不再看 hover。
    /// 原因：滚动时指针不动、行从指针下方穿过，onHover 会疯狂触发 enter/exit；
    /// 每次都改一个 @Published → 整个界面失效重绘 → 这是列表卡顿的主因。
    private func rowBackground(for app: AppEntry) -> Color {
        if app.policy == .proxy { return Color.accentColor.opacity(0.10) }
        if app.policy == .direct { return Color.green.opacity(0.10) }
        return Color.clear
    }

    // ── 底部操作栏 ──
    private var actionBar: some View {
        HStack(spacing: 10) {
            Button {
                model.restore()
            } label: {
                Label("恢复原配置", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(!model.hasWrittenRules || model.isReloading)
            .help("移除本工具写入的所有规则，回到原有机场配置")

            Menu {
                Button("全部设为代理") { setAll(.proxy) }
                Button("全部直连") { setAll(.direct) }
                Button("全部回到原规则") { setAll(.origin) }
                Divider()
                Button("重新扫描") { model.scan(force: true) }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 30)
            .disabled(!model.appRoutingEnabled)
            .help("批量操作")

            Spacer()

            if !model.statusMessage.isEmpty {
                statusView
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func setAll(_ policy: RoutePolicy) {
        for i in model.apps.indices {
            if model.searchText.isEmpty
                || model.apps[i].name.localizedCaseInsensitiveContains(model.searchText)
                || model.apps[i].executableName.localizedCaseInsensitiveContains(model.searchText) {
                model.apps[i].policy = policy
            }
        }
        model.scheduleApply()
    }

    private var statusView: some View {
        HStack(spacing: 6) {
            if model.isReloading {
                ProgressView()
                    .controlSize(.small)
            } else if let icon = statusIcon {
                Image(systemName: icon)
                    .foregroundStyle(statusColor)
                    .font(.system(size: 12))
            }
            Text(model.statusMessage)
                .font(.callout)
                .foregroundStyle(statusColor)
                .lineLimit(2)
        }
        .frame(maxWidth: 320, alignment: .trailing)
    }

    private var statusIcon: String? {
        let m = model.statusMessage
        if m.contains("失败") || m.contains("无法") || m.contains("错误") {
            return "exclamationmark.triangle.fill"
        }
        if m.contains("已写入") || m.contains("已恢复") || m.contains("已重载")
            || m.contains("生效") || m.contains("成功") {
            return "checkmark.circle.fill"
        }
        return nil
    }

    private var statusColor: Color {
        if model.isReloading { return .secondary }
        let m = model.statusMessage
        if m.contains("失败") || m.contains("无法") || m.contains("错误") {
            return .red
        }
        if m.contains("已写入") || m.contains("已恢复") || m.contains("已重载")
            || m.contains("生效") || m.contains("成功") {
            return .green
        }
        return .secondary
    }

    // ── 规则预览 ──
    private var rulesPreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "text.alignleft")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("规则预览")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("· \(model.countRouted) 条 · 改动立即生效")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.rulesPreviewText, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("复制规则到剪贴板")
            }
            ScrollView {
                Text(model.rulesPreviewText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(10)
            }
            .frame(maxHeight: 130)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(NSColor.textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.primary.opacity(0.08))
            )
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }
}

/// 单行 App 行：改动直连/代理立即生效（经 model.scheduleApply 防抖）
struct AppRow: View {
    @EnvironmentObject var model: AppRouterModel
    @Binding var app: AppEntry

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: app.icon)
                .resizable()
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(
                        app.extraProcs.isEmpty
                            ? app.executableName
                            : "\(app.executableName) · 含 \(app.extraProcs.count) 个子进程"
                    )
                    if app.conflictingNames.contains(app.executableName) {
                        // 同名进程串扰提示：主进程名被多个 App 共用，会走全路径规则
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.orange)
                            .help("主进程名被多个 App 共用，已自动改用全路径(PROCESS-PATH)精确匹配，不会影响其他 App")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .frame(width: 220, alignment: .leading)

            Spacer()

            Picker(
                "",
                selection: Binding(
                    get: { app.policy },
                    set: { newValue in
                        app.policy = newValue
                        model.scheduleApply()
                    }
                )
            ) {
                ForEach(RoutePolicy.allCases) { p in
                    Text(p.label).tag(p)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
            .help("原规则 = 走机场原有分流；直连 = 真正不走代理；代理 = 走出口组（改动立即生效）")
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}
