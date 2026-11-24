# NoveliaECH

本目录包含面向 iOS 的 Novelia ECH 原生传输库，来源于上游 Android 客户端 [nobYoQ/novelia](https://github.com/nobYoQ/novelia) 的 `native/ech`（提交 `fa93eef2508cfc9830db76842c8db82af6908e68`，GPL-3.0-only），内部使用 Go 标准库 `crypto/tls` ECH 与 `github.com/inqadh/jissr-bypass` v0.1.1（Apache-2.0）修改版。

完整第三方许可与声明见 `ECH-native.txt` 及 `ech/third_party/jissr-bypass/LICENSE`。

## 重新构建 XCFramework

需要本机已安装 Xcode 与 Go 1.27+：

```sh
scripts/build_ech_xcframework.sh
```

脚本会执行 Go 单元测试，并通过 `gomobile bind` 生成支持 `iOS 15+` 真机（`arm64`）与模拟器（`arm64` / `x86_64`）的 `Vendor/NoveliaECH/NoveliaECH.xcframework`。
