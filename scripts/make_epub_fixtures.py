#!/usr/bin/env python3
"""生成 Tests/NoveliaEPUBTests 使用的合成 EPUB 测试样本。

全部文字与图片都在此生成，样本不含任何第三方内容。
修改本脚本后重新运行即可；输出是确定性的。
"""
from pathlib import Path
import struct
import zipfile
import zlib

OUT = Path(__file__).resolve().parents[1] / "Tests/NoveliaEPUBTests/Fixtures"
FIXED_TIME = (2026, 1, 1, 0, 0, 0)


def png(width, height, rgb=(200, 80, 40)):
    raw = b"".join(b"\x00" + bytes(rgb) * width for _ in range(height))

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")


CONTAINER = ('<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
             '<rootfiles><rootfile full-path="{root}" media-type="application/oebps-package+xml"/></rootfiles></container>')
XHTML = ('<?xml version="1.0" encoding="utf-8"?><html xmlns="http://www.w3.org/1999/xhtml"><head><title>c</title>'
         '{head}</head><body>{body}</body></html>')


def write(name, opf, files, root="OEBPS/content.opf"):
    with zipfile.ZipFile(OUT / f"{name}.epub", "w") as archive:
        def add(path, data, compress=zipfile.ZIP_DEFLATED):
            info = zipfile.ZipInfo(path, FIXED_TIME)
            info.compress_type = compress
            archive.writestr(info, data)
        add("mimetype", "application/epub+zip", zipfile.ZIP_STORED)
        add("META-INF/container.xml", CONTAINER.format(root=root))
        add(root, opf)
        for path, data in files.items():
            add(path, data)


def opf(version, metadata, manifest, chapter_href="Text/c1.xhtml", ns_opf=False, extra_items=""):
    ns = ' xmlns:opf="http://www.idpf.org/2007/opf"' if ns_opf else ""
    return f'''<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="{version}" unique-identifier="uid"{ns}>
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
<dc:identifier id="uid">urn:uuid:00000000-0000-4000-8000-000000000000</dc:identifier><dc:language>zh</dc:language>
{metadata}
</metadata>
<manifest><item id="c1" href="{chapter_href}" media-type="application/xhtml+xml"/>{manifest}{extra_items}</manifest>
<spine><itemref idref="c1"/></spine></package>'''


def simple_chapter():
    return XHTML.format(head="", body="<p>text</p>")


def metadata_fixtures():
    # EPUB2：<meta name="cover">、opf:role 过滤、标题中的实体。
    write("epub2_meta_cover", opf("2.0", '''<dc:title>文庫 &amp; 測試</dc:title>
<dc:creator opf:role="aut">作者甲</dc:creator><dc:creator opf:role="ill">畫師乙</dc:creator><dc:creator>作者丙</dc:creator>
<dc:description>&lt;p&gt;簡介 第一行&lt;/p&gt;</dc:description>
<meta name="cover" content="cover-img"/>''', '<item id="cover-img" href="Images/cover.png" media-type="image/png"/>', ns_opf=True),
          {"OEBPS/Text/c1.xhtml": simple_chapter(), "OEBPS/Images/cover.png": png(600, 900)})
    # EPUB3：cover-image 属性、refines 角色、title-type 为 main 的标题排在第二、CDATA、编码过的 href。
    write("epub3_refines", opf("3.0", '''<dc:title id="t1">Subtitle Here</dc:title><dc:title id="t2">Main Title</dc:title>
<meta refines="#t1" property="title-type">subtitle</meta><meta refines="#t2" property="title-type">main</meta>
<dc:creator id="a1">Author One</dc:creator><meta refines="#a1" property="role" scheme="marc:relators">aut</meta>
<dc:creator id="a2">Translator Two</dc:creator><meta refines="#a2" property="role" scheme="marc:relators">trl</meta>
<dc:creator id="a3">Odd Role</dc:creator><meta refines="#a3" property="role" scheme="marc:relators">xyz</meta>
<dc:description><![CDATA[<b>Bold</b> desc]]></dc:description>''', '<item id="cv" href="Images/c%20over.png" media-type="image/png" properties="cover-image"/>'),
          {"OEBPS/Text/c1.xhtml": simple_chapter(), "OEBPS/Images/c over.png": png(100, 120)})
    # OPF 位于压缩包根目录、无封面、标题带首尾空白。
    write("root_opf_nocover", opf("2.0", "<dc:title>  Spaced   Title  </dc:title><dc:creator>Solo</dc:creator>", "", chapter_href="c1.xhtml"),
          {"c1.xhtml": simple_chapter()}, root="content.opf")
    # 小于缩略图尺寸的封面不放大；简介中含嵌套标签。
    write("small_cover", opf("3.0", "<dc:title>Small</dc:title><dc:description>Line <i>one</i>\n line two</dc:description>",
                             '<item id="x" href="../cover.png" media-type="image/png" properties="nav cover-image"/>'),
          {"OEBPS/Text/c1.xhtml": simple_chapter(), "cover.png": png(80, 60)})
    # 宽封面按宽度限制缩放。
    write("wide_cover", opf("2.0", '<dc:title>Wide</dc:title><meta content="w" name="cover"/>', '<item id="w" href="w.png" media-type="image/png"/>'),
          {"OEBPS/Text/c1.xhtml": simple_chapter(), "OEBPS/w.png": png(1000, 300)})


SUBJECTS = ["店长", "她", "我", "常客", "店员", "那位客人", "同事", "老板"]
VERBS = ["收拾着桌上的卡牌", "翻开了新的说明书", "把咖啡放到柜台上", "数着剩下的骰子", "望向窗外的雨", "整理起明天的预约",
         "叹了一口气", "笑着摇了摇头", "把椅子推回原位", "在笔记本上写了几行字"]
TAILS = ["。", "，然后沉默了片刻。", "，看起来心情不错。", "……", "，却什么也没说。", "，像是在等谁回答。"]
LINES = ["「真的吗？」", "「这样就好了！」", "「等一下……再给我一点时间。」", "「你觉得呢？」", "「『规则书』放在哪里了？」",
         "「好啊，那就再来一局吧。」", "「嗯，嗯，我明白了。」", "「今天的客人好像特别多呢。」"]


def justified_fixture():
    """在触发间隙问题的 CSS 下排版的原创中文段落。"""
    paragraphs = []
    state = 7
    for index in range(60):
        state = (state * 1103515245 + 12345) % 2**31
        if index % 3 == 2:
            paragraphs.append(LINES[state % len(LINES)] + SUBJECTS[(state >> 3) % len(SUBJECTS)] + VERBS[(state >> 6) % len(VERBS)] + "。")
        else:
            parts = []
            for step in range(2 + state % 4):
                state = (state * 1103515245 + 12345) % 2**31
                parts.append(SUBJECTS[state % len(SUBJECTS)] + VERBS[(state >> 4) % len(VERBS)] + TAILS[(state >> 9) % len(TAILS)])
            paragraphs.append("".join(parts))
    css = ("body{margin:0;padding:0 5px;line-height:130%;text-align:justify;text-justify:inter-ideograph;}"
           "p{text-indent:2em;margin:0.5em 0;}")
    body = "<h1>第一话 雨天的桌游店</h1>" + "".join(f"<p>{text}</p>" for text in paragraphs)
    chapter = XHTML.format(head='<link href="../Styles/style.css" type="text/css" rel="stylesheet"/>', body=body)
    write("justified_cjk", opf("3.0", "<dc:title>两端对齐测试</dc:title><dc:creator>Novelia</dc:creator>", "",
                               extra_items='<item id="css" href="Styles/style.css" media-type="text/css"/>'),
          {"OEBPS/Text/c1.xhtml": chapter, "OEBPS/Styles/style.css": css})


if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    metadata_fixtures()
    justified_fixture()
    for path in sorted(OUT.glob("*.epub")):
        print(f"{path.name}\t{path.stat().st_size}")
