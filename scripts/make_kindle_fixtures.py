#!/usr/bin/env python3
"""生成 Tests/NoveliaKindleTests 使用的排版与注释样本（AZW3、MOBI）。

先写出一本合成 EPUB（全部文字与图片在此生成，不含第三方内容），
再用 calibre 的 ebook-convert 转为 AZW3（KF8）与旧版 MOBI。
覆盖：外部 CSS（缩进、对齐、边框、字号）、`@media amzn-kf8`／`amzn-mobi` 分支、
EPUB3 注脚（noteref／aside）、多看注释、跨章尾注、ruby、表格与插图。

用法：python3 scripts/make_kindle_fixtures.py（需要 PATH 中有 ebook-convert）。
calibre 版本不同，输出字节可能不同；更新样本后重新运行 Kindle 测试。
"""
from pathlib import Path
import os
import shutil
import struct
import subprocess
import tempfile
import zipfile
import zlib

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "Tests/NoveliaKindleTests/Fixtures"
FIXED_TIME = (2026, 1, 1, 0, 0, 0)


def png(width, height, rgb):
    raw = b"".join(b"\x00" + bytes(rgb) * width for _ in range(height))

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")


CSS = """
body { margin: 0 2%; }
h1.chapter { text-align: center; font-size: 1.6em; margin: 1em 0 1.2em; border-bottom: 2px solid #3a6b4f; }
p { text-indent: 2em; margin: 0 0 0.4em; line-height: 1.6; }
p.center { text-indent: 0; text-align: center; }
p.right { text-indent: 0; text-align: right; font-style: italic; }
.box { border: 1px solid #996633; background-color: #f6ead8; padding: 0.6em; margin: 1em 0; }
.big { font-size: 1.4em; font-weight: bold; }
.marker { text-indent: 0; }
table.grid { border-collapse: collapse; margin: 1em auto; }
table.grid td, table.grid th { border: 1px solid #555; padding: 0.2em 0.6em; }
aside.footnote { font-size: 0.85em; }
ol.duokan-footnote-content { font-size: 0.85em; }
@media amzn-kf8 {
  .kf8only { color: #b00020; }
  .mobionly { display: none; }
}
@media amzn-mobi {
  .kf8only { display: none; }
}
"""

XHTML = """<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="zh-CN" xml:lang="zh-CN">
<head><title>{title}</title><link rel="stylesheet" type="text/css" href="style.css"/></head>
<body>
{body}
</body>
</html>
"""

CHAPTERS = [
    ("ch1.xhtml", "第一章 排版", """
<h1 class="chapter">第一章 排版</h1>
<p>这一段用于检查首行缩进与行距。山谷里的风从早吹到晚，吹过石桥，也吹过晒在屋檐下的稻谷。</p>
<p class="center">居中的一行</p>
<p class="right">右对齐的斜体署名</p>
<div class="box"><p class="marker"><span class="big">边框盒</span>：棕色边框与米色底色应同时显示。</p></div>
<p class="marker kf8only">KF8 样式生效：这一行应为红色。</p>
<p class="marker mobionly">旧设备后备：这一行在 KF8 中应隐藏。</p>
<p>汉字注音：<ruby>山谷<rt>shān gǔ</rt></ruby>与<ruby>石桥<rt>shí qiáo</rt></ruby>。</p>
<p class="center"><img src="figure.png" alt="插图"/></p>
"""),
    ("ch2.xhtml", "第二章 注释", """
<h1 class="chapter">第二章 注释</h1>
<p>EPUB3 注脚<a epub:type="noteref" href="#fn1" id="r1">[1]</a>应以浮窗显示。</p>
<p>多看注释<a class="duokan-footnote" href="#note_1" id="dk1"><img src="note.png" alt="注"/></a>同样应以浮窗显示。</p>
<p>跨章尾注<a epub:type="noteref" href="ch3.xhtml#en1" id="r2">[2]</a>指向第三章。</p>
<aside epub:type="footnote" id="fn1" class="footnote"><p>注脚一：这是 EPUB3 注脚正文。</p></aside>
<ol class="duokan-footnote-content"><li class="duokan-footnote-item" id="note_1"><p>多看注释正文。</p></li></ol>
"""),
    ("ch3.xhtml", "第三章 尾注", """
<h1 class="chapter">第三章 尾注</h1>
<aside epub:type="endnote" id="en1"><p>尾注二：这是放在第三章的尾注正文。<a href="ch2.xhtml#r2">返回</a></p></aside>
"""),
    # 原生引擎（YueduCoreText）不支持表格，整章会显示失败页；单独成章，不影响其他章节的样式检查。
    ("ch4.xhtml", "第四章 表格", """
<h1 class="chapter">第四章 表格</h1>
<table class="grid"><tr><th>项目</th><th>数值</th></tr><tr><td>甲</td><td>1</td></tr><tr><td>乙</td><td>2</td></tr></table>
"""),
]

OPF = """<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid" xml:lang="zh-CN">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
<dc:identifier id="uid">urn:uuid:5b0d6a2e-7c1f-4a3e-9d55-6f1b2c3d4e5f</dc:identifier>
<dc:title>Kindle 排版样本</dc:title>
<dc:creator>Novelia 测试</dc:creator>
<dc:language>zh-CN</dc:language>
<meta property="dcterms:modified">2026-01-01T00:00:00Z</meta>
<meta name="cover" content="cover"/>
</metadata>
<manifest>
<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
<item id="css" href="style.css" media-type="text/css"/>
<item id="cover" href="cover.png" media-type="image/png" properties="cover-image"/>
<item id="figure" href="figure.png" media-type="image/png"/>
<item id="note" href="note.png" media-type="image/png"/>
{items}
</manifest>
<spine>{refs}</spine>
</package>
"""

NAV = """<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head><title>目录</title></head>
<body><nav epub:type="toc"><ol>{entries}</ol></nav></body>
</html>
"""


def write_epub(path):
    items = "\n".join(f'<item id="{n[:-6]}" href="{n}" media-type="application/xhtml+xml"/>' for n, _, _ in CHAPTERS)
    refs = "".join(f'<itemref idref="{n[:-6]}"/>' for n, _, _ in CHAPTERS)
    entries = "".join(f'<li><a href="{n}">{t}</a></li>' for n, t, _ in CHAPTERS)
    with zipfile.ZipFile(path, "w") as archive:
        def add(name, data, method=zipfile.ZIP_DEFLATED):
            info = zipfile.ZipInfo(name, FIXED_TIME)
            info.compress_type = method
            archive.writestr(info, data)
        add("mimetype", "application/epub+zip", zipfile.ZIP_STORED)
        add("META-INF/container.xml",
            '<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
            '<rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>')
        add("OEBPS/content.opf", OPF.format(items=items, refs=refs))
        add("OEBPS/nav.xhtml", NAV.format(entries=entries))
        add("OEBPS/style.css", CSS)
        add("OEBPS/cover.png", png(60, 80, (58, 107, 79)))
        add("OEBPS/figure.png", png(120, 40, (200, 80, 40)))
        add("OEBPS/note.png", png(8, 8, (53, 97, 143)))
        for name, title, body in CHAPTERS:
            add(f"OEBPS/{name}", XHTML.format(title=title, body=body))


def main():
    converter = shutil.which("ebook-convert")
    if not converter:
        raise SystemExit("需要 calibre 的 ebook-convert")
    with tempfile.TemporaryDirectory() as work:
        epub = Path(work) / "styles.epub"
        write_epub(epub)
        # AZW3 不压缩，便于下面原位改写样式表。
        for name, extra in [("kindle-styles.azw3", ["--dont-compress"]), ("kindle-styles.mobi", ["--mobi-file-type", "old"])]:
            subprocess.run([converter, str(epub), str(OUT / name), *extra], check=True,
                           stdout=subprocess.DEVNULL, env={**os.environ, "SOURCE_DATE_EPOCH": "1767225600"})
            print("wrote", OUT / name)
        restore_kindle_media_queries(OUT / "kindle-styles.azw3")


# calibre 转换时会自行求值 `@media amzn-*`，输出里不再有这些查询；而 kindlegen 制作的书会保留。
# 为了端到端覆盖展开逻辑，把 calibre 已求值的两条规则原位改回媒体查询写法（等长替换、空格补齐，
# 记录偏移不变）。未展开时第一行不是红色、第二行可见；展开后第一行为红色、第二行隐藏。
REWRITES = [
    (".marker1 {\n    color: #b00020;\n    display: block;\n    line-height: 1.6;\n    text-indent: 0;\n    margin: 0 0 0.4em\n    }",
     ".marker1{display:block;line-height:1.6;text-indent:0;margin:0 0 0.4em}@media amzn-kf8{.marker1{color:#b00020}}"),
    (".marker2 {\n    display: none;\n    line-height: 1.6;\n    text-indent: 0;\n    margin: 0 0 0.4em\n    }",
     "@media amzn-kf8{.marker2{display:none}}@media amzn-mobi{.marker1{display:none}}"),
]


def restore_kindle_media_queries(path):
    data = path.read_bytes()
    for original, replacement in REWRITES:
        original, replacement = original.encode(), replacement.encode()
        assert data.count(original) == 1, f"calibre 输出的样式与预期不同：{original[:20]!r}"
        assert len(replacement) <= len(original)
        data = data.replace(original, replacement.ljust(len(original)))
    path.write_bytes(data)


if __name__ == "__main__":
    main()
