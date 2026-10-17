# 本机构建与分发

[← 返回 README](../README.md) · [功能说明](FEATURES.md) · [WebDAV 同步](WEBDAV.md) · [许可与第三方软件](LICENSES.md)

本文面向需要从源码运行、测试或分发 IPA 的开发者。修改代码前请先阅读[开发文档](../DEVELOPMENT.md)；仓库根目录 [AGENTS.md](../AGENTS.md) 提供必须遵循的入口规则。

## 从源码运行

使用 Xcode 打开 `NoveliaIOS.xcodeproj`，选择 `Novelia` scheme 和 iPhone 模拟器或已配置签名的设备。依赖由 Swift Package Manager 解析，锁定版本见 `NoveliaIOS.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`。

### 目录结构

| 目录 | 内容 |
| --- | --- |
| `iOSApp/` | SwiftUI 应用与 EPUB 阅读器 |
| `Sources/NoveliaIOSCore/` | API、模型、论坛 Markdown、TXT 分章与同步合并等不依赖界面的代码 |
| `Tests/` | 单元测试与合成 EPUB 样例 |
| `NoveliaIOS.xcodeproj/` | Xcode 工程 |

## 测试与排版检查

单元测试、离线回归、App 编译和 EPUB 排版扫描的命令与选择方法见[开发文档 → 构建与验证](../DEVELOPMENT.md#构建与验证)。

## 本机构建 Release

无需 GitHub Actions 或处理账单即可在 macOS／Xcode 本机构建。先按 [VERSIONING.md](../VERSIONING.md) 设置 Debug／Release 一致的版本与新构建号，再运行：

```sh
python3 -I scripts/build_local_release.py --simulator 'iPhone 18 Pro Max'
```

未提交的开发测试使用 `--allow-dirty`，例如：

```sh
python3 -I scripts/build_local_release.py --allow-dirty --simulator '<模拟器名称或 UDID>'
```

### 脚本做了什么

脚本运行 Swift 包逻辑／排版测试（不运行模拟器 UI 测试）、架构依赖检查与七项离线回归、Release 真机构建、架构验证代码排除检查、原始依赖许可与包内资源核对、IPA 隐私检查，生成未签名 IPA、完整对应源码、锁定依赖完整源码／许可（含 Readium 阅读器脚本所用 npm 包的原始发布包，按锁定文件 SHA-512 校验，并补充两项发布包缺失的 TypeScript 原始源码及构建配置）、BUILD.json 和 SHA256SUMS。

### 注意事项

- 开源许可页的 GPL 修改日期（`SettingsViews.swift` 的 `modifiedDate`）必须等于发布提交的日期，否则脚本拒绝构建。
- Xcode 派生数据默认放在系统临时目录下的新目录（成功后删除，失败时保留供排查）；Release 二进制会记录目标文件路径，`--derived-data` 不得位于用户主目录下，否则 IPA 隐私检查会失败。
- 产物位于忽略的 `build/local-releases/<版本>-<构建号>/`；只有出现 SUCCESS 才可分发。
- 输出目录已存在时拒绝覆盖，源码在构建期间变化也会失败。
- 脚本不修改版本、不提交、不推送、不发布。

## 分发

Release 分发时一并提供 IPA、source.tar.gz、dependencies.tar.gz、BUILD.json 与 SHA256SUMS；未签名 IPA 需接收者自行重签。

- **公开正式版**：构建另加 `--public-release`，生成指向本版本固定公开 Release 页的 `novelia-<版本>-build<构建号>-source-info.txt`，并纳入 SHA256SUMS；发布公开 Release 时一并上传该 TXT。
- **私密测试版**：默认不生成此文件。不要给尚未公开对应源码的私密测试版套用公开版说明。
- **网盘分享**：公开版通过网盘分享时，可仅上传配套 IPA 和 TXT，并在分享说明中提示源码取得方式；须保证对应 Release 的源码、依赖及许可材料完整、免费且持续可访问。

目录中的构建／测试日志仅供本机排障，可能含开发环境路径，不是应用的隐私过滤日志，不作为发布附件。

发布前还需运行以下命令，检查包内是否包含开发者主目录路径或常见凭据特征：

```sh
python3 scripts/verify_release_privacy.py <IPA路径>
```

许可核对说明见[许可与第三方软件](LICENSES.md)。

## API 架构与开发时替换

开发时的 API 配置和实现由 `NoveliaApp` / `AppServices` 统一组装，页面与 Store 通过业务服务接口调用。接口、功能实现和维护方法见[开发文档](../DEVELOPMENT.md)，其中也说明功能落点、依赖注入、API/认证替换、本地状态与数据兼容，以及对应验证方式。替换服务器格式需要实现对应服务；认证采用当前 Cookie/JWT 适配，其他认证协议需要相应适配。

## 性能与故障验证

发布脚本包含真实书库 Store 的隔离事务故障回归；性能基线需要单独采集，不随打包脚本自动测量。合成样本、运行命令及真机／真实 WebDAV 验收边界见[性能基线与故障验收](PERFORMANCE.md)。
