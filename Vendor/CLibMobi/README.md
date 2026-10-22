# CLibMobi

[libmobi](https://github.com/bfabiszewski/libmobi) 的 C 源码，供书库导入 AZW3／MOBI 时解析并重建 KF8／MOBI 源文件。转换与 EPUB 打包在 `iOSApp/Features/Library/KindleImport/`。

| 项目 | 内容 |
| --- | --- |
| 版本 | v0.12（提交 `85dcfe803fc2a21020ddcf15c3eb66b93d388add`） |
| 许可 | LGPL-3.0-or-later，全文见 [COPYING](COPYING)，作者见 [AUTHORS](AUTHORS) |
| 修改 | 未修改任何源码文件；只把公开头文件 `mobi.h` 放到 `Sources/CLibMobi/include/` 供 Swift 导入 |

## 收录范围

- 收录 `src/` 中 buffer、compression、debug、index、memory、meta、opf、parse_rawml、read、structure、util、write、xmlwriter 的 `.c`／`.h` 与 `config.h`、`mobi.h`。
- 未收录：`encryption.*`、`sha1.*`、`randombytes.*`（DRM 处理）、`miniz.*`（改用系统 zlib）、`tools/`、`tests/` 与构建脚本。

## 编译选项

`USE_XMLWRITER`（用内置 xmlwriter 生成 OPF／NCX），`HAVE_STRDUP`、`HAVE_UNISTD_H`；**不定义 `USE_ENCRYPTION`**，因此不包含解密代码，受 DRM 保护的书只会被识别并拒绝导入。链接系统 `libz`。

## 更新

替换 `Sources/CLibMobi/` 中的同名文件，更新本文件的版本与提交、`iOSApp/Features/Reader/EPUBReader/DEPENDENCIES.md` 与 `iOSApp/Resources/ThirdPartyLicenses/`，再运行 Kindle 导入测试。
