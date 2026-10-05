import SwiftUI
import AppKit
import CoreServices

/// NSImage 缩小工具（AppKit 提供，追加到 NSImage 扩展）
extension NSImage {
    func resized(to target: NSSize) -> NSImage {
        let out = NSImage(size: target)
        out.lockFocus()
        self.draw(in: NSRect(origin: .zero, size: target),
                  from: NSRect(origin: .zero, size: self.size),
                  operation: .copy, fraction: 1.0)
        out.unlockFocus()
        return out
    }
}

enum RoutePolicy: String, CaseIterable, Identifiable {
    case origin = "ORIGIN"  // 原规则：不生成任何规则，走机场原有分流
    case direct = "DIRECT"  // 直连：生成 PROCESS-NAME,X,DIRECT，真正不走代理
    case proxy = "Proxy"    // 代理：生成 PROCESS-NAME,X,<出口组>
    var id: String { rawValue }
    var label: String {
        switch self {
        case .origin: return "原规则"
        case .direct: return "直连"
        case .proxy: return "代理"
        }
    }
}

/// 一条「必须解决才能用」的前置问题：标题 + 具体怎么修
struct PrereqIssue: Identifiable {
    let id = UUID()
    let icon: String  // SF Symbol
    let title: String
    let hint: String
}

/// 一个可被 PROCESS-NAME / PROCESS-PATH 匹配的进程
struct ProcSpec {
    let name: String  // 进程名（basename）
    let path: String  // 完整可执行文件路径
}

struct AppEntry: Identifiable {
    let id = UUID()
    let name: String
    let path: String
    let executableName: String
    let mainProcPath: String
    /// 嵌套子进程（Chromium 系浏览器的网络请求由 Helper 进程发出，微信的小程序/视频组件同理；
    /// 只匹配主进程名会导致规则不生效，必须一并写规则）
    let extraProcs: [ProcSpec]
    /// 本机范围内被多个 App 共用的进程名（这些进程须用 PROCESS-PATH 全路径规则，
    /// 否则会给别的 App 一起分流——如 WorkBuddy/Trae CN 主进程都叫 Electron)
    var conflictingNames: Set<String> = []
    let icon: NSImage
    var policy: RoutePolicy = .origin
}

final class AppRouterModel: ObservableObject {
    static let shared = AppRouterModel()

    @Published var apps: [AppEntry] = []
    @Published var generatedRules: String = ""
    @Published var statusMessage: String = ""
    @Published var searchText: String = ""
    @Published var isScanning: Bool = false
    @Published var isReloading: Bool = false
    @Published var hasWrittenRules: Bool = false
    /// 总开关：开 = App 规则分流（改动立即生效）；关 = 原有机场规则
    @Published var appRoutingEnabled: Bool = false
    /// 出口组名缓存（仅 UI 显示用；真正写规则时 generate() 内部仍实时解析，机场切换后写入也安全）
    @Published var proxyTargetName: String = "Proxy"
    // ── 派生数据缓存（滚动性能关键）──
    // 原先这三项是 ContentView 里的 computed property，界面**每次重绘**都要：
    //   · 全量 filter 一遍 apps（3 次）
    //   · 重新拼一遍规则字符串（generate()，当前 39 条规则）
    // 而滚动时 SwiftUI 每帧都重绘 → 卡顿。改为只在策略/列表真正变化时重算一次。
    @Published var rulesPreviewText: String = ""
    @Published var countRouted: Int = 0
    @Published var countProxy: Int = 0
    @Published var countDirect: Int = 0
    /// 前置条件自检结果。非空 = 存在「必须解决才能用」的问题 → 界面被拦截页接管。
    /// 换机器分发后最关键的一项：不满足时 PROCESS-NAME 规则根本不会命中，
    /// 工具会「看起来正常但静默失效」，所以宁可拦住也不让用户带着坏配置操作。
    @Published var prereqIssues: [PrereqIssue] = []
    /// 是否已完成首次检测（未完成时先显示「检测中」，避免主界面闪一下再被拦）
    @Published var prereqChecked = false
    /// 诊断信息：把实际读到的原始值摊开，万一检测有误用户能直接看到原因
    @Published var prereqDiagnostics: String = ""
    /// 当前问题能否自动修复（读不到 FLClash 设置时不能）
    @Published var prereqAutoFixable = true
    /// 自动修复进行中
    @Published var isAutoFixing = false
    /// 自动修复的结果提示（显示在拦截页上）
    @Published var autoFixMessage: String = ""
    /// FLClash 当前状态标签（如「规则模式 · TUN 已开」），标题栏实时展示用。
    /// 与 prereqIssues 一样由 1 秒轮询刷新。
    @Published var flclashStatusLabel: String = ""

    /// 防抖任务：改动后 1.2s 内连续改动只生效最后一次
    private var applyWorkItem: DispatchWorkItem?

    /// config.yaml 文件监听（机场切换/订阅更新都会重写它，借此实时刷新出口组）
    private var configWatcher: DispatchSourceFileSystemObject?
    private var configWatchWork: DispatchWorkItem?
    /// 定时轮询 FLClash 设置（模式切换不会改 config.yaml 之外的触发点，靠它兜底）
    private var refreshTimer: Timer?

    /// 刷新 UI 显示用的出口组名缓存（scan 完成 / 写入 / 恢复后调用）
    func refreshProxyTarget() {
        proxyTargetName = resolveProxyTarget()
    }

    /// 重算派生数据（规则预览文本 + 三个计数）。
    /// **只能在 body 之外调用**：本函数写 @Published，若被界面重绘调用会
    /// 「重绘 → 改状态 → 再重绘」无限循环（迭代6 踩过同样的坑）。
    func refreshDerived() {
        countRouted = apps.filter { $0.policy != .origin }.count
        countProxy = apps.filter { $0.policy == .proxy }.count
        countDirect = apps.filter { $0.policy == .direct }.count
        rulesPreviewText = generate()
    }

    /// 启动对 config.yaml 的文件监听：FLClash 一切换机场/更新订阅都会重新生成它，
    /// 监听到变化就实时刷新出口组显示 + 已有规则状态（订阅更新冲掉标记块时 UI 也能跟上）。
    func startWatchingConfig() {
        configWatcher?.cancel()
        configWatcher = nil
        let fd = open(configPath, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            // 防抖 0.5s：FLClash 可能短时间多次重写
            self.configWatchWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.refreshProxyTarget()
                self.refreshHasWrittenRules()
                self.checkPrerequisites()
                // 开关开着时同步规则显示（标记块被外部冲掉 → 全部回到「原规则」）
                if self.appRoutingEnabled { self.loadAppliedPolicies() }
            }
            self.configWatchWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
            // FLClash 原子写（rename）后原 fd 失效，重新建立监听
            self.startWatchingConfig()
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        configWatcher = src
    }

    /// 改动直连/代理后自动生效（防抖 1.2s，避免连续点触发多次重载）
    func scheduleApply() {
        // 策略刚变，先把派生缓存刷新掉（预览/计数用的是缓存，不刷会显示旧值）
        refreshDerived()
        guard appRoutingEnabled else { return }
        applyWorkItem?.cancel()
        statusMessage = "已修改，即将生效…"
        let work = DispatchWorkItem { [weak self] in
            DispatchQueue.main.async { self?.applyToConfig() }
        }
        applyWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    /// 总开关切换（仅由 UI Toggle 触发；内部直接改 appRoutingEnabled 不会走这里，避免循环）
    func setAppRoutingEnabled(_ on: Bool) {
        guard appRoutingEnabled != on else { return }
        applyWorkItem?.cancel()
        applyWorkItem = nil
        appRoutingEnabled = on
        if !on {
            // 关闭 = 恢复原机场配置（有标记块才需要清）
            if hasWrittenRules {
                restore()
            } else {
                statusMessage = "已切回原有机场规则"
            }
        } else {
            // 打开：重新读一遍现有规则，让显示与实际一致
            refreshHasWrittenRules()
            loadAppliedPolicies()
            statusMessage = "已开启 App 规则，改动会立即生效"
        }
    }

    /// 从激活 profile 的标记块读取已生效的 PROCESS-NAME 规则，映射回各 App 的原规则/直连/代理显示。
    /// 规则目标为 DIRECT → 直连；为出口组 → 代理。标记块不存在时全部重置为「原规则」。
    func loadAppliedPolicies() {
        // 无论哪条分支退出（读完 / 标记块不存在全部重置 / 读不到文件），都要同步派生缓存
        defer { refreshDerived() }
        guard let profilePath = activeProfilePath(),
              let text = try? String(contentsOfFile: profilePath, encoding: .utf8) else { return }
        let lines = text.components(separatedBy: "\n")
        guard let s = lines.firstIndex(where: { $0.contains(markerStart) }) else {
            // 标记块不存在（如被订阅更新冲掉）：全部显示为「原规则」
            for i in apps.indices { apps[i].policy = .origin }
            return
        }
        var e = s
        while e < lines.count, !lines[e].contains(markerEnd) { e += 1 }
        guard e < lines.count else { return }
        var proxies = Set<String>()
        var directs = Set<String>()
        for i in s...e {
            var t = lines[i].trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("-") else { continue }
            t = t.dropFirst().trimmingCharacters(in: .whitespaces)
            // 兼容规则被引号包裹的情况（FLClash 重新序列化 profile 时可能加 "- "PROCESS-NAME,...""）
            t = t.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            // 两种规则都要认：PROCESS-NAME,<名> 与 PROCESS-PATH,<全路径>
            var key: String? = nil
            var target = ""
            if t.hasPrefix("PROCESS-NAME,") {
                let parts = t.components(separatedBy: ",")
                if parts.count >= 3 { key = String(parts[1]); target = parts[2] }
            } else if t.hasPrefix("PROCESS-PATH,") {
                let parts = t.components(separatedBy: ",")
                if parts.count >= 3 {
                    key = (parts[1] as NSString).lastPathComponent  // 用 basename 匹配回 App
                    target = parts[2]
                }
            }
            if let k = key, !k.isEmpty {
                if target == "DIRECT" { directs.insert(k) } else { proxies.insert(k) }
            }
        }
        for i in apps.indices {
            // 主进程名或任一嵌套子进程名命中规则，都算该 App 被设置
            let names = [apps[i].executableName] + apps[i].extraProcs.map { $0.name }
            if names.contains(where: { proxies.contains($0) }) { apps[i].policy = .proxy }
            else if names.contains(where: { directs.contains($0) }) { apps[i].policy = .direct }
            else { apps[i].policy = .origin }
        }
    }

    private let flclashDir =
        NSString(string: "~/Library/Application Support/com.follow.clash")
        .expandingTildeInPath
    private let profilesDir: String = {
        let d = NSString(string: "~/Library/Application Support/com.follow.clash")
            .expandingTildeInPath
        return (d as NSString).appendingPathComponent("profiles")
    }()
    private let configPath: String = {
        let d = NSString(string: "~/Library/Application Support/com.follow.clash")
            .expandingTildeInPath
        return (d as NSString).appendingPathComponent("config.yaml")
    }()
    private let markerStart = "# >>> FlClashAppRouter"
    private let markerEnd = "# <<< FlClashAppRouter"

    /// 启动后自动扫描所有已安装 App（不限于 /Applications，递归扫 /Applications、/System/Applications、~/Applications）。
    /// 在后台线程跑，避免界面卡顿；结果回到主线程赋值给 apps。
    /// force=true 时忽略磁盘缓存强制重新枚举（「重新扫描」菜单走这里）。
    /// 修复前：scan() 只要缓存存在就直接返回缓存，导致「重新扫描」按钮装了新 App 后永远刷不出新列表。
    func scan(force: Bool = false) {
        guard !isScanning else { return }
        isScanning = true
        DispatchQueue.global(qos: .userInitiated).async {
            // 1) 非强制时先加载上次的磁盘缓存（秒开：不重新枚举 + 不做 Mach-O 检测）
            if !force, let cached = Self.readDiskCache() {
                DispatchQueue.main.async { self.finishScan(cached) }
                return
            }
            // 2) 无缓存 / 强制刷新：全量扫描
            let result = Self.performFullScan()
            // 3) 写磁盘缓存（下次启动秒开）
            Self.writeDiskCache(result)
            DispatchQueue.main.async { self.finishScan(result) }
        }
    }

    /// 扫描收尾（主线程）：统一刷新状态、派生缓存与文件监听
    private func finishScan(_ result: [AppEntry]) {
        apps = result
        isScanning = false
        refreshHasWrittenRules()
        refreshProxyTarget()
        checkPrerequisites()
        // 内部 defer 会调 refreshDerived()，无需再调一次
        loadAppliedPolicies()
        startWatchingConfig()
        startPeriodicRefresh()
    }

    /// 全量扫描所有目录，返回 AppEntry 列表
    private static func performFullScan() -> [AppEntry] {
        let home = NSHomeDirectory()
        let dirs = [
            "/Applications",
            "/System/Applications",
            (home as NSString).appendingPathComponent("Applications")
        ]
        var entries: [AppEntry] = []
        for dir in dirs {
            entries.append(contentsOf: scanDir(dir))
        }
        entries.sort {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        // 按 app 路径去重（不能按进程名——WorkBuddy/Trae CN/WorkBuddy AI 主进程都叫 Electron，
        // 按进程名去重会把这些 App 整个删掉，用户根本看不到它们）
        var seenPaths = Set<String>()
        var result = entries.filter { seenPaths.insert($0.path).inserted }
        // 冲突检测：同一进程名被多个不同 App 引用（Electron、chrome_crashpad_handler、Updater…），
        // 这些进程必须改用 PROCESS-PATH 全路径规则，否则给一个 App 分流会连累别的 App
        var nameOwnerCount: [String: Int] = [:]
        for e in result {
            nameOwnerCount[e.executableName, default: 0] += 1
            for p in e.extraProcs { nameOwnerCount[p.name, default: 0] += 1 }
        }
        let conflicts = Set(nameOwnerCount.filter { $0.value > 1 }.keys)
        result = result.map { e in
            var e2 = e
            e2.conflictingNames = conflicts
            return e2
        }
        return result
    }

    // ── 磁盘缓存：App 列表持久化，二次启动免重扫 ──
    private static func cachePath() -> String {
        let dir = NSString(string: "~/Library/Caches/FlClashAppRouter").expandingTildeInPath
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        return (dir as NSString).appendingPathComponent("apps_cache.json")
    }

    private static func readDiskCache() -> [AppEntry]? {
        let path = cachePath()
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        var out: [AppEntry] = []
        for d in arr {
            guard let name = d["name"] as? String,
                  let p = d["path"] as? String,
                  let exec = d["exec"] as? String,
                  let mainPath = d["mainPath"] as? String else { continue }
            var extra: [ProcSpec] = []
            if let es = d["extra"] as? [[String: String]] {
                for e in es {
                    if let n = e["name"], let pp = e["path"] {
                        extra.append(ProcSpec(name: n, path: pp))
                    }
                }
            }
            var conflict: Set<String> = []
            if let cs = d["conflicts"] as? [String] { conflict = Set(cs) }
            let icon = smallIcon(for: p)
            out.append(
                AppEntry(
                    name: name, path: p, executableName: exec,
                    mainProcPath: mainPath, extraProcs: extra,
                    conflictingNames: conflict, icon: icon))
        }
        return out
    }

    private static func writeDiskCache(_ entries: [AppEntry]) {
        let arr: [[String: Any]] = entries.map { e in
            [
                "name": e.name, "path": e.path, "exec": e.executableName,
                "mainPath": e.mainProcPath,
                "extra": e.extraProcs.map { ["name": $0.name, "path": $0.path] },
                "conflicts": Array(e.conflictingNames),
            ]
        }
        if let data = try? JSONSerialization.data(
            withJSONObject: arr, options: [.prettyPrinted]) {
            try? data.write(to: URL(fileURLWithPath: cachePath()))
        }
    }

    /// 检查激活 profile 里是否已有本工具写入的标记块（决定「恢复」按钮可用性）
    func refreshHasWrittenRules() {
        guard let profilePath = activeProfilePath(),
              let text = try? String(contentsOfFile: profilePath, encoding: .utf8) else {
            hasWrittenRules = false
            return
        }
        hasWrittenRules = text.contains(markerStart)
    }

    /// 递归收集目录下的 .app（深度上限 8，避免异常目录导致无限下钻）
    /// 递归收集目录下的 .app（深度上限 8，避免异常目录导致无限下钻）
    private static func scanDir(_ dir: String, depth: Int = 0) -> [AppEntry] {
        guard depth < 8 else { return [] }
        var out: [AppEntry] = []
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: dir) else { return out }
        var appPaths: [String] = []
        var subDirs: [String] = []
        for item in items {
            let full = (dir as NSString).appendingPathComponent(item)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &isDir) else { continue }
            if item.hasSuffix(".app") { appPaths.append(full) }
            else if isDir.boolValue { subDirs.append(full) }
        }
        // 子目录递归（继续深度优先，保持顺序稳定）
        for sub in subDirs {
            out.append(contentsOf: scanDir(sub, depth: depth + 1))
        }
        // 同一目录下的 app 并行收集（每个 app 的嵌套子进程/Mach-O 检测独立，可安全并行）
        if appPaths.count > 3 {
            let lock = NSLock()
            var results: [Int: [AppEntry]] = [:]
            DispatchQueue.concurrentPerform(iterations: appPaths.count) { i in
                let entry = AppRouterModel.shared.makeEntry(at: appPaths[i])
                lock.lock()
                results[i] = [entry]
                lock.unlock()
            }
            for i in 0..<appPaths.count {
                if let e = results[i] { out.append(contentsOf: e) }
            }
        } else {
            for p in appPaths {
                out.append(AppRouterModel.shared.makeEntry(at: p))
            }
        }
        return out
    }

    /// 取「显示给用户的名称」：Finder/Launchpad 实际显示名（如 WeChat.app → 微信、BaiduNetdisk.app → 百度网盘）。
    /// 来源：app 本地化的 Contents/Resources/<语言>.lproj/InfoPlist.strings 里的
    /// CFBundleDisplayName / CFBundleName（与 Spotlight/Finder 完全一致），回退链：
    /// 本地化 CFBundleDisplayName → 本地化 CFBundleName → 顶层 Info.plist → .app 文件夹名。
    private func lprojCandidates(for lang: String) -> [String] {
        let segs = lang.components(separatedBy: "-")
        var cands = Set<String>()
        for sep in ["-", "_"] {
            var parts = segs
            while !parts.isEmpty {
                cands.insert(parts.joined(separator: sep) + ".lproj")
                parts.removeLast()
            }
        }
        // 语言+地区组合（跳过中间 script），如 zh-Hans-CN -> zh_CN.lproj（百度网盘用法）
        if segs.count >= 2 {
            let base = segs.first!
            let region = segs.last!
            cands.insert("\(base)_\(region).lproj")
            cands.insert("\(base)-\(region).lproj")
        }
        return Array(cands)
    }

    private func localizedBundleValue(_ key: String, forAppAt path: String) -> String? {
        let preferred = Locale.preferredLanguages
        let resources = (path as NSString).appendingPathComponent("Contents/Resources")
        for lang in preferred {
            for c in lprojCandidates(for: lang) {
                let cPath = (resources as NSString).appendingPathComponent(c)
                let sp = (cPath as NSString).appendingPathComponent("InfoPlist.strings")
                if let dict = NSDictionary(contentsOfFile: sp),
                   let v = dict[key] as? String, !v.isEmpty {
                    return v
                }
            }
        }
        return nil
    }

    /// 取 Spotlight / Finder 显示名（kMDItemDisplayName），即用户在 Finder/Launchpad 看到的真实名称。
    /// 系统 App 的本地化名不写在 bundle 内、而由 Spotlight 索引提供，所以这是最权威、覆盖最全的来源。
    private func spotlightDisplayName(for path: String) -> String? {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString) else { return nil }
        guard let raw = MDItemCopyAttribute(item, kMDItemDisplayName) as? String else {
            return nil
        }
        if raw.hasSuffix(".app") { return String(raw.dropLast(4)) }
        return raw.isEmpty ? nil : raw
    }

    private func displayName(for path: String) -> String {
        // 1) Spotlight 显示名（Finder 真名，系统/第三方 App 全覆盖）
        if let s = spotlightDisplayName(for: path), !s.isEmpty { return s }
        // 2) 回退链：本地化 CFBundleDisplayName → 本地化 CFBundleName → 顶层 Info.plist → .app 文件夹名
        if let d = localizedBundleValue("CFBundleDisplayName", forAppAt: path), !d.isEmpty {
            return d
        }
        if let n = localizedBundleValue("CFBundleName", forAppAt: path), !n.isEmpty { return n }
        let infoPath = (path as NSString).appendingPathComponent("Contents/Info.plist")
        if let plist = NSDictionary(contentsOfFile: infoPath) {
            if let d = plist["CFBundleDisplayName"] as? String, !d.isEmpty { return d }
            if let n = plist["CFBundleName"] as? String, !n.isEmpty { return n }
        }
        return (path as NSString).deletingPathExtension.components(separatedBy: "/").last
            ?? (path as NSString).lastPathComponent
    }

    private func makeEntry(at path: String) -> AppEntry {
        let displayName = displayName(for: path)
        // 图标预缩放：NSWorkspace 返回的是 512px 大图，列表每行每次重绘都缩放很卡。
        // 这里一次缩到 32px 小图缓存，滚动重绘几乎零开销
        let icon = Self.smallIcon(for: path)
        // 进程名来自 CFBundleExecutableName（标准键）；少数 App（如微信）用旧键 CFBundleExecutable，
        // 两个都要读，否则回退成显示名会导致 PROCESS-NAME 规则匹配不到真实进程、分流失效。
        var exec = displayName
        let infoPath = (path as NSString).appendingPathComponent("Contents/Info.plist")
        if let plist = NSDictionary(contentsOfFile: infoPath),
           let e = (plist["CFBundleExecutableName"] ?? plist["CFBundleExecutable"])
               as? String, !e.isEmpty {
            exec = e
        }
        let macOSDir = (path as NSString).appendingPathComponent("Contents/MacOS")
        return AppEntry(
            name: displayName, path: path, executableName: exec,
            mainProcPath: (macOSDir as NSString).appendingPathComponent(exec),
            extraProcs: nestedProcesses(at: path, excluding: exec),
            conflictingNames: [], icon: icon)
    }

    /// 取 32px 预缩放图标（带小尺寸缓存，避免重复缩放）
    private static var iconCache: [String: NSImage] = [:]
    /// 并发保护：scanDir 用 DispatchQueue.concurrentPerform 多线程调 makeEntry，
    /// 若不加锁，多个线程同时读写 iconCache 字典会触发 Swift 容器数据竞争（可能崩溃/读到野值）。
    private static let iconLock = NSLock()
    private static func smallIcon(for path: String) -> NSImage {
        iconLock.lock()
        defer { iconLock.unlock() }
        if let cached = iconCache[path] { return cached }
        let big = NSWorkspace.shared.icon(forFile: path)
        let small = big.resized(to: NSSize(width: 32, height: 32))
        iconCache[path] = small
        return small
    }

    /// 收集 app bundle 内嵌的全部子进程（名 + 完整路径）。
    /// 覆盖三类（本机 138 个 App 实测 53 个有子进程）：
    ///  1. 嵌套 .app（递归进内部——微信 WeChatAppEx.app 里还有 WeChatAppEx Helper)
    ///  2. .xpc / .appex 服务（XPC 服务常直接发网络请求）
    ///  3. 裸 Mach-O 可执行文件（crashpad_handler、Updater、ShipIt 等，用 filetype==2 精确识别，
    ///     dylib/静态库不会误判）
    private func nestedProcesses(at path: String, excluding mainExec: String) -> [ProcSpec] {
        var result: [ProcSpec] = []
        var seen: Set<String> = [mainExec]
        collectNested(in: path, depth: 0, seen: &seen, result: &result)
        return result
    }

    private func collectNested(
        in bundlePath: String, depth: Int, seen: inout Set<String>, result: inout [ProcSpec]
    ) {
        guard depth < 4 else { return }
        let contents = (bundlePath as NSString).appendingPathComponent("Contents")
        let roots = ["Frameworks", "MacOS", "XPCServices", "Library"].map {
            (contents as NSString).appendingPathComponent($0)
        }
        let fm = FileManager.default
        for root in roots {
            guard let en = fm.enumerator(atPath: root) else { continue }
            var visited = 0
            for case let item as String in en {
                visited += 1
                if visited > 3000 { break }  // 防御超大 bundle
                let full = (root as NSString).appendingPathComponent(item)
                if item.hasSuffix(".app") || item.hasSuffix(".xpc") || item.hasSuffix(".appex") {
                    en.skipDescendants()
                    if let e = Self.readBundleExec(full), seen.insert(e).inserted {
                        result.append(
                            ProcSpec(
                                name: e,
                                path: Self.macOSPath(in: full, exec: e)))
                    }
                    // 嵌套 .app 递归进内部（WeChatAppEx.app 内含 WeChatAppEx Helper)
                    if item.hasSuffix(".app") {
                        collectNested(in: full, depth: depth + 1, seen: &seen, result: &result)
                    }
                } else if item.hasSuffix(".dylib") || item.hasSuffix(".a") {
                    en.skipDescendants()
                } else {
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue,
                       fm.isExecutableFile(atPath: full), Self.isMachOExecutable(full) {
                        let name = (item as NSString).lastPathComponent
                        if seen.insert(name).inserted {
                            result.append(ProcSpec(name: name, path: full))
                        }
                    }
                }
            }
        }
    }

    private static func macOSPath(in bundle: String, exec: String) -> String {
        ((bundle as NSString).appendingPathComponent("Contents/MacOS") as NSString)
            .appendingPathComponent(exec)
    }

    /// 读 bundle 的执行文件名（标准键 + 旧键兜底）
    private static func readBundleExec(_ bundlePath: String) -> String? {
        let ip = (bundlePath as NSString).appendingPathComponent("Contents/Info.plist")
        guard let plist = NSDictionary(contentsOfFile: ip),
              let e = (plist["CFBundleExecutableName"] ?? plist["CFBundleExecutable"]) as? String,
              !e.isEmpty else { return nil }
        return e
    }

    /// Mach-O 可执行文件检测（thin 32/64 + fat universal，filetype==2 即 MH_EXECUTE）
    private static func isMachOExecutable(_ path: String) -> Bool {
        guard let fh = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? fh.close() }
        guard let data = try? fh.read(upToCount: 16), data.count >= 16 else { return false }
        var magic: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &magic) { data.copyBytes(to: $0, from: 0..<4) }
        if magic == 0xFEEDFACF || magic == 0xFEEDFACE {  // thin
            var ft: UInt32 = 0
            _ = withUnsafeMutableBytes(of: &ft) { data.copyBytes(to: $0, from: 12..<16) }
            return ft == 2
        }
        if magic == 0xCAFEBABE {  // fat（big endian），读第一个 arch 的 thin header
            var offset: UInt32 = 0
            _ = withUnsafeMutableBytes(of: &offset) { data.copyBytes(to: $0, from: 12..<16) }
            offset = offset.byteSwapped
            try? fh.seek(toOffset: UInt64(offset))
            guard let d2 = try? fh.read(upToCount: 16), d2.count >= 16 else { return false }
            var m2: UInt32 = 0
            _ = withUnsafeMutableBytes(of: &m2) { d2.copyBytes(to: $0, from: 0..<4) }
            guard m2 == 0xFEEDFACF || m2 == 0xFEEDFACE else { return false }
            var ft: UInt32 = 0
            _ = withUnsafeMutableBytes(of: &ft) { d2.copyBytes(to: $0, from: 12..<16) }
            return ft == 2
        }
        return false
    }

    // MARK: - 激活 profile 解析

    /// FLClash 实际加载的「激活 profile」文件路径。
    /// 关键：FLClash 在启动时从激活 profile 重新生成 config.yaml，所以直接写 config.yaml 会在重载后被覆盖，
    /// 恢复也会找不到标记块。本工具必须写进「激活 profile」文件本身。
    /// 激活 profile 的 id 存于 UserDefaults(com.follow.clash) 的 flutter.config.currentProfileId。
    /// 读不到时退化为「与当前 config.yaml 的代理组最匹配的那个 profile 文件」。
    private func activeProfilePath() -> String? {
        if let id = currentProfileIdFromDefaults() {
            let p = (profilesDir as NSString).appendingPathComponent("\(id).yaml")
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        // 退化：找与 config.yaml 代理组最匹配的 profile
        if let groups = proxyGroupNames(from: configPath), !groups.isEmpty {
            var best: (path: String, score: Int)? = nil
            if let files = try? FileManager.default.contentsOfDirectory(atPath: profilesDir) {
                for f in files where f.hasSuffix(".yaml") {
                    let fp = (profilesDir as NSString).appendingPathComponent(f)
                    guard let txt = try? String(contentsOfFile: fp, encoding: .utf8) else {
                        continue
                    }
                    let score = groups.reduce(0) { $0 + (txt.contains($1) ? 1 : 0) }
                    if score > (best?.score ?? 0) { best = (fp, score) }
                }
            }
            if let best { return best.path }
        }
        return nil
    }

    /// 读取 FLClash 的 UserDefaults(com.follow.clash → flutter.config) 并解析成字典。
    /// 这是 FLClash **自己保存的设置**，比 config.yaml 更可信——实测 config.yaml 里的
    /// `mode` 字段会与实际运行状态不符（写着 direct，但流量确实走了代理），
    /// 而 patchClashConfig 里的 mode / tun / find-process-mode 与实测行为完全一致。
    private var cachedConfigRaw: String?
    private var cachedConfigJSON: [String: Any]?

    private func flclashConfigJSON() -> [String: Any]? {
        // 直接读 UserDefaults（走 cfprefsd），不再 spawn /usr/bin/defaults 子进程。
        // 本函数现在会被 2 秒一次的轮询调用，spawn 子进程太贵；UserDefaults 读是内存级开销。
        // synchronize() 强制从 cfprefsd 重新取值，避免读到本进程内的旧缓存
        // （FLClash 在另一个进程里改设置，不 sync 可能一直读到旧值 → 界面不刷新）。
        guard let suite = UserDefaults(suiteName: "com.follow.clash") else { return nil }
        _ = suite.synchronize()
        guard let raw = suite.string(forKey: "flutter.config"), !raw.isEmpty else { return nil }
        // 内容没变就复用上次解析结果，避免每 2 秒重复 JSON 解析 4.8KB
        if raw == cachedConfigRaw, let cached = cachedConfigJSON { return cached }
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        cachedConfigRaw = raw
        cachedConfigJSON = obj
        return obj
    }

    /// FLClash 自己保存的 patchClashConfig —— 模式(mode)、TUN、find-process-mode 都在这里
    private func flclashPatch() -> [String: Any]? {
        flclashConfigJSON()?["patchClashConfig"] as? [String: Any]
    }

    /// 从 UserDefaults(com.follow.clash) flutter.config 取 currentProfileId
    private func currentProfileIdFromDefaults() -> Int64? {
        guard let obj = flclashConfigJSON() else { return nil }
        return obj["currentProfileId"] as? Int64
    }

    /// 从某个 YAML 文本里收集 proxy-groups: 段下的所有组名
    private func proxyGroupNames(from path: String) -> [String]? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }
        return proxyGroupNames(in: text.components(separatedBy: "\n"))
    }

    /// 从一行里提取 name: 的值，兼容三种写法：
    ///   - 双引号：name: "Foo"
    ///   - 单引号：name: '美国 洛杉矶 - US07'   （常见机场 profile）
    ///   - 无引号：name: OneLighter            （流样式 - { name: OneLighter, ... }）
    ///   - 流样式：proxy-groups: 下多是 `- { name: X, type: select, ... }`
    private func extractName(_ line: String) -> String? {
        guard let r = line.range(of: #"name:\s*"#, options: .regularExpression) else {
            return nil
        }
        var after = String(line[r.upperBound...])
        // 双引号：去掉前引号后找下一个同种引号（支持行尾结束，引号内含逗号/空格安全）
        if after.hasPrefix("\"") {
            after.removeFirst()
            if let q = after.firstIndex(of: "\"") {
                let v = String(after[after.startIndex..<q])
                if !v.isEmpty { return v }
            }
        }
        // 单引号：同上（机场节点名 '美国 洛杉矶 - US07' 走这里，行尾结束也能取全）
        if after.hasPrefix("'") {
            after.removeFirst()
            if let q = after.firstIndex(of: "'") {
                let v = String(after[after.startIndex..<q])
                if !v.isEmpty { return v }
            }
        }
        // 裸词（组名带空格的都已加引号，所以裸词不含空格/逗号/右花括号）
        if let end = after.firstIndex(where: {
            ",}".contains($0) || $0.isWhitespace
        }) {
            let w = String(after[after.startIndex..<end])
            if !w.isEmpty { return w }
        }
        // 裸词行尾结束（无分隔符），取整行
        let tail = after.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { return tail }
        return nil
    }

    private func proxyGroupNames(in lines: [String]) -> [String] {
        var groups: [String] = []
        var inGroups = false
        for line in lines {
            if line == "proxy-groups:" { inGroups = true; continue }
            if inGroups {
                if line.hasPrefix("proxy-providers:")
                    || line.hasPrefix("rules:")
                    || line.hasPrefix("tun:")
                    || line.hasPrefix("profile:") { break }
                // 展开式 `- name: "X"` 与流样式 `- { name: X, ... }` 都走 extractName
                if line.contains("name:") {
                    if let n = extractName(line) { groups.append(n) }
                }
            }
        }
        return groups
    }

    /// 探测目标文件 rules: 段下规则条目的缩进（profile 多为 4 空格，config.yaml 为 2 空格），
    /// 插入的标记块必须用相同缩进，否则 YAML 非法导致 FLClash 拒载。
    private func ruleIndentation(in lines: [String]) -> String {
        if let ri = lines.firstIndex(where: { $0 == "rules:" }) {
            for i in (ri + 1)..<lines.count {
                let l = lines[i]
                if l.hasPrefix("proxy-providers:")
                    || l.hasPrefix("proxy-groups:")
                    || l.hasPrefix("tun:")
                    || l.hasPrefix("profile:") { break }
                if l.range(of: #"^\s*-\s"#, options: .regularExpression) != nil {
                    if let r = l.range(of: #"^\s*"#, options: .regularExpression) {
                        return String(l[r])
                    }
                }
            }
        }
        return "  "
    }

    /// 从「激活 profile」（读不到时退化为 config.yaml）里找出「代理」策略应指向的真实代理组名。
    /// 很多机场配置的主组不叫 Proxy（如本机的 OneLighter），写错组名会导致 Mihomo 拒绝加载整个配置。
    private func resolveProxyTarget() -> String {
        let target = activeProfilePath() ?? configPath
        guard let text = try? String(contentsOfFile: target, encoding: .utf8) else {
            return "Proxy"
        }
        let lines = text.components(separatedBy: "\n")
        let groups = proxyGroupNames(in: lines)
        guard !groups.isEmpty else { return "Proxy" }
        // 在 rules: 段里统计哪个组被引用最多 → 即默认出口组
        var inRules = false
        var counts: [String: Int] = [:]
        for line in lines {
            if line.hasPrefix("rules:") { inRules = true; continue }
            if inRules {
                if line.hasPrefix("tun:")
                    || line.hasPrefix("profile:")
                    || line.hasPrefix("sniffer:") { break }
                for g in groups where line.contains(",\(g)") {
                    counts[g, default: 0] += 1
                }
            }
        }
        if let top = counts.max(by: { $0.value < $1.value })?.key {
            return top
        }
        return groups.first!
    }

    /// 实时生成规则文本（预览和「写进」都用它；无自定义 App 时返回友好提示）
    /// 出口组用缓存的 proxyTargetName（由 scan / config 文件监听 / 写入 / 恢复维护），
    /// **不在这里读文件**——本函数被界面每次重绘调用，实时读两个大 YAML 会让列表滚动卡顿。
    /// 缓存刷新时机覆盖了所有可能变化的场景（机场切换、订阅更新、写入、恢复）。
    /// 注意：本函数必须是纯函数——不能在里面写 @Published，否则界面每次重绘调用它时
    /// 会修改被观察对象，触发 SwiftUI 无限重渲染（CPU 空转）。
    func generate() -> String {
        let target = proxyTargetName
        let routed = apps.filter { $0.policy != .origin }
        guard !routed.isEmpty else {
            return
                "# 所有 App 都走「原规则」\n# 把某个 App 改成「直连」或「代理」，这里会实时生成 PROCESS-NAME 规则"
        }
        var lines = [
            "# Generated by FlClashAppRouter — 按软件(进程)分流",
            "# 需 FLClash 开启 TUN 且 find-process-mode: strict/always",
            "# 「代理」目标组: \(target)  (由激活 profile 自动识别)",
            "# 进程名由 CFBundleExecutableName 映射；同名进程(多 App 共用)自动改用 PROCESS-PATH 精确匹配"
        ]
        // 进程名被多个 App 共用时必须用 PROCESS-PATH 全路径规则，
        // 否则给一个 App 分流会连累所有同名进程（如 3 个 Electron 应用互相串扰）。
        // 路径含逗号时回退 PROCESS-NAME（逗号会破坏规则解析，串扰总比配置非法好）。
        func rule(_ name: String, path: String, conflict: Bool, target: String) -> String {
            if conflict && !path.contains(",") {
                return "- PROCESS-PATH,\(path),\(target)"
            }
            return "- PROCESS-NAME,\(name),\(target)"
        }
        for app in routed {
            // 代理 → 出口组；直连 → DIRECT（真正直连，不走代理）
            let t = app.policy == .proxy ? target : "DIRECT"
            let conflict = app.conflictingNames.contains(app.executableName)
            lines.append(rule(app.executableName, path: app.mainProcPath, conflict: conflict, target: t))
            // 嵌套子进程（Chromium Helper / 微信组件等）必须一并写，否则主进程规则形同虚设
            for extra in app.extraProcs {
                lines.append(
                    rule(
                        extra.name, path: extra.path,
                        conflict: app.conflictingNames.contains(extra.name), target: t))
            }
        }
        return lines.joined(separator: "\n")
    }

    /// 写进「激活 profile」的 rules: 段（带标记块，重复写入会先清旧块）。
    /// 现在由 scheduleApply 防抖自动触发（改动立即生效），不再有手动「写进」按钮。
    func applyToConfig() {
        applyWorkItem?.cancel()
        applyWorkItem = nil
        guard appRoutingEnabled else { return }
        // 上一次重载还没完：推迟到重载结束后再生效，避免 kill 掉正在启动的 FLClash
        if isReloading {
            scheduleApply()
            return
        }
        // 写前刷新出口组缓存：generate() 改成用缓存（避免界面重绘读文件卡顿），
        // 这里必须保证缓存是当前机场的，否则机场切换后会把旧组名写进配置
        refreshProxyTarget()
        generatedRules = generate()
        guard let profilePath = activeProfilePath() else {
            statusMessage =
                "无法确定 FLClash 当前激活的 profile（UserDefaults 与 profiles 均未匹配）。请确认 FLClash 已至少启动过一次。"
            return
        }
        guard let text = try? String(contentsOfFile: profilePath, encoding: .utf8) else {
            statusMessage = "找不到激活 profile: \(profilePath)"
            return
        }
        var lines = text.components(separatedBy: "\n")
        // 先移除已存在的本工具块
        if let idx = lines.firstIndex(where: { $0.contains(markerStart) }) {
            var end = idx
            while end < lines.count, !lines[end].contains(markerEnd) { end += 1 }
            if end < lines.count {
                lines.removeSubrange(idx...end)
            } else {
                lines.remove(at: idx) // 标记块残缺（缺结束标记），仅移除悬空起始注释行
            }
        }
        guard let rulesIdx = lines.firstIndex(where: { $0.hasPrefix("rules:") }) else {
            statusMessage =
                "激活 profile 里没有 rules: 段，无法写入。请换用含 rules 的 profile，或手动添加。"
            return
        }
        let n = apps.filter { $0.policy != .origin }.count
        if n > 0 {
            // 用目标文件真实的 rules 缩进（profile 多为 4 空格），插入块须一致，否则 YAML 非法
            let indent = ruleIndentation(in: lines)
            // 只取真正的规则行（过滤注释头），比按固定行数 dropFirst 更健壮
            let ruleLines = generatedRules.components(separatedBy: "\n")
                .filter { $0.hasPrefix("- PROCESS-NAME,") || $0.hasPrefix("- PROCESS-PATH,") }
            let block =
                [indent + markerStart]
                + ruleLines.map { indent + $0 }
                + [indent + markerEnd]
            lines.insert(contentsOf: block, at: rulesIdx + 1)
        }
        do {
            try lines.joined(separator: "\n").write(
                toFile: profilePath, atomically: true, encoding: .utf8)
            let name = (profilePath as NSString).lastPathComponent
            hasWrittenRules = (n > 0)
            refreshProxyTarget()
            isReloading = true
            statusMessage =
                (n == 0
                    ? "全部直连，已清理之前写入的规则"
                    : "已写入 \(n) 条规则到激活 profile (\(name))")
                + "，正在重载 FLClash…"
            DispatchQueue.global(qos: .background).async { self.reloadFlClash() }
        } catch {
            statusMessage = "写入失败: \(error.localizedDescription)"
        }
    }

    /// 恢复：移除「激活 profile」里本工具写入的标记块，让配置回到写入前的状态。
    /// 成功后回到「原有规则」模式：开关跳关、所有 App 显示重置为直连。
    func restore() {
        applyWorkItem?.cancel()
        applyWorkItem = nil
        guard let profilePath = activeProfilePath() else {
            statusMessage =
                "无法确定 FLClash 当前激活的 profile（UserDefaults 与 profiles 均未匹配）。请确认 FLClash 已至少启动过一次。"
            return
        }
        guard let text = try? String(contentsOfFile: profilePath, encoding: .utf8) else {
            statusMessage = "找不到激活 profile: \(profilePath)"
            return
        }
        var lines = text.components(separatedBy: "\n")
        guard let idx = lines.firstIndex(where: { $0.contains(markerStart) }) else {
            statusMessage = "激活 profile 里没有本工具写入的规则，无需恢复"
            return
        }
        var end = idx
        while end < lines.count, !lines[end].contains(markerEnd) { end += 1 }
        guard end < lines.count else {
            statusMessage = "标记块不完整（缺少结束标记），未改动配置，请手动检查"
            return
        }
        lines.removeSubrange(idx...end)
        do {
            try lines.joined(separator: "\n").write(
                toFile: profilePath, atomically: true, encoding: .utf8)
            generatedRules = ""
            let name = (profilePath as NSString).lastPathComponent
            hasWrittenRules = false
            refreshProxyTarget()
            // 恢复原配置后：回到「原有规则」模式，所有 App 显示重置为「原规则」
            appRoutingEnabled = false
            for i in apps.indices { apps[i].policy = .origin }
            refreshDerived()
            isReloading = true
            statusMessage =
                "已恢复：移除了本工具写入的规则（profile \(name)），正在重载 FLClash…"
            DispatchQueue.global(qos: .background).async { self.reloadFlClash() }
        } catch {
            statusMessage = "恢复失败: \(error.localizedDescription)"
        }
    }

    /// 检测 FLClash 当前设置能否让「按软件分流」真正生效。三项缺一不可：
    ///   ① TUN 模式开启 —— 不开 TUN，很多 App 的流量根本不进内核
    ///   ② find-process-mode 为 always/strict —— 为 off 时内核不做进程反查，规则永远不命中
    ///   ③ **模式为「规则」** —— 全局模式下所有流量都走代理、直连模式下全部不走代理，
    ///      这两种模式下 rules 段会被整体忽略，按软件分流形同虚设
    /// 数据源优先用 FLClash 自己的 patchClashConfig：实测 config.yaml 的 mode / tun 字段
    /// 都会滞后于实际状态（写 direct 但实际在走代理；写 tun.enable: true 但路由表里
    /// 没有任何指向 utun 的条目），patchClashConfig 才与实测行为一致。
    /// 结果写入 prereqIssues（拦截页）与 flclashStatusLabel（标题栏状态标签）。
    func checkPrerequisites() {
        var tunOK = false
        var tunKnown = false  // 读不到时不要误报「未开启」
        var fpmOK = false
        var fpmKnown = false
        var mode = ""
        var source = "patchClashConfig"

        if let patch = flclashPatch() {
            if let tun = patch["tun"] as? [String: Any], let e = tun["enable"] as? Bool {
                tunOK = e
                tunKnown = true
            }
            let fpm = (patch["find-process-mode"] as? String ?? "").lowercased()
            if !fpm.isEmpty {
                fpmOK = (fpm == "always" || fpm == "strict")
                fpmKnown = true
            }
            mode = (patch["mode"] as? String ?? "").lowercased()
        } else {
            // 退化：UserDefaults 读不到时，直接解析 config.yaml
            source = "config.yaml"
            guard let text = try? String(contentsOfFile: configPath, encoding: .utf8) else {
                let issues = [
                    PrereqIssue(
                        icon: "questionmark.folder",
                        title: "未检测到 FLClash 设置",
                        hint: "请先安装并至少启动一次 FLClash"
                            + "（https://github.com/chen08209/FlClash），再点「重新检测」。")
                ]
                applyPrereq(
                    issues: issues, label: "",
                    diagnostics: "未找到 UserDefaults 与 config.yaml", autoFixable: false)
                return
            }
            let lines = text.components(separatedBy: "\n")
            for l in lines {
                let t = l.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("find-process-mode:") {
                    let v = t.dropFirst("find-process-mode:".count)
                        .trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
                        .lowercased()
                    fpmOK = (v == "always" || v == "strict")
                    fpmKnown = true
                    break
                }
            }
            // tun.enable（只看 tun: 段内的缩进项，避免误读别处的 enable）
            if let ti = lines.firstIndex(where: {
                $0.trimmingCharacters(in: .whitespaces) == "tun:"
            }) {
                for i in (ti + 1)..<min(ti + 12, lines.count) {
                    let raw = lines[i]
                    let t = raw.trimmingCharacters(in: .whitespaces)
                    if t.isEmpty { continue }
                    if !raw.hasPrefix(" ") && !raw.hasPrefix("\t") { break }  // 回到顶层键 = 离开 tun 段
                    if t.hasPrefix("enable:") {
                        let v = t.dropFirst("enable:".count)
                            .trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
                            .lowercased()
                        tunOK = (v == "true")
                        tunKnown = true
                        break
                    }
                }
            }
            for l in lines {
                let t = l.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("mode:") {
                    mode = t.dropFirst("mode:".count)
                        .trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
                        .lowercased()
                    break
                }
            }
        }

        // 标题栏状态标签：模式 + TUN（识别不了就不显示）
        var parts: [String] = []
        switch mode {
        case "rule": parts.append("规则模式")
        case "global": parts.append("全局模式")
        case "direct": parts.append("直连模式")
        default: break
        }
        if tunKnown { parts.append(tunOK ? "TUN 已开" : "TUN 未开") }
        let newLabel = parts.joined(separator: " · ")

        // ── 构造「必须解决」的问题清单（每条都带具体修复步骤）──
        var issues: [PrereqIssue] = []
        if tunKnown && !tunOK {
            issues.append(
                PrereqIssue(
                    icon: "shield.slash",
                    title: "TUN 模式未开启",
                    hint: "打开 FLClash → 首页 → 打开「TUN」开关。不开 TUN，很多 App 的流量"
                        + "根本不进内核，进程规则永远不会命中。"))
        }
        if fpmKnown && !fpmOK {
            issues.append(
                PrereqIssue(
                    icon: "magnifyingglass",
                    title: "find-process-mode 为 off",
                    hint: "内核不会反查连接属于哪个进程，PROCESS-NAME 规则永远不命中。"
                        + "在 FLClash 的「覆写」里把它设为 strict 或 always。"))
        }
        if mode == "global" {
            issues.append(
                PrereqIssue(
                    icon: "globe.asia.australia.fill",
                    title: "当前是「全局模式」",
                    hint: "全局模式下所有流量都走代理，rules 段被整体忽略，按软件分流无效。"
                        + "请在 FLClash 首页把模式切到「规则」。"))
        } else if mode == "direct" {
            issues.append(
                PrereqIssue(
                    icon: "arrow.right.circle.fill",
                    title: "当前是「直连模式」",
                    hint: "直连模式下所有流量都不走代理，rules 段被整体忽略，按软件分流无效。"
                        + "请在 FLClash 首页把模式切到「规则」。"))
        }

        let diag = [
            "数据源: \(source)",
            "mode: \(mode.isEmpty ? "(未读到)" : mode)",
            "tun.enable: \(tunKnown ? (tunOK ? "true" : "false") : "(未读到)")",
            "find-process-mode: \(fpmKnown ? (fpmOK ? "ok" : "off") : "(未读到)")",
        ].joined(separator: "\n")
        applyPrereq(
            issues: issues, label: newLabel, diagnostics: diag,
            autoFixable: (source == "patchClashConfig"))
    }

    /// 把检测结果落到 @Published 上。**只在内容真的变化时才赋值**——
    /// 本函数被 1 秒轮询调用，无条件赋值会让整个界面每秒重绘一次；
    /// 而且 PrereqIssue 带 UUID，每次重建都会让 ForEach 认为全是新行。
    private func applyPrereq(
        issues: [PrereqIssue], label: String, diagnostics: String, autoFixable: Bool = true
    ) {
        let newSig = issues.map { $0.title }.joined(separator: "|")
        let oldSig = prereqIssues.map { $0.title }.joined(separator: "|")
        if newSig != oldSig { prereqIssues = issues }
        if flclashStatusLabel != label { flclashStatusLabel = label }
        if prereqDiagnostics != diagnostics { prereqDiagnostics = diagnostics }
        if prereqAutoFixable != autoFixable { prereqAutoFixable = autoFixable }
        if !prereqChecked { prereqChecked = true }
    }

    /// 打开 FLClash（拦截页的「打开 FLClash」按钮）
    func openFlClash() {
        guard let appPath = flclashAppPath() else { return }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-a", appPath]
        try? open.run()
    }

    /// 备份 FLClash 当前设置到缓存目录，返回备份路径（写坏时的还原依据）
    private func backupFlclashConfig() -> String? {
        guard let suite = UserDefaults(suiteName: "com.follow.clash"),
              let raw = suite.string(forKey: "flutter.config") else { return nil }
        let dir = NSString(string: "~/Library/Caches/FlClashAppRouter").expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = (dir as NSString).appendingPathComponent("flclash-config-backup.json")
        guard (try? raw.write(toFile: path, atomically: true, encoding: .utf8)) != nil else {
            return nil
        }
        return path
    }

    /// 改写 FLClash 的 patchClashConfig 并写回 UserDefaults，返回是否成功（带回读校验）。
    /// 已实测 JSON 往返完全保真：13 个顶层键、27 个 patch 键、Int64/Double/Bool 类型都不变。
    private func patchFlclashConfig(_ mutate: (inout [String: Any]) -> Void) -> Bool {
        guard let suite = UserDefaults(suiteName: "com.follow.clash") else { return false }
        _ = suite.synchronize()
        guard let raw = suite.string(forKey: "flutter.config"),
              let data = raw.data(using: .utf8),
              var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var patch = obj["patchClashConfig"] as? [String: Any]
        else { return false }
        mutate(&patch)
        obj["patchClashConfig"] = patch
        guard let out = try? JSONSerialization.data(withJSONObject: obj),
              let str = String(data: out, encoding: .utf8) else { return false }
        suite.set(str, forKey: "flutter.config")
        _ = suite.synchronize()
        // 缓存失效，立刻能读到新值
        cachedConfigRaw = nil
        cachedConfigJSON = nil
        // 回读校验：只核对本次改的关键字段是否真的落盘
        guard let check = flclashConfigJSON(),
              let cp = check["patchClashConfig"] as? [String: Any] else { return false }
        let m = (cp["mode"] as? String)?.lowercased()
        let f = (cp["find-process-mode"] as? String)?.lowercased()
        let t = (cp["tun"] as? [String: Any])?["enable"] as? Bool
        return m == "rule" && f == "always" && t == true
    }

    /// 自动修复：把 FLClash 的三项设置改成「能让按软件分流生效」的值，然后重启它。
    /// **顺序很关键：先退出 FLClash 再写设置**——FLClash 退出时会把内存里的设置写回
    /// UserDefaults，先写会被它覆盖。写完再拉起，它会用新设置重新生成 config.yaml。
    func autoFix() {
        guard !isAutoFixing else { return }
        isAutoFixing = true
        autoFixMessage = ""
        DispatchQueue.global(qos: .userInitiated).async {
            let backup = self.backupFlclashConfig()
            // 1) 先让 FLClash 完全退出，避免它退出时覆盖我们写入的值
            self.killProcess("FlClash")
            self.waitProcessGone("FlClash")
            self.killProcess("FlClashCore")
            self.waitProcessGone("FlClashCore")
            // 2) 写设置：TUN 开、find-process-mode 为 always、模式为规则
            let ok = self.patchFlclashConfig { patch in
                var tun = (patch["tun"] as? [String: Any]) ?? [:]
                tun["enable"] = true
                if tun["stack"] == nil { tun["stack"] = "mixed" }
                if tun["device"] == nil { tun["device"] = "FlClash" }
                if tun["dns-hijack"] == nil { tun["dns-hijack"] = ["any:53"] }
                patch["tun"] = tun
                patch["find-process-mode"] = "always"
                patch["mode"] = "rule"
            }
            // 3) 重新拉起 FLClash，让它按新设置重新生成 config.yaml
            if ok {
                self.openFlClash()
                Thread.sleep(forTimeInterval: 3.0)
            }
            DispatchQueue.main.async {
                self.isAutoFixing = false
                self.cachedConfigRaw = nil
                self.cachedConfigJSON = nil
                self.checkPrerequisites()
                if !ok {
                    self.autoFixMessage =
                        "自动修复失败：无法写入 FLClash 设置。"
                        + (backup.map { "原设置已备份到 \($0)" } ?? "")
                } else if self.prereqIssues.isEmpty {
                    self.autoFixMessage = "已自动修复，FLClash 已重启"
                } else {
                    self.autoFixMessage = "已写入设置并重启 FLClash，但仍有未满足项，请按提示手动处理"
                }
            }
        }
    }

    /// 定时轮询 FLClash 设置（TUN / find-process-mode / 模式），1 秒一次。
    /// 之前只在「扫描完 / config.yaml 变化 / 重载后」检测，用户在 FLClash 里切模式或
    /// 开关 TUN 不会触发任何回调，界面就一直显示旧状态。
    /// 加入 .common 模式，保证滚动列表时也照常触发。
    /// 开销很低：一次 UserDefaults 读取（走 cfprefsd），内容没变时连 JSON 都不解析。
    func startPeriodicRefresh() {
        refreshTimer?.invalidate()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkPrerequisites()
        }
        RunLoop.main.add(t, forMode: .common)
        refreshTimer = t
    }

    /// FLClash 安装位置发现（分发到别的电脑的关键）。
    /// 不能写死 /Applications/FlClash.app——对方可能装在 ~/Applications、/Applications/Utilities
    /// 或外接盘，写死会让「改动立即生效」的自动重载在别人机器上静默失效。
    /// 优先用 bundle id 让 LaunchServices 反查（最可靠），再退到常见安装路径。
    private func flclashAppPath() -> String? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.follow.clash"),
            FileManager.default.fileExists(atPath: url.path)
        {
            return url.path
        }
        let home = NSHomeDirectory()
        let candidates = [
            "/Applications/FlClash.app",
            (home as NSString).appendingPathComponent("Applications/FlClash.app"),
            "/Applications/Utilities/FlClash.app",
            "/System/Applications/FlClash.app",
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    /// 退出兜底：若用户在本工具重载 FLClash 的窗口期（kill 后 open 前，约几百毫秒）Cmd+Q 退出，
    /// reload 流程随进程中断，FLClash 会被留在「被杀掉却没拉起」的状态——代理直接掉线。
    /// 仅在「我们正在重载」且「FLClash 确实没活着」时才负责拉起，其余情况一律不动
    /// （用户自己手动关的 FLClash 不会被误拉起）。
    func ensureFlClashAliveBeforeExit() {
        guard isReloading else { return }
        let chk = Process()
        chk.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        chk.arguments = ["-x", "FlClash"]
        let pipe = Pipe()
        chk.standardOutput = pipe
        try? chk.run()
        chk.waitUntilExit()
        let out = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }  // 活着,无需救
        guard let appPath = flclashAppPath() else { return }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-a", appPath]
        try? open.run()
        open.waitUntilExit()
    }

    /// 写/恢复后自动重载 FLClash：关掉 GUI + 内核再重新拉起，让新配置生效（免去手动重启）。
    /// 必须在后台线程跑（里面有等待），不要在主线程/界面重绘时调用。
    /// killall 指定进程（阻塞到命令返回）
    private func killProcess(_ name: String) {
        let k = Process()
        k.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        k.arguments = [name]
        try? k.run()
        k.waitUntilExit()
    }

    /// 轮询等进程真正退出（最多 ~3s），避免紧接着 open 时旧进程还在
    private func waitProcessGone(_ name: String) {
        for _ in 0..<30 {
            let chk = Process()
            chk.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            chk.arguments = ["-x", name]
            let pipe = Pipe()
            chk.standardOutput = pipe
            try? chk.run()
            chk.waitUntilExit()
            let out = String(
                data: pipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8) ?? ""
            if out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    func reloadFlClash() {
        let kill = killProcess
        let waitGone = waitProcessGone
        // 1) 先关 GUI 并等其彻底退出（关键：否则 GUI 可能在后台把内核用旧配置重新拉起，导致重载失效）
        // 记录重载前 config.yaml 修改时间，用于后面等它真正重新生成
        let beforeMtime =
            (try? FileManager.default.attributesOfItem(atPath: configPath)[.modificationDate])
            as? Date
        kill("FlClash")
        waitGone("FlClash")
        // 2) 再确保内核退出
        kill("FlClashCore")
        waitGone("FlClashCore")
        // 3) 重新打开 GUI（拉起全新内核，读取已写入的新配置并重建 TUN）
        var launched = false
        if let appPath = flclashAppPath() {
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = ["-a", appPath]
            try? open.run()
            open.waitUntilExit()
            launched = (open.terminationStatus == 0)
            // 4) 等 FLClash 真正从激活 profile 重新生成 config.yaml（实测约 +2s，上限 6s），
            //    否则「已生效」报得太早——用户看到生效时规则其实还没进内核
            if launched {
                for _ in 0..<60 {
                    Thread.sleep(forTimeInterval: 0.1)
                    let now =
                        (try? FileManager.default.attributesOfItem(atPath: configPath)[
                            .modificationDate]) as? Date
                    if let b = beforeMtime, let n = now, n > b { break }
                    if beforeMtime == nil, now != nil { break }
                }
            }
        }
        DispatchQueue.main.async {
            self.isReloading = false
            self.refreshHasWrittenRules()
            self.checkPrerequisites()
            self.statusMessage =
                launched
                ? "已生效"
                : "配置已写入，但没找到 FLClash，无法自动重载，请手动打开 FLClash"
        }
    }
}
