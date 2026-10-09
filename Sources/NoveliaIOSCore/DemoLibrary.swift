import Foundation

/// Fictional local content used to exercise the iOS reader before API integration.
public enum DemoLibrary {
    public static let novels: [Novel] = [
        Novel(
            id: "moonlit-archive",
            title: "月光档案室",
            author: "七海灯",
            summary: "深夜的旧图书馆里，每一本遗失的书都会带来一位陌生访客。新来的管理员开始整理目录，也慢慢发现这些故事彼此相连。",
            genres: ["奇幻", "日常", "连载中"],
            chapters: [
                NovelChapter(
                    id: "moon-01",
                    title: "第一章　闭馆后的来客",
                    originalText: "雨が止んだのは、時計の針が午前零時を指したころだった。\n\n古い図書館の窓に、街灯の光が細く差し込む。新米司書の澪は、返却台に置かれた見覚えのない本を手に取った。\n\n表紙には題名がない。けれど、開いた最初のページには、彼女の名前が書かれていた。",
                    translatedText: "雨停下时，时钟的指针刚好指向午夜。\n\n街灯的光细细地落进旧图书馆的窗户。新来的管理员澪拿起了放在还书台上的陌生书本。\n\n封面没有标题。但翻开第一页，上面却写着她的名字。"
                ),
                NovelChapter(
                    id: "moon-02",
                    title: "第二章　没有标题的书",
                    originalText: "澪は本を閉じ、もう一度表紙を確かめた。紙の匂いに混じって、雨上がりの庭のような香りがする。\n\n「それは、まだ誰にも読まれていない物語です」\n\n背後から声がした。振り返ると、濡れた傘を持った少年が入口に立っていた。",
                    translatedText: "澪合上书，又仔细看了一遍封面。纸张的气味里，混着雨后庭院般的清香。\n\n“那是一本还没有人读过的故事。”\n\n身后传来一个声音。她转过身，一个拿着湿伞的少年站在入口处。"
                ),
                NovelChapter(
                    id: "moon-03",
                    title: "第三章　借阅期限",
                    originalText: "少年はカウンターに一枚のカードを置いた。返却期限の欄には、明日の日付が記されている。\n\n「この本を借りたいの？」\n\n彼はうなずいた。澪が貸出印を押すと、図書館の奥で、古い時計がひとつ鳴った。",
                    translatedText: "少年把一张借阅卡放到柜台上。归还日期一栏，写着明天。\n\n“你想借这本书吗？”\n\n他点了点头。澪盖下借阅章时，图书馆深处的一座老钟响了一声。"
                )
            ],
            accent: .plum
        ),
        Novel(
            id: "paper-sea",
            title: "纸海航线",
            author: "青木遥",
            summary: "少年航海士在一艘由书页拼成的船上寻找失落的海图。每座岛屿都藏着一段尚未写完的传说。",
            genres: ["冒险", "奇幻", "已完结"],
            chapters: [
                NovelChapter(
                    id: "paper-01",
                    title: "第一章　船从书架启航",
                    originalText: "本棚のいちばん高い場所に、海の匂いがした。\n\n航は梯子を上り、背表紙の青い本を引き抜く。すると、床に広げた地図の上で、紙の帆船がゆっくりと動き始めた。",
                    translatedText: "最高那层书架上传来海的气息。\n\n航爬上梯子，抽出一本蓝色书脊的书。随后，摊在地板上的地图中，那艘纸帆船缓缓动了起来。"
                ),
                NovelChapter(
                    id: "paper-02",
                    title: "第二章　风向标的约定",
                    originalText: "「風は、帰り道を覚えているよ」\n\n港の灯台守はそう言って、小さな羅針盤を渡した。針は北ではなく、まだ名前のない島を指していた。",
                    translatedText: "“风会记得回去的路。”\n\n港口的灯塔守这样说着，把一只小小的罗盘交给他。指针没有指向北方，而是指向一座尚未命名的岛屿。"
                )
            ],
            accent: .ocean
        )
    ]
}
