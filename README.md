# FanControl — Apple Silicon 风扇控制 & 温度监控

macOS 原生菜单栏 App（SwiftUI），基于 [smctl](https://github.com/leaperone/smctl)（MIT）封装。
在 Apple Silicon（M1/M2/M3/M4/M5）上读取温度、控制风扇转速、编辑温度曲线。

## 功能
- **菜单栏实时监控**：风扇图标随温度变色，下拉面板显示热点温度/平均温度/功耗/各风扇实际与目标转速
- **手动调速**：滑块设目标 RPM（经 daemon XPC，admin 用户即可）
- **预设模式**：系统自动 / 静音 / 全速，一键切换
- **温度曲线编辑器**：拖拽节点定义 温度→转速 映射，写入 `/etc/smctl/config.toml`
- **安全护栏**：smctld 每秒监控温度，超上限自动交还系统控制（不可关闭）
- **退出自动还原**：交还系统控制，launchd reconcile 兜底

## 构建
```bash
brew install xcodegen
xcodegen generate
xcodebuild -project FanControl.xcodeproj -scheme FanControl -configuration Debug -derivedDataPath .build build
```

依赖：本项目自带 `smctl`/`smctld` 预编译二进制（`vendor/smctl/`），无需另行安装。
构建后需把 `vendor/smctl/smctl` 复制进 app bundle：
```bash
cp vendor/smctl/smctl vendor/smctl/smctld .build/Build/Products/Debug/FanControl.app/Contents/MacOS/
```

> ⚠️ `smctl` 和 `smctld` **必须同时**复制进 bundle。`smctl daemon install` 要求 `smctld`
> 与 `smctl` 同目录，漏掉 smctld 会导致安装失败（报 "Could not find smctld next to the
> current smctl executable"）。若架构改为打包脚本，请把这两个二进制一并纳入。

## 运行与首次安装
1. 打开 app（菜单栏出现风扇图标）
2. 到「服务」页点「安装服务」，输一次管理员密码安装 smctld
3. 之后手动调速、预设、曲线均免密（admin 用户经 XPC 授权）

> 说明：传感器读取无需 root；写操作由 smctld（root daemon）执行。daemon 依赖一次性的
> 管理员授权，这与 smctl 官方设计一致（不写 sudoers、信任边界在 root daemon + XPC）。

## 技术路线
- **CLI 中转**：SwiftUI app 通过 `Process` 调用 `smctl` CLI 二进制 → XPC → smctld → AppleSMC
  - 绕过 smctl XPC 的 Team ID 签名鉴权约束（无 Apple Developer 账号也能用）
- 详见 `ROUTE.md`

## 许可证
- 本项目：**MIT**（见 [LICENSE](LICENSE)），Copyright © 2026 RainbowYang
- 底层 [smctl](https://github.com/leaperone/smctl)（含 smctld）同为 **MIT**，版权归其原作者。`vendor/smctl/LICENSE` 保留其完整许可声明。
- 打包产物 `.dmg` 内含 smctl/smctld，按 MIT 条款随副本保留上述声明。
