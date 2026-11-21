# Dulo iOS

SwiftUI 全量重写的 Dulo iOS 客户端（Android 版：`dev.dulo.player`）。纵向无限信息流，服务端（`Dulo-server`）零改动。面向 TrollStore 侧载分发，不做 App Store 上架。

## 架构

- `Sources/Data` — 清单/lease 数据层（对应 Android 同名 Kotlin 包）：`/manifest.json` 身份列表、`/resolve/{id}` 按需铸造播放 URL，客户端 LRU lease 缓存 + 60s 提前续期。
- `Sources/Feed` — 流存储、乱序队列、`UIPageViewController` 垂直分页（SwiftUI 无 iOS 16 垂直 paging，滚动吸附行为用 UIKit 分页器）、页面（每页一个 AVPlayer，预加载邻居页，403 → `?force=1` 续租，失败自动跳过）。
- `Sources/Player` — AVURLAsset 注入抖音要求的浏览器 UA + Referer；403 检测走一次 Range 预检请求（AVFoundation 错误里不暴露 HTTP 状态码）。
- 服务器地址在右上角齿轮里配置，默认 `http://192.168.2.3:8080`。左上角 80pt 双击退出。

## 构建（GitHub Actions）

无需本地 Xcode：push 到 `main` 即构建，产物在 Actions 的 **Dulo.ipa** artifact。

```
push → macos-15 → xcodegen generate → 模拟器单测 → 无签名 archive → zip IPA
```

IPA 不签名（TrollStore 安装时自动 fakesign）。

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

- 视频字节走系统网络（AVFoundation 遵循系统代理设置），Android 客户端内嵌的 7890 代理由系统 Wi-Fi 代理等价覆盖。
- 首次联网会弹 iOS 本地网络权限框，允许即可。
