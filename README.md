# FlClashAppRouter

给 macOS 版 **FLClash** 补上「按软件分流」的可视化面板——带 App 图标，点一下选出口，改完自动生效。

> 为什么需要它：FLClash 的「应用分流」面板 **只有 Android 端有**（基于 uid），macOS 端官方没做。本工具用进程名规则补上这一块。

**当前版本：v2.6** · [下载最新版 DMG](https://github.com/Easonliu-banfang/FlClashAppRouter/releases/latest)

---

## 下载安装

1. 到 [Releases](https://github.com/Easonliu-banfang/FlClashAppRouter/releases/latest) 下载 `FlClashAppRouter-x.x.dmg`
2. 打开 DMG，**推荐**双击里面的「安装到应用程序.command」（输一次密码，自动清隔离属性并重新签名）
   ——也可以手动把 `FlClashAppRouter.app` 拖进「应用程序」
3. 首次打开若被 macOS 拦下（本工具未做 Apple 公证）：
   右键 App → 「打开」→ 点「打开」，或到「系统设置 → 隐私与安全性」点「仍要打开」

要求：**macOS 14+**，Apple Silicon 与 Intel 均可（通用二进制）。

## 使用前提

| 前提 | 说明 |
| --- | --- |
| 已安装并运行 FLClash | [github.com/chen08209/FlClash](https://github.com/chen08209/FlClash) |
| FLClash 开启 **TUN 模式** | 不开 TUN，很多 App 的流量根本不进内核 |
| `find-process-mode` 为 `strict` 或 `always` | 为 `off` 时内核不反查进程，规则永远不命中 |
| FLClash 模式为 **规则模式** | 全局模式下所有流量都走代理、直连模式下全部不走代理，这两种模式下 `rules:` 段会被整体忽略，按软件分流形同虚设 |
| 配置里有 `rules:` 段 | 订阅档需先在 FLClash 里「更新订阅」 |

**这四项工具都会自动检测**：标题栏实时显示 FLClash 当前模式（规则/全局/直连），任一前提不满足时顶部弹出橙色提示条，明确告诉你是哪一项——不会让你对着一个"没反应"的界面猜。

## 怎么用

1. 打开后自动扫描已安装 App（首次较慢，之后走缓存秒开）
2. 打开顶部「App 规则分流」开关
3. 给任意 App 选策略：
   - **原规则** = 不干预，走机场原有分流
   - **直连** = 真正不走代理（生成 `PROCESS-NAME,X,DIRECT`）
   - **代理** = 走机场出口组（自动从你的配置里识别组名，不用手填）
4. 改完约 3 秒自动写入并重载 FLClash，不用点任何按钮
5. 想全部撤销 → 点「恢复原配置」

装了新 App 后，用右上角 `⋯` 菜单里的「重新扫描」刷新列表。

## 它具体做了什么

1. 递归扫描 `/Applications`、`/System/Applications`、`~/Applications`，用 Spotlight 取 Finder 显示名（中文名、系统 App 本地化名都能正确显示）
2. 从每个 App 的 `Info.plist` 读 `CFBundleExecutableName` / `CFBundleExecutable`，拿到**真实进程名**（不是显示名）
3. 收集 App 内嵌的子进程（Chromium 系 Helper、XPC 服务、Updater 等）——只写主进程规则会形同虚设
4. 生成规则写进 FLClash **当前激活的 profile**（`profiles/<currentProfileId>.yaml`），而不是 `config.yaml`——后者每次启动都会被 profile 覆盖，写那里等于白写
5. 自动重载 FLClash 让规则进内核

几个容易踩的坑，本工具都已处理：

- **出口组名不能瞎写**：你的机场主组不一定叫 `Proxy`（比如可能叫 OneLighter）。工具会读 `proxy-groups` 并统计 `rules` 里被引用最多的组，写错组名会让 Mihomo 直接拒载整个配置。
- **同名进程串扰**：多个 App 共用同一进程名（比如三个 Electron 应用），只按进程名匹配会互相连累。工具检测到冲突就自动改用 `PROCESS-PATH` 全路径精确匹配。
- **YAML 缩进**：profile 里规则是 4 空格缩进、config.yaml 是 2 空格，插入块缩进不一致会导致配置非法。工具按目标文件实测缩进。

## 从源码构建

```bash
bash build_and_install.sh
```

会用 `swiftc` 分别编译 arm64 / x86_64 再 `lipo` 合并，打包 `.app`、嵌入图标、ad-hoc 签名，并提权安装到 `/Applications`。

> 注意：项目用 `swiftc` 直接编译而非 Xcode——macOS 26+ SDK 下 `@State` 是外部宏，直编时插件解析不到。所以所有界面局部状态都放在 `AppRouterModel` 里用 `@Published`。

重新生成图标（改了 `Assets/AppIcon-source.jpg` 后）：

```bash
for pair in "16x16:16:16" "16x16@2x:32:32" "32x32:32:32" "32x32@2x:64:64" \
            "128x128:128:128" "128x128@2x:256:256" "256x256:256:256" \
            "256x256@2x:512:512" "512x512:512:512" "512x512@2x:1024:1024"; do
  name="${pair%%:*}"; rest="${pair#*:}"; w="${rest%%:*}"; h="${rest##*:}"
  mkdir -p Assets/AppIcon.iconset
  sips -z "$h" "$w" -s format png Assets/AppIcon-source.jpg \
       --out "Assets/AppIcon.iconset/icon_${name}.png"
done
iconutil -c icns Assets/AppIcon.iconset -o Assets/AppIcon.icns
```

## 已知限制

- 订阅更新会重写整个配置，把本工具写入的规则冲掉——重新设置一次即可，或用「恢复原配置」清理。
- macOS 内核只能按进程名/进程路径匹配，做不到 Android 那种按 uid 的干净映射。已用真实可执行文件名的映射把准确度做到足够高。
- 未做 Apple 公证，首次打开需要一次 Gatekeeper 放行（见上文）。

## 目录结构

```
Sources/
  AppRouterModel.swift    扫描 / 进程推导 / 规则生成 / 写入 / 重载
  ContentView.swift       SwiftUI 界面
  FlClashAppRouterApp.swift
Assets/                   图标源图与 ICNS
dist/                     DMG 内的说明与一键安装脚本
build_and_install.sh      构建 + 安装
Info.plist                Bundle 配置（改版本号在这里）
```
