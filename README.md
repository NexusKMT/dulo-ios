# Dulo iOS

SwiftUI 全量重写的 Dulo iOS 客户端（Android 版：`dev.dulo.player`）。纵向无限信息流，服务端（`Dulo-server`）零改动。面向 TrollStore 侧载分发，不做 App Store 上架。

## 架构

- `Sources/Data` — 清单/lease 数据层（对应 Android 同名 Kotlin 包）：`/manifest.json` 身份列表、`/resolve/{id}` 按需铸造播放 URL；确定性 LRU lease 缓存，播放页在过期前 60s 尝试续期。
- `Sources/Feed` — 流存储、乱序队列、`UICollectionView` 垂直分页；每页使用 player pool 的 AVPlayer，预加载邻居页。播放 item 失败时以 `?force=1` 重新 resolve，并用新 URL 重建 item。
- `Sources/Player` — 播放 URL 统一经过本地 HTTP 代理；UA/Referer 由代理注入上游 CDN，不依赖 AVURLAsset 的非公开 header 选项。
- 服务器地址内化在代码里（`AppSettings.serverBaseUrl` = `http://192.168.2.3:8080`），无设置界面；没有隐藏退出手势。

## 构建（GitHub Actions）

无需本地 Xcode：push 到 `main` 即构建，产物在 Actions 的 **Dulo.ipa** artifact。

```
push → macos-15 → xcodegen generate → 模拟器单测 → 无签名 archive → zip IPA
```

IPA 不签名（TrollStore 安装时自动 fakesign）。

## 版本规则

任何改动（代码、配置、文档、CI）都必须递增 `project.yml` 的
`CURRENT_PROJECT_VERSION`。PR 的 CI 会对比 `main`，未递增时直接失败。
`MARKETING_VERSION` 仅在发布时提升。

## 本地开发

```sh
brew install xcodegen
xcodegen generate
open Dulo.xcodeproj        # 需要完整 Xcode
swift build --target DuloCore   # 无 Xcode：CLT 只做核心模块编译检查
# 单测需要 XCTest（CLT 不带），由 CI 在 iOS 模拟器上跑
```

## 安装

1. Actions 下载 `Dulo.ipa`。
2. 传到 iPhone（AirDrop/文件）。
3. 打开方式 → TrollStore → Install。

## 与 Android 版的差异

- 首次联网会弹 iOS 本地网络权限框，允许即可。
