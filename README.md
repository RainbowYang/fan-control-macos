# FanControl — Apple Silicon 风扇控制 & 温度监控

macOS 原生菜单栏 App（SwiftUI），基于 [smctl](https://github.com/leaperone/smctl)（MIT）封装。
在 Apple Silicon（M1/M2/M3/M4/M5）上读取温度、控制风扇转速。

## 功能
- **菜单栏实时监控**：App 启动即开始轮询（面板关闭也持续），风扇图标随掌托温度变色，下拉面板显示掌托/CPU/GPU 温度、整机功耗、各风扇实际与目标转速
- **历史曲线**：面板内展示最近约 15 分钟的掌托温度 / 风扇转速走势，两条可独立开关、同时显示或全关
- **四种工作模式**：自动 / 静音 / 全速 / 控温，一键切换、当前模式高亮
- **控温闭环**：设目标温度（25–45°C），app 内每 1.5s 读掌托温度 → 滞回控制器 → 经 daemon XPC 应用目标转速。全程**零密码弹窗**，仅在 app 运行期间生效
- **安全护栏**：控温每周期限变速 ±1200 RPM；掌托 ≥50°C 直接全速；切走模式立即停闭环
- **首次安装**：到「服务」页点「装服务」，输一次管理员密码安装 smctld；之后所有操作免密（admin 用户经 XPC 授权）
- **退出自动还原**：正常退出（含面板内「退出 FanControl」按钮）前交还系统自动控制，不会把风扇冻在手动高转速
- **独立设置面板**：开机自动启动（Login Item）、温度/风扇面板开关、历史曲线开关、版本与项目地址

## 构建
```bash
brew install xcodegen
./scripts/bootstrap-project.sh   # xcodegen generate + 修正 objectVersion 兼容性
xcodebuild -project FanControl.xcodeproj -scheme FanControl -configuration Debug -derivedDataPath .build build
```

依赖：本项目通过构建脚本自动把 `smctl`/`smctld` 复制进 app bundle。两个预编译 arm64 二进制
**不入 git 仓库**（体积较大），构建前请从 [smctl GitHub Releases](https://github.com/leaperone/smctl/releases)
下载后放到：

```
vendor/smctl/smctl
vendor/smctl/smctld
```

> ⚠️ `smctl` 和 `smctld` **必须同时**存在。`smctl daemon install` 要求 `smctld`
> 与 `smctl` 同目录，漏掉 smctld 会导致安装失败（报 "Could not find smctld next to the
> current smctl executable"）。发布打包脚本也会校验并拷贝这两个二进制。

## 运行与首次安装
1. 打开 app（菜单栏出现风扇图标，随后显示掌托温度）
2. 到面板底部点「装服务」，输一次管理员密码安装 smctld
3. 之后手动调速、预设、控温均免密（admin 用户经 XPC 授权）

> 说明：传感器读取无需 root；写操作由 smctld（root daemon）执行。daemon 依赖一次性的
> 管理员授权，这与 smctl 官方设计一致（不写 sudoers、信任边界在 root daemon + XPC）。

## 技术路线
- **CLI 中转**：SwiftUI app 通过 `Process` 调用 `smctl` CLI 二进制 → XPC → smctld → AppleSMC
  - 绕过 smctl XPC 的 Team ID 签名鉴权约束（无 Apple Developer 账号也能用）
- **串行写队列**：所有风扇写命令（切模式、控温写入）经同一串行队列执行，并带「执行前模式复核」，杜绝退出/切模式与控温闭环的写竞态
- 详见 `ROUTE.md`

## 打包发布
```bash
./scripts/make-dmg.sh
```
生成 `dist/FanControl-<版本>-arm64.dmg`。产物未签名/公证，分发后用户需「右键 → 打开」绕过 Gatekeeper。

也可以直接交给 CI 打包（GitHub Actions 的 macOS runner 自带可用 hdiutil，避免本机环境限制）：

```bash
# 手动触发一次构建，完成后从 Actions 的 artifact 下载 DMG
gh workflow run "Build DMG"
```

推送 `v*` tag 会自动构建 DMG 并创建 GitHub Release（`.github/workflows/build-dmg.yml`）。

## 许可证
- 本项目：**MIT**（见 [LICENSE](LICENSE)），Copyright © 2026 RainbowYang
- 底层 [smctl](https://github.com/leaperone/smctl)（含 smctld）同为 **MIT**，版权归其原作者。`vendor/smctl/LICENSE` 保留其完整许可声明。
- 打包产物 `.dmg` 内含 smctl/smctld，按 MIT 条款随副本保留上述声明。
