# Kindle 导入测试样本

## libmobi 样本

以下三个均取自 [libmobi](https://github.com/bfabiszewski/libmobi) v0.12 的 `tests/samples/`（libmobi 作者自行生成的测试样本，随 libmobi 以 LGPL-3.0-or-later 发布），只改了文件名：

| 文件 | 原文件 | 用途 |
| --- | --- | --- |
| `kf8-ncx.azw3` | `sample-ncx.mobi` | KF8：多章节、两级 NCX 目录 |
| `mobi6-cp1252.mobi` | `sample-cp1252.mobi` | 旧版 MOBI：cp1252 编码、`mbp:pagebreak`、内嵌图片与封面 |
| `drm-v1.mobi` | `sample-drm-v1.mobi` | 受 DRM 保护，应拒绝导入 |

## 排版与注释样本

`kindle-styles.azw3`、`kindle-styles.mobi` 由 [`scripts/make_kindle_fixtures.py`](../../../scripts/make_kindle_fixtures.py) 生成：脚本写出一本合成 EPUB（文字与图片均为脚本生成），用 calibre 的 `ebook-convert` 转为 AZW3（不压缩）与旧版 MOBI。内容覆盖外部 CSS（缩进、对齐、边框底色、字号）、EPUB3 注脚、多看注释、跨章尾注、ruby、插图与表格（单独成章，原生引擎不支持表格）。calibre 转换时会自行求值 `@media amzn-*`，脚本因此把 AZW3 样式表中的两条规则原位改回 `@media amzn-kf8`／`amzn-mobi` 写法，以端到端覆盖展开逻辑。

KFX、损坏文件等其他情况由测试在运行时生成。
