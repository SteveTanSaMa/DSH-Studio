# DSH Studio

[English](README.en.md) | **中文**

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="Brand/AppIcon-dark.png">
    <img src="Brand/AppIcon-light.png" alt="DSH Studio 项目标识" width="180">
  </picture>
</p>

<p align="center">
  DeepSeek Harness 的非官方第三方 macOS 客户端。
</p>

DSH Studio 是 DeepSeek Harness Web UI 的 Swift 原生外壳：它管理 macOS 窗口与应用生命周期，
在内置 `WKWebView` 中启动并展示本地 Harness Runtime，并补齐 Harness 自身不负责的 macOS 使用体验。

DSH Studio **不是** DeepSeek 官方产品，与 DeepSeek 之间不存在隶属、授权、赞助或背书关系。

**规范用词**：本文中「必须」表示违反即失败，「不允许」表示对应操作会被代码或流水线拒绝，
「应当」表示约定，偏离时需要说明理由。

## 目录

- [1. 范围](#1-范围)
- [2. 功能](#2-功能)
- [3. 系统要求](#3-系统要求)
- [4. 构建、运行与测试](#4-构建运行与测试)
- [5. 架构与目录](#5-架构与目录)
- [6. Runtime：来源、身份与信任](#6-runtime来源身份与信任)
- [7. 设置](#7-设置)
- [8. 插件市场](#8-插件市场)
- [9. Agent Preset 迁移](#9-agent-preset-迁移)
- [10. 安全与隐私边界](#10-安全与隐私边界)
- [11. 本地路径](#11-本地路径)
- [12. 已知限制](#12-已知限制)
- [13. 许可与声明](#13-许可与声明)

## 1. 范围

- 本仓库**只提供 macOS 外壳**：窗口与生命周期、WebKit 集成、本地 Runtime 的发现/验签/下载/
  校验/安装/健康检查/回滚、设置页挂载，以及 macOS 侧的可用性调整。
- 本仓库**不实现 Harness**，也不 fork 上游：Harness Web UI 与其命令行为始终以官方为准。
- Harness 及其完整依赖由独立仓库 [DSH Studio Runtime](https://github.com/SteveTanSaMa/DSH-Studio-Runtime)
  打包成不可变 artifact，并以签名 catalog 发布；两者的契约写在 Runtime 仓库的
  `docs/runtime-contract.md`（中文）。
- 本仓库**不提供服务端**：没有账号体系、没有 API 中继、没有遥测与广告，也不会上传用户的 API Key。

## 2. 功能

- **原生外壳**：macOS 窗口、生命周期、菜单、快捷键与 WebKit 集成。
- **Runtime 管理**：首次启动自动安装；版本检查、经校验的更新、回滚到上一个可用安装；退出时按
  进程树停止 Harness。
- **设置合并**：应用设置作为**一等 Harness 设置分区**挂载在 Harness 设置对话框内，不再有第二
  个原生偏好窗口。
- **插件市场**：按 Runtime 发布的 pin 安装并管理上游 `dshmarket`。
- **Agent Preset 迁移**：以 `.dshpreset` 归档在本地安装之间导入/导出用户自建 Preset。
- **macOS 集成**：工作区准入、系统通知、会话日志 ZIP 导出、本地 Runtime 终端、诊断复制与导出，
  以及不替换上游行为的前端布局调整。

架构如下，Web UI 始终是本地运行的 Harness，而不是任何远程站点：

```text
DSH Studio.app
    │
    ├── Swift / macOS 原生外壳
    │       │
    │       └── WKWebView
    │               │
    │               └── http://127.0.0.1:<port>
    │                       │
    │                       └── DeepSeek Harness Web UI
    │                               │
    │                               └── 用户自行配置的 DeepSeek API
```

## 3. 系统要求

- macOS 15 或更高版本（`LSMinimumSystemVersion` = 15.0）。
- Apple Silicon 或 Intel Mac；架构必须与所选 Runtime artifact 一致。
- 从源码构建需要带 macOS 15 SDK 的 Xcode。
- 首次启动需要网络；之后仅在检查或安装 Runtime 更新时需要。
- 用户自行在 Harness 中配置 DeepSeek API。

**主机不需要单独安装 Node.js、Harness 或 pnpm**：它们的版本与完整性都由 Runtime artifact 提供。

## 4. 构建、运行与测试

```bash
git clone https://github.com/SteveTanSaMa/DSH-Studio.git
cd DSH-Studio
open "DSH Studio.xcodeproj"        # 选择 DSH Studio scheme 运行
```

分发构建**必须**提供签名 catalog 公钥，否则远端 Runtime 发现会被关闭：

```bash
RUNTIME_CATALOG_PUBLIC_KEY=base64-ed25519-public-key ./Scripts/build-app.sh
```

公钥写入 `Info.plist` 的 `RuntimeCatalogPublicKey`；缺失时应用仍可在已有 Runtime 上离线启动，
但不会安装新的 Runtime。

测试与门禁：

```bash
xcodebuild -project "DSH Studio.xcodeproj" -scheme "DSH Studio" \
  -destination "platform=macOS,arch=arm64" test     # 269 个用例

python3 Scripts/check-doc-comments.py               # 每个内部声明都有文档注释
python3 Scripts/check-web-bridge-script.py          # 注入脚本可被解析

cd Plugins/dsh-studio-settings && npm ci && npm test && npm run build
```

CI（`.github/workflows/ci.yml`）执行四件事：静态门禁、设置插件测试与「提交的
`lib/client.js` 与源码一致」、完整测试套件、以及三个模块的 DocC 无警告构建。

应用图标由 `Brand/` 下的原始美术资源派生；替换任一资源后运行：

```bash
Scripts/generate-app-icon.sh
```

## 5. 架构与目录

| 目录 | 内容 |
| --- | --- |
| `DSH Studio/Sources/App` | 应用目标：生命周期、AppModel、设置桥、WebView 宿主、外观与品牌、诊断 |
| `DSH Studio/Sources/Harness` | `DeepSeekHarness` 模块：注入式布局/行为脚本、Harness 本地 RPC 客户端、URL 策略 |
| `DSH Studio/Sources/Runtime` | `DeepSeekRuntime` 模块：catalog 验签、安装与更新、进程生命周期、profile、插件市场 |
| `DSH Studio/Sources/Logging` | `DeepSeekLogging` 模块：日志与脱敏 |
| `Plugins/dsh-studio-settings` | 一等 Harness 插件：Host 侧注册 `dsh-studio` 设置命名空间，浏览器侧注册设置页 |
| `Tests/HarnessRuntimeTests` | 全部单元测试（含设置页契约、进程生命周期与真实子进程用例） |
| `Scripts/` | 构建脚本、静态门禁、图标派生 |
| `Brand/` | 应用标识原始美术资源（浅色/深色） |

## 6. Runtime：来源、身份与信任

**安装位置**是用户 Application Support 下的版本化目录：

```text
~/Library/Application Support/DSH Studio/Runtimes/<runtime-version>
~/Library/Application Support/DSH Studio/Runtime              # 旧版安装（仅迁移）
```

**版本身份**：Runtime 的公开版本号**就是**它包含的 Harness 版本，不加构建计数。重新打包同一
Harness 版本不会产生新版本号，替换的是 release 附件与 catalog 中的 `sha256`；因此 artifact 的
身份由签名 catalog 的 SHA-256 承担，而不是版本号。

**信任链**：catalog 是固定地址上的签名 JSON（Ed25519，`keyID` 必须为 `runtime-catalog-v1`，
`schemaVersion` 必须为 1）；解析后按本机架构选择 release，校验依赖 pin、数据格式与 artifact
描述，下载后逐字节校验 SHA-256，再校验解包布局与 `manifest.json`（`schemaVersion: 3`）与
catalog 条目一致。任一步失败即关闭，回滚完全离线。

当前开发快照（无签名 catalog 时的回退值，实际安装以 catalog 为准）：

| 组件 | 版本 | 来源 |
| --- | --- | --- |
| Node.js | `24.19.0` | `nodejs.org` |
| DeepSeek Harness | `@deepseek-ai/dsh@0.2.0-rc.2` | `registry.npmjs.org` |
| pnpm | `11.22.0` | `registry.npmjs.org` |
| 插件市场 | `dshmarket@1.66.6` | `registry.npmjs.org` |

**数据兼容**采用 fail-closed：只有 manifest 与 catalog 同时声明且证明兼容时，新 Runtime 才会
复用现有数据；声明了不兼容的 `dataFormat.id`（当前为 `sqlite-v2`）时新建隔离数据 profile，
旧数据不迁移、不覆盖、不删除；未声明 `dataFormat` 时**不允许**更新。

**安装完整性**不按「目录存在」判断：只有当 `manifest.json` 可解析且与签名 catalog 的记录一致
时，该安装才可用。安装过程在暂存目录完成后再发布，中断或校验失败的安装不会被当成可用 Runtime。

**进程生命周期**：Harness 运行期间可能 fork 自身的副本；父进程被 `SIGTERM` 后，子进程会被
reparent 到 launchd 并继续存活。因此退出时 DSH Studio 会先记录并停止这次启动观察到的后代进程，
再终止 Harness 本体；10 秒宽限期后对仍存活者发送 `SIGKILL`。该宽限期与 Runtime 发布流水线
验证的预算一致，正在刷写会话持久化的 Harness 不会被截断。

## 7. 设置

DSH Studio 没有独立的偏好窗口。应用设置是 Harness 设置对话框中的一个分区，Harness 对话框始终
是唯一的配置入口：

- `Plugins/dsh-studio-settings` 是 Harness 插件：Host 侧注册 `dsh-studio` 设置命名空间，浏览器侧
  把 **DSH Studio** 页注册进 Harness 自己的 `settings.section` 槽位。
- 页面只使用 Harness 共享的 UI 原语与设计 token，因此与一等页面同一种视觉语言，并跟随 Harness
  主题（浅色/深色）。
- **持久化归 Harness**：所有写入都经过 Harness 设置服务，并受命名空间 revision 约束。
- 必须在 Harness 启动前就确定的值（工作区路径、对话内容宽度、三个通知开关）仍由 App 持有：
  页面把每次改动镜像回 App，App 在 Runtime 就绪后再把自己的值写回命名空间，两侧不会漂移。
- 菜单中的**设置…**（⌘,）打开的是同一个 Harness 对话框。
- 页面自身无法完成的操作（原生面板、Runtime 终端、进程控制、诊断）通过经过校验的
  `WKScriptMessageHandler` 桥接，并按同一 request id 回复。

应用菜单保留在 Harness 页面出现之前或不可用时也必须存在的操作：Runtime 更新、Runtime 终端、
工作区选择、数据目录、侧边栏开关、重新加载、Web Inspector、日志与诊断。

## 8. 插件市场

DSH Studio 可以安装并管理上游 `dshmarket` 插件。市场自己负责社区插件；本应用只处理这一个包在
`web` profile 内的安装、启用、修复与卸载，并且只使用 Runtime 内置的 Node.js 与 pnpm 路径，
不依赖主机上任何独立安装。

**「哪个市场版本可用」不是应用的属性**，而是由 Runtime 所含 Harness 版本决定的，因此这个配对
随 Runtime 版本发布：

- 签名 catalog 的 release 可以携带 `pluginMarket` pin（`{package, version, integrity,
  harnessRange}`），artifact manifest 记录同一 pin，使离线安装也能描述自己的市场。
- 应用按该 pin 安装与校验；自身常量只作为 pin 字段出现之前所发布 Runtime 的回退值。
- 兼容性由市场在 `peerDependencies` 中声明的 Harness 范围决定；超出范围时报告为不兼容，并在
  消息中给出范围与当前 Harness 版本，而不是装上去再在界面里失败。
- 预发布版本按所属「版本线」判断：`^0.1.1-rc.2` 覆盖 0.1.x，而点名具体构建的比较符仍会拒绝更
  旧的同线构建。

市场包只从官方 `registry.npmjs.org` 解析，包元数据与 lockfile integrity 校验通过后才会改动
`web` profile。第三方插件以 Runtime 的权限运行且**不沙箱隔离**，只应安装可信插件。当前只管理
`web` profile。

## 9. Agent Preset 迁移

用户自建的 Agent Preset 可以 `.dshpreset` 归档在本地安装之间迁移。DSH Studio 只读写
`DSH_HOME/.agent-presets/<preset-id>`，内置 Preset 不会被导出。归档包含带版本的 `manifest.json`
与 `preset/` 目录树，其必需入口为 `agent.cordis.yml`。

导入前先预览：来源 Harness 版本、文件数、解压后大小、可能的凭据标记，以及 ID 是否冲突；冲突时
必须由用户另选 ID，已有 Preset 永不被覆盖。安装是把校验通过的目录树一次性移入的本地操作。

迁移边界**不包含** API Key 等凭据、Session、工作区文件与其余 DSH_HOME 数据。归档限制为压缩后
16 MiB、解压后 32 MiB、256 个文件、单文件 12 MiB；绝对路径、目录穿越、不支持类型、重复项与
符号链接条目都会被拒绝。导入 Preset 仍会把 Runtime 的插件与工具权限授予其组合，因此只应导入
可信归档。

## 10. 安全与隐私边界

- Harness 必须显式绑定 `127.0.0.1`，不允许绑定 `0.0.0.0`。
- WebView 主页面只允许本地 loopback URL。
- Runtime 与插件市场的包元数据在发布侧核对官方 registry 主机与固定 integrity。
- Runtime artifact 与签名 catalog 只从固定的 Runtime GitHub Release 地址下载。
- 运行期应用**不执行** npm/pnpm 安装，也不执行远端脚本。
- Runtime Builder 使用 `npm ci --ignore-scripts`，并在发布前验证原生依赖。
- 不添加遥测、统计、广告或任何远端服务端点；子进程以禁用遥测的方式启动。
- 诊断在写入本地日志前脱敏；API Key 与 bearer token 不允许出现在问题反馈或日志中。

## 11. 本地路径

```text
~/Library/Application Support/DSH Studio/DSH_HOME          # Harness 数据（可备份）
~/Library/Application Support/DSH Studio/Workspace         # 默认工作区
~/Library/Application Support/DSH Studio/Runtimes/<ver>    # 已安装 Runtime
~/Library/Application Support/DSH Studio/DataProfiles/<id> # 隔离数据 profile
~/Library/Application Support/DSH Studio/Logs              # 应用与 Runtime 日志
```

Harness 组合 profile 存放在 `DSH_HOME/profiles`，其 active/pending/last-known-good 选择记录在
Application Support。工作区可在设置中选择，并受本地目录准入检查约束。

## 12. 已知限制

- 本项目是非官方第三方客户端，Harness 功能的最终依据是上游官方实现。
- 首次安装需要下载约 188 MiB（197 MB）的 Runtime artifact，耗时取决于网络。
- 第三方插件不在沙箱内运行；插件能力等同于 Harness 自身权限。
- 当前只管理 `web` profile。
- macOS 的 appiconset **不能**携带深色外观，因此 Finder/启动台显示浅色图标，而运行中的应用
  （Dock、应用切换器、「关于」面板）会按系统外观在浅色/深色标识之间切换。完整的系统级深色图标
  需要 macOS 26 的 Icon Composer 格式。
- 「已安装的是哪个构建」目前由「版本号 + 架构 + 全部依赖 pin」判定；若发布方在原版本上重新打包
  且依赖 pin 不变（只有 artifact 字节变化），该安装会被视为同一个构建而不会提示更新。

## 13. 许可与声明

DSH Studio 自有源码以 MIT 许可发布，见 [LICENSE](LICENSE)。

项目标识与派生的应用图标美术资源属于**独立**作品，**不**在 MIT 许可范围内，以 CC BY-NC-SA 4.0
发布，署名与授权信息见 [NOTICE](NOTICE)。原始资源位于 `Brand/`。

DeepSeek Harness 与全部 npm 依赖是各自许可下的独立作品；分发已安装 Runtime 时必须保留其声明与
许可条款（见 [NOTICE](NOTICE) 与 Runtime 内各包的元数据）。

美术资源许可：[CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/)

DSH Studio 是非官方第三方项目。DeepSeek、DeepSeek Harness 及相关名称与标识归各自权利人所有；
本仓库与应用中的任何内容都不应被理解为获得 DeepSeek 的官方隶属、授权、赞助或背书。
