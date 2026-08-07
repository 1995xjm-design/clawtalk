import Foundation
import OnnxRuntimeBindings
// 注意：onnxruntime SPM 的 product 名是 onnxruntime，但 Swift 模块名是 OnnxRuntimeBindings
// （见 microsoft/onnxruntime-swift-package-manager 官方测试与 fdddf/onnxruntime-spm 说明）。
// 若编译报 "No such module"，把上面一行改成 `import onnxruntime` 即可（个别打包版本以 product 名导出模块）。

// MARK: - 错误类型

enum KokoroTTSError: LocalizedError {
    /// 模型未下载（设置页负责下载入口）
    case modelNotDownloaded
    case sessionCreationFailed(String)
    case inferenceFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotDownloaded:
            return "本地语音模型未下载，请先在语音设置中下载"
        case .sessionCreationFailed(let detail):
            return "Kokoro 模型加载失败：\(detail)"
        case .inferenceFailed(let detail):
            return "Kokoro 语音合成失败：\(detail)"
        }
    }
}

// MARK: - vocab（v1.1-zh config.json 的 vocab，171 项，与模型 tokenizer 精确一致）

/// Kokoro v1.1-zh 的词表：音素字符 → token id。
/// 数据来源：https://huggingface.co/hexgrad/Kokoro-82M-v1.1-zh/raw/main/config.json
/// （含注音符号、声调数字 1-5、以及 misaki 中文 G2P 用到的特殊韵母符号如 月/十/压/言 等）
enum KokoroVocab {
    static let table: [String: Int64] = [
        ";": 1, ":": 2, ",": 3, ".": 4, "!": 5, "?": 6, "/": 7,
        "—": 9, "…": 10, "\"": 11, "(": 12, ")": 13, "“": 14, "”": 15,
        " ": 16, "̃": 17, "ʣ": 18, "ʥ": 19, "ʦ": 20, "ʨ": 21, "ᵝ": 22,
        "ㄓ": 23, "A": 24, "I": 25, "ㄅ": 30, "O": 31, "ㄆ": 32, "Q": 33,
        "R": 34, "S": 35, "T": 36, "ㄇ": 37, "ㄈ": 38, "W": 39, "ㄉ": 40,
        "Y": 41, "ᵊ": 42, "a": 43, "b": 44, "c": 45, "d": 46, "e": 47,
        "f": 48, "ㄊ": 49, "h": 50, "i": 51, "j": 52, "k": 53, "l": 54,
        "m": 55, "n": 56, "o": 57, "p": 58, "q": 59, "r": 60, "s": 61,
        "t": 62, "u": 63, "v": 64, "w": 65, "x": 66, "y": 67, "z": 68,
        "ɑ": 69, "ɐ": 70, "ɒ": 71, "æ": 72, "ㄋ": 73, "ㄌ": 74, "β": 75,
        "ɔ": 76, "ɕ": 77, "ç": 78, "ㄍ": 79, "ɖ": 80, "ð": 81, "ʤ": 82,
        "ə": 83, "ㄎ": 84, "ㄦ": 85, "ɛ": 86, "ɜ": 87, "ㄏ": 88, "ㄐ": 89,
        "ɟ": 90, "ㄑ": 91, "ɡ": 92, "ㄒ": 93, "ㄔ": 94, "ㄕ": 95, "ㄗ": 96,
        "ㄘ": 97, "ㄙ": 98, "月": 99, "ㄚ": 100, "ɨ": 101, "ɪ": 102, "ʝ": 103,
        "ㄛ": 104, "ㄝ": 105, "ㄞ": 106, "ㄟ": 107, "ㄠ": 108, "ㄡ": 109, "ɯ": 110,
        "ɰ": 111, "ŋ": 112, "ɳ": 113, "ɲ": 114, "ɴ": 115, "ø": 116, "ㄢ": 117,
        "ɸ": 118, "θ": 119, "œ": 120, "ㄣ": 121, "ㄤ": 122, "ɹ": 123, "ㄥ": 124,
        "ɾ": 125, "ㄖ": 126, "ㄧ": 127, "ʁ": 128, "ɽ": 129, "ʂ": 130, "ʃ": 131,
        "ʈ": 132, "ʧ": 133, "ㄨ": 134, "ʊ": 135, "ʋ": 136, "ㄩ": 137, "ʌ": 138,
        "ɣ": 139, "ㄜ": 140, "ㄭ": 141, "χ": 142, "ʎ": 143, "十": 144, "压": 145,
        "言": 146, "ʒ": 147, "ʔ": 148, "阳": 149, "要": 150, "阴": 151, "应": 152,
        "用": 153, "又": 154, "中": 155, "ˈ": 156, "ˌ": 157, "ː": 158, "穵": 159,
        "外": 160, "万": 161, "ʰ": 162, "王": 163, "ʲ": 164, "为": 165, "文": 166,
        "瓮": 167, "我": 168, "3": 169, "5": 170, "1": 171, "2": 172, "4": 173,
        "元": 175, "云": 176, "ᵻ": 177,
    ]
}

// MARK: - 拼音 → 注音映射（与 misaki 的 ZH_MAP 一致）

/// 简化中文 G2P 用到的拼音→注音符号表。
/// 数据来源：https://github.com/hexgrad/misaki/blob/main/misaki/zh_frontend.py 的 ZH_MAP（Apache-2.0）
enum KokoroZhuyin {
    /// 声母映射
    static let initialMap: [String: String] = [
        "b": "ㄅ", "p": "ㄆ", "m": "ㄇ", "f": "ㄈ",
        "d": "ㄉ", "t": "ㄊ", "n": "ㄋ", "l": "ㄌ",
        "g": "ㄍ", "k": "ㄎ", "h": "ㄏ",
        "j": "ㄐ", "q": "ㄑ", "x": "ㄒ",
        "zh": "ㄓ", "ch": "ㄔ", "sh": "ㄕ", "r": "ㄖ",
        "z": "ㄗ", "c": "ㄘ", "s": "ㄙ",
    ]

    /// 韵母映射（含 pypinyin 风格韵母：iou/uei/uen/ve/van/vn/iong 等）
    static let finalMap: [String: String] = [
        "a": "ㄚ", "o": "ㄛ", "e": "ㄜ", "i": "ㄧ", "u": "ㄨ", "v": "ㄩ",
        "ai": "ㄞ", "ei": "ㄟ", "ao": "ㄠ", "ou": "ㄡ",
        "an": "ㄢ", "en": "ㄣ", "ang": "ㄤ", "eng": "ㄥ", "er": "ㄦ",
        "ia": "压", "ie": "ㄝ", "iao": "要", "iou": "又",
        "ian": "言", "in": "阴", "iang": "阳", "ing": "应", "iong": "用",
        "ua": "穵", "uo": "我", "uai": "外", "uei": "为",
        "uan": "万", "uen": "文", "uang": "王", "ueng": "瓮", "ong": "中",
        "ve": "月", "van": "元", "vn": "云",
        "ii": "ㄭ", "iii": "十",
    ]
}

// MARK: - 简化中文 G2P

/// 简化版中文音素器（汉字 → 拼音 → 注音符号 + 声调数字）。
///
/// ⚠️ 这是任务允许的简化实现，与官方 misaki/espeak-ng 的区别：
/// - 内置约 400 个常用汉字的小字典（带声调），未知汉字直接跳过；
/// - 不做变调（三声变调/一不连读变调）与儿化音；
/// - 英文按字母直通（vocab 里大多数字母存在，效果有限）；
/// - 数字/符号按拼音直通会被跳过，建议调用前先把数字转成中文数字。
/// 输出格式与 misaki 中文（v1.1）一致：如 "你好" → "ㄋㄧ3 ㄏㄠ3"，
/// 与 v1.1-zh 的 vocab 完全匹配，tokenizer 不会丢字。
enum KokoroG2P {
    /// 汉字 → 拼音（带声调 1-5，5=轻声）。多音字取最常用读音（简化版，注释不展开）。
    private static let hanziPinyin: [Character: String] = [
        "我": "wo3", "你": "ni3", "他": "ta1", "她": "ta1", "它": "ta1", "们": "men5",
        "这": "zhe4", "那": "na4", "哪": "na3", "谁": "shei2", "什": "shen2", "么": "me5",
        "个": "ge4", "的": "de5", "是": "shi4", "不": "bu4",
        "一": "yi1", "二": "er4", "三": "san1", "四": "si4", "五": "wu3",
        "六": "liu4", "七": "qi1", "八": "ba1", "九": "jiu3", "十": "shi2",
        "百": "bai3", "千": "qian1", "万": "wan4", "亿": "yi4", "零": "ling2",
        "在": "zai4", "有": "you3", "和": "he2", "人": "ren2", "中": "zhong1",
        "大": "da4", "小": "xiao3", "上": "shang4", "下": "xia4",
        "左": "zuo3", "右": "you4", "前": "qian2", "后": "hou4",
        "里": "li3", "外": "wai4", "内": "nei4",
        "天": "tian1", "地": "di4", "日": "ri4", "月": "yue4", "星": "xing1",
        "年": "nian2", "时": "shi2", "分": "fen1", "秒": "miao3", "钟": "zhong1",
        "点": "dian3", "半": "ban4", "今": "jin1", "明": "ming2", "昨": "zuo2", "现": "xian4",
        "早": "zao3", "晚": "wan3", "午": "wu3", "好": "hao3",
        "吃": "chi1", "喝": "he1", "睡": "shui4", "起": "qi3", "来": "lai2",
        "去": "qu4", "回": "hui2", "走": "zou3", "跑": "pao3",
        "看": "kan4", "听": "ting1", "说": "shuo1", "讲": "jiang3",
        "读": "du2", "写": "xie3", "做": "zuo4", "想": "xiang3",
        "要": "yao4", "能": "neng2", "会": "hui4", "可": "ke3", "以": "yi3",
        "知": "zhi1", "道": "dao4", "问": "wen4", "答": "da2",
        "喜": "xi3", "欢": "huan1", "爱": "ai4", "高": "gao1", "兴": "xing4",
        "开": "kai1", "心": "xin1", "生": "sheng1", "活": "huo2",
        "工": "gong1", "作": "zuo4", "学": "xue2", "习": "xi2", "校": "xiao4",
        "老": "lao3", "师": "shi1", "世": "shi4", "界": "jie4", "朋": "peng2", "友": "you3", "家": "jia1",
        "爸": "ba4", "妈": "ma1", "哥": "ge1", "姐": "jie3", "弟": "di4", "妹": "mei4",
        "儿": "er2", "女": "nv3", "男": "nan2", "孩": "hai2", "子": "zi5",
        "名": "ming2", "字": "zi4", "话": "hua4", "语": "yu3", "文": "wen2",
        "英": "ying1", "美": "mei3", "国": "guo2", "京": "jing1", "广": "guang3", "州": "zhou1",
        "北": "bei3", "南": "nan2", "东": "dong1", "西": "xi1",
        "城": "cheng2", "市": "shi4", "省": "sheng3", "区": "qu1", "县": "xian4",
        "路": "lu4", "街": "jie1", "楼": "lou2", "号": "hao4", "门": "men2",
        "车": "che1", "火": "huo3", "站": "zhan4", "机": "ji1", "飞": "fei1",
        "水": "shui3", "电": "dian4", "气": "qi4", "风": "feng1",
        "雨": "yu3", "雪": "xue3", "云": "yun2", "阳": "yang2", "阴": "yin1", "晴": "qing2",
        "冷": "leng3", "热": "re4", "温": "wen1", "度": "du4",
        "快": "kuai4", "慢": "man4", "长": "chang2", "短": "duan3",
        "新": "xin1", "旧": "jiu4", "多": "duo1", "少": "shao3",
        "很": "hen3", "太": "tai4", "最": "zui4", "更": "geng4",
        "都": "dou1", "也": "ye3", "还": "hai2", "又": "you4", "再": "zai4",
        "才": "cai2", "就": "jiu4", "只": "zhi3", "但": "dan4", "而": "er2",
        "因": "yin1", "为": "wei4", "所": "suo3", "如": "ru2", "果": "guo3",
        "或": "huo4", "者": "zhe3", "与": "yu3", "及": "ji2", "从": "cong2",
        "到": "dao4", "对": "dui4", "给": "gei3", "把": "ba3", "被": "bei4",
        "让": "rang4", "请": "qing3", "谢": "xie4", "帮": "bang1", "忙": "mang2",
        "找": "zhao3", "拿": "na2", "放": "fang4",
        "买": "mai3", "卖": "mai4", "钱": "qian2", "贵": "gui4", "便": "bian4", "宜": "yi2",
        "块": "kuai4", "元": "yuan2", "角": "jiao3", "够": "gou4",
        "没": "mei2", "无": "wu2", "空": "kong4", "累": "lei4",
        "痛": "tong4", "病": "bing4", "药": "yao4", "医": "yi1", "院": "yuan4",
        "死": "si3", "轻": "qing1", "重": "zhong4", "难": "nan2", "易": "yi4",
        "简": "jian3", "单": "dan1", "复": "fu4", "杂": "za2",
        "真": "zhen1", "假": "jia3", "错": "cuo4", "坏": "huai4",
        "丑": "chou3", "胖": "pang4", "瘦": "shou4", "矮": "ai3",
        "远": "yuan3", "近": "jin4", "深": "shen1", "浅": "qian3",
        "亮": "liang4", "暗": "an4", "黑": "hei1", "白": "bai2",
        "红": "hong2", "绿": "lv4", "蓝": "lan2", "黄": "huang2",
        "紫": "zi3", "灰": "hui1", "颜": "yan2", "色": "se4",
        "头": "tou2", "脑": "nao3", "脸": "lian3", "眼": "yan3", "睛": "jing1",
        "耳": "er3", "鼻": "bi2", "口": "kou3", "牙": "ya2",
        "手": "shou3", "脚": "jiao3", "腿": "tui3", "身": "shen1", "体": "ti3",
        "血": "xue4", "骨": "gu3", "皮": "pi2", "毛": "mao2", "发": "fa4",
        "衣": "yi1", "服": "fu2", "鞋": "xie2", "帽": "mao4", "裤": "ku4",
        "饭": "fan4", "菜": "cai4", "肉": "rou4", "鱼": "yu2",
        "鸡": "ji1", "鸭": "ya1", "牛": "niu2", "羊": "yang2", "猪": "zhu1",
        "狗": "gou3", "猫": "mao1", "马": "ma3", "鸟": "niao3", "虫": "chong2",
        "树": "shu4", "花": "hua1", "草": "cao3", "木": "mu4",
        "山": "shan1", "河": "he2", "海": "hai3", "湖": "hu2", "江": "jiang1",
        "石": "shi2", "沙": "sha1", "土": "tu3", "田": "tian2",
        "房": "fang2", "屋": "wu1", "桌": "zhuo1", "椅": "yi3",
        "床": "chuang2", "灯": "deng1", "窗": "chuang1",
        "书": "shu1", "本": "ben3", "笔": "bi3", "纸": "zhi3", "画": "hua4",
        "歌": "ge1", "舞": "wu3", "音": "yin1", "乐": "le4",
        "网": "wang3", "信": "xin4", "邮": "you2", "件": "jian4",
        "包": "bao1", "箱": "xiang1", "银": "yin2", "行": "xing2", "卡": "ka3",
        "付": "fu4", "款": "kuan3", "账": "zhang4", "票": "piao4", "证": "zheng4",
        "备": "bei4", "用": "yong4", "打": "da3", "关": "guan1", "停": "ting2",
        "等": "deng3", "见": "jian4", "面": "mian4", "次": "ci4", "遍": "bian4",
        "玩": "wan2", "游": "you2", "戏": "xi4", "球": "qiu2",
        "运": "yun4", "动": "dong4", "步": "bu4", "练": "lian4",
        "休": "xiu1", "息": "xi1", "闲": "xian2", "待": "dai4",
        "遇": "yu4", "碰": "peng4", "摔": "shuai1", "倒": "dao3",
        "扶": "fu2", "救": "jiu4", "命": "ming4",
        "安": "an1", "全": "quan2", "危": "wei1", "险": "xian3",
        "注": "zhu4", "意": "yi4", "静": "jing4", "吵": "chao3", "闹": "nao4",
        "笑": "xiao4", "哭": "ku1", "喊": "han3", "叫": "jiao4", "骂": "ma4",
        "抱": "bao4", "歉": "qian4", "祝": "zhu4", "福": "fu2", "贺": "he4",
        "期": "qi1", "礼": "li3", "物": "wu4", "结": "jie2", "婚": "hun1", "节": "jie2",
        "旅": "lv3", "住": "zhu4", "店": "dian4", "宾": "bin1", "馆": "guan3",
        "厅": "ting1", "厨": "chu2", "卫": "wei4", "浴": "yu4", "厕": "ce4",
        "洗": "xi3", "澡": "zao3", "刷": "shua1", "理": "li3", "剪": "jian3",
        "修": "xiu1", "换": "huan4", "超": "chao1", "商": "shang1", "场": "chang3",
        "价": "jia4", "格": "ge2", "折": "zhe2", "减": "jian3", "免": "mian3",
        "费": "fei4", "税": "shui4", "资": "zi1", "薪": "xin1", "职": "zhi2",
        "业": "ye4", "公": "gong1", "司": "si1", "班": "ban1",
        "加": "jia1", "油": "you2", "努": "nu3", "力": "li4",
        "成": "cheng2", "功": "gong1", "失": "shi1", "败": "bai4",
        "试": "shi4", "验": "yan4", "考": "kao3", "题": "ti2", "案": "an4",
        "数": "shu4", "化": "hua4", "历": "li4", "史": "shi3", "图": "tu2",
        "课": "ke4", "表": "biao3", "章": "zhang1", "句": "ju4", "词": "ci2",
        "思": "si1", "念": "nian4", "记": "ji4", "忆": "yi4", "忘": "wang4",
        "办": "ban4", "法": "fa3", "方": "fang1", "式": "shi4",
        "计": "ji4", "划": "hua4", "算": "suan4", "程": "cheng2", "序": "xu4",
        "软": "ruan3", "硬": "ying4", "盘": "pan2", "屏": "ping2", "幕": "mu4",
        "键": "jian4", "鼠": "shu3", "标": "biao1", "输": "shu1", "入": "ru4",
        "出": "chu1", "页": "ye4", "搜": "sou1", "索": "suo3", "载": "zai4",
        "传": "chuan2", "消": "xiao1", "微": "wei1", "博": "bo2",
        "接": "jie1", "挂": "gua4", "响": "xiang3", "铃": "ling2",
        "通": "tong1", "断": "duan4",
        "整": "zheng3", "齐": "qi2", "清": "qing1", "楚": "chu3",
        "干": "gan4", "净": "jing4", "脏": "zang1", "乱": "luan4", "急": "ji2",
        "困": "kun4", "饿": "e4", "渴": "ke3", "饱": "bao3",
        "香": "xiang1", "甜": "tian2", "苦": "ku3", "辣": "la4",
        "酸": "suan1", "咸": "xian2", "淡": "dan4", "鲜": "xian1",
        "破": "po4", "差": "cha4", "直": "zhi2", "弯": "wan1",
        "平": "ping2", "正": "zheng4", "反": "fan3",
        "边": "bian1", "旁": "pang2", "间": "jian1",
        "向": "xiang4", "往": "wang3", "按": "an4", "照": "zhao4", "据": "ju4",
        "于": "yu2", "至": "zhi4", "周": "zhou1", "刻": "ke4",
        "啊": "a5", "吧": "ba5", "吗": "ma5", "呢": "ne5", "呀": "ya5", "啦": "la5",
        "嘛": "ma5", "哈": "ha1", "嘿": "hei1", "哦": "o2", "唉": "ai1", "哎": "ai1",
        "了": "le5", "着": "zhe5", "过": "guo4", "得": "de5",
        "位": "wei4", "条": "tiao2", "张": "zhang1", "台": "tai2",
        "辆": "liang4", "双": "shuang1", "些": "xie1", "每": "mei3",
        "另": "ling4", "其": "qi2", "此": "ci3", "何": "he2",
    ]

    /// 全角标点 → vocab 支持的标点。
    private static let punctuationMap: [Character: Character] = [
        "，": ",", "。": ".", "！": "!", "？": "?", "：": ":", "；": ";",
        "、": ",", "（": "(", "）": ")", "「": "“", "」": "”",
        "『": "“", "』": "”", "《": "“", "》": "”", "【": "(", "】": ")",
        "‘": "“", "’": "”", "·": " ", "～": " ", "—": "—", "…": "…",
    ]

    /// 文本 → 音素串（注音 + 声调数字）。
    static func phonemize(_ text: String) -> String {
        var result = ""
        for ch in text {
            switch classify(ch) {
            case .hanzi:
                guard let pinyin = hanziPinyin[ch] else { continue } // 简化版：未知字跳过
                let syllable = pinyinToZhuyin(pinyin)
                if !syllable.isEmpty {
                    if !result.isEmpty, result.last != " " {
                        result.append(" ")
                    }
                    result.append(syllable)
                }
            case .punct:
                let mapped = punctuationMap[ch] ?? ch
                if KokoroVocab.table[String(mapped)] != nil {
                    if !result.isEmpty, result.last != " ", !" \n\t".contains(mapped) {
                        result.append(" ")
                    }
                    result.append(mapped)
                }
            case .latin:
                // 简化版：英文字母直通（vocab 含大多数字母；'g' 等个别字母会被 tokenizer 丢弃）
                if let upper = ch.unicodeScalars.first?.value, (0x41...0x5A).contains(upper) || (0x61...0x7A).contains(upper) {
                    if !result.isEmpty, result.last != " " {
                        result.append(" ")
                    }
                    result.append(ch)
                }
            case .space:
                if result.last != " " {
                    result.append(" ")
                }
            case .skip:
                break // 数字/符号/emoji：跳过（建议调用前把数字转中文数字）
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private enum CharClass {
        case hanzi, punct, latin, space, skip
    }

    private static func classify(_ ch: Character) -> CharClass {
        guard let scalar = ch.unicodeScalars.first, ch.unicodeScalars.count == 1 else {
            return .skip
        }
        let value = scalar.value
        if (0x3400...0x4DBF).contains(value) || (0x4E00...0x9FFF).contains(value) {
            return .hanzi
        }
        if (0x41...0x5A).contains(value) || (0x61...0x7A).contains(value) {
            return .latin
        }
        if value == 0x20 || value == 0x09 || value == 0x0A || value == 0x0D {
            return .space
        }
        if KokoroVocab.table[String(ch)] != nil || punctuationMap[ch] != nil {
            return .punct
        }
        return .skip
    }

    /// 单个拼音（含声调）→ 注音串。实现与 misaki/pypinyin 的韵母规则一致。
    static func pinyinToZhuyin(_ pinyin: String) -> String {
        var syllable = pinyin
        var tone = ""
        if let last = syllable.last, "012345".contains(last) {
            tone = last == "0" ? "5" : String(last)
            syllable.removeLast()
        }
        guard !syllable.isEmpty else { return tone }

        // 零声母 y/w 归一（对应 pypinyin FINALS 输出）
        if syllable.hasPrefix("yu") {
            syllable = "v" + syllable.dropFirst(2)       // yu→v, yue→ve, yuan→van, yun→vn
        } else if syllable.hasPrefix("yi") {
            syllable = String(syllable.dropFirst())      // yi→i, yin→in, ying→ing
        } else if syllable.hasPrefix("y") {
            if syllable == "yong" {
                syllable = "iong"
            } else {
                syllable = "i" + syllable.dropFirst()    // ya→ia, ye→ie, yao→iao, yan→ian, yang→iang, you→iou
            }
        } else if syllable.hasPrefix("wu") {
            syllable = String(syllable.dropFirst())      // wu→u
        } else if syllable.hasPrefix("w") {
            syllable = "u" + syllable.dropFirst()        // wo→uo, wei→uei, wan→uan, wen→uen, wang→uang, weng→ueng
        }

        // 声母（先试双字母 zh/ch/sh）
        var initial = ""
        if syllable.count >= 2 {
            let two = String(syllable.prefix(2))
            if two == "zh" || two == "ch" || two == "sh" {
                initial = two
                syllable.removeFirst(2)
            }
        }
        if initial.isEmpty, let first = syllable.first, "bpmfdtnlgkhjqxrzcs".contains(first) {
            initial = String(first)
            syllable.removeFirst()
        }

        // j/q/x + u → ü(v)：ju→jv, qu→qv, xu→xv, jue→jve, juan→jvan, jun→jvn
        if ["j", "q", "x"].contains(initial), syllable.hasPrefix("u") {
            syllable = "v" + syllable.dropFirst()
        }
        // 韵母标准化（pinyin 拼写 → pypinyin 韵母）：ui→uei, iu→iou, un→uen
        switch syllable {
        case "ui": syllable = "uei"
        case "iu": syllable = "iou"
        case "un": syllable = "uen"
        default: break
        }
        // zi/ci/si → ii；zhi/chi/shi/ri → iii
        if syllable == "i" {
            if ["z", "c", "s"].contains(initial) {
                syllable = "ii"
            } else if ["zh", "ch", "sh", "r"].contains(initial) {
                syllable = "iii"
            }
        }

        let initialSymbol = KokoroZhuyin.initialMap[initial] ?? ""
        let finalSymbol = KokoroZhuyin.finalMap[syllable] ?? ""
        return initialSymbol + finalSymbol + tone
    }
}

// MARK: - TTS 服务

/// Kokoro 本地神经 TTS（82M 参数，Apache-2.0，完全离线）。
///
/// 推理管线（与 kokoro-onnx 一致）：
/// 文本 → 简化中文 G2P（注音+声调）→ vocab tokenize → ONNX Runtime 推理
/// （input_ids int64[1,L] / style float32[1,256] / speed int32[1]）→ waveform float32（24kHz）
/// → 按 100ms 分片输出 Float32 PCM（SpeechService 协议要求的格式）。
///
/// 模型输入名兼容两代导出：
/// - 新导出（v1.1-zh）：input_ids + int32 speed；
/// - 旧导出（v1.0）：tokens + float32 speed。
/// 实际以 ORT session 的 inputNames 为准自动选择。
final class KokoroTTSService: SpeechService {
    /// 最长音素 token 数（kokoro-onnx MAX_PHONEME_LENGTH=510，含首尾 pad 需留 2 个）
    static let maxPhonemeTokens = 508
    /// 输出波形每 100ms 的采样数（24kHz × 0.1s）
    private static let samplesPerChunk = 2400
    static let waveformOutputName = "waveform"

    private let modelManager: KokoroModelManager
    /// 音色名（v1.1-zh 音色包内，如 "zf_001" 女声、"zm_010" 男声）
    let voice: String
    /// 语速：1.0 正常、2.0 两倍速（模型 speed 为 int32，0.5~2.0 取整后 1 或 2）
    let speed: Float

    private let engineLock = NSLock()
    private var cachedEngine: Engine?
    private var currentTask: Task<Void, Never>?

    /// ClawTalkApp / 设置页可这样初始化：
    ///   KokoroTTSService(modelManager: KokoroModelManager.shared)
    init(modelManager: KokoroModelManager = .shared, voice: String = "zf_001", speed: Float = 1.0) {
        self.modelManager = modelManager
        self.voice = voice
        self.speed = min(max(speed, 0.5), 2.0)
    }

    // MARK: SpeechService

    func streamSpeech(text: String) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                do {
                    guard KokoroModelPaths.filesExist else {
                        throw KokoroTTSError.modelNotDownloaded
                    }
                    let engine = try self.engine()
                    let phonemes = KokoroG2P.phonemize(text)
                    guard !phonemes.isEmpty else {
                        continuation.finish()
                        return
                    }
                    let chunks = Self.splitPhonemes(phonemes, maxLength: Self.maxPhonemeTokens)
                    for chunk in chunks {
                        if Task.isCancelled { break }
                        let samples = try engine.synthesize(phonemes: chunk, speed: self.speed)
                        if samples.isEmpty { continue }
                        var offset = 0
                        while offset < samples.count {
                            if Task.isCancelled { break }
                            let end = min(offset + Self.samplesPerChunk, samples.count)
                            let slice = Array(samples[offset..<end])
                            continuation.yield(Self.float32PCMData(slice))
                            offset = end
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            currentTask = task
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func stop() {
        currentTask?.cancel()
        currentTask = nil
    }

    // MARK: - ORT 引擎（惰性加载，线程安全）

    private func engine() throws -> Engine {
        engineLock.lock()
        defer { engineLock.unlock() }
        if let cachedEngine { return cachedEngine }
        do {
            let pack = try KokoroLoadVoicePack(named: voice)
            let engine = try Engine(modelURL: KokoroModelPaths.modelFile, voicePack: pack)
            cachedEngine = engine
            return engine
        } catch let error as KokoroTTSError {
            throw error
        } catch {
            throw KokoroTTSError.sessionCreationFailed(error.localizedDescription)
        }
    }

    /// 按空格把音素串切成 ≤ maxLength 的音素段（每段一次 ORT 推理）。
    static func splitPhonemes(_ phonemes: String, maxLength: Int) -> [String] {
        var chunks: [String] = []
        var current = ""
        var lastSpaceIndex = -1
        for ch in phonemes {
            if ch == " " { lastSpaceIndex = current.count }
            current.append(ch)
            if current.count >= maxLength {
                if lastSpaceIndex > 0 {
                    let cut = current.index(current.startIndex, offsetBy: lastSpaceIndex)
                    let head = String(current[..<cut]).trimmingCharacters(in: .whitespaces)
                    let tail = String(current[cut...]).trimmingCharacters(in: .whitespaces)
                    if !head.isEmpty { chunks.append(head) }
                    current = tail
                    lastSpaceIndex = -1
                } else {
                    chunks.append(current)
                    current = ""
                    lastSpaceIndex = -1
                }
            }
        }
        if !current.isEmpty {
            chunks.append(current.trimmingCharacters(in: .whitespaces))
        }
        return chunks
    }

    /// [Float] → 24kHz 单声道 Float32 PCM 的 Data（小端，与 AudioPlaybackManager 匹配）。
    static func float32PCMData(_ samples: [Float]) -> Data {
        samples.withUnsafeBytes { Data($0) }
    }
}

// MARK: - ORT 推理引擎

/// 封装 ORTSession + 音色包：一次推理 = tokenize + 组张量 + session.run → [Float] 波形。
private final class Engine {
    private let env: ORTEnv
    private let session: ORTSession
    private let inputNames: [String]
    private let voicePack: KokoroVoicePack

    init(modelURL: URL, voicePack: KokoroVoicePack) throws {
        self.voicePack = voicePack
        do {
            let env = try ORTEnv(loggingLevel: .warning)
            let options = try ORTSessionOptions()
            // CPU 线程数：手机核数减半，避免抢占主线程过多算力
            _ = try options.setIntraOpNumThreads(Int32(max(1, ProcessInfo.processInfo.activeProcessorCount / 2)))
            _ = try options.setGraphOptimizationLevel(.all)
            self.env = env
            self.session = try ORTSession(env: env, modelPath: modelURL.path, sessionOptions: options)
            self.inputNames = try session.inputNames()
        } catch {
            throw KokoroTTSError.sessionCreationFailed(error.localizedDescription)
        }
    }

    /// 对一段音素串合成音频（返回 24kHz Float32 波形）。
    func synthesize(phonemes: String, speed: Float) throws -> [Float] {
        var ids: [Int64] = []
        for ch in phonemes {
            if let id = KokoroVocab.table[String(ch)] {
                ids.append(id)
            }
        }
        guard !ids.isEmpty else { return [] }
        if ids.count > KokoroTTSService.maxPhonemeTokens {
            ids = Array(ids.prefix(KokoroTTSService.maxPhonemeTokens))
        }
        let paddedIDs = [0] + ids + [0] // 首尾 pad（vocab id 0 = pad）

        // style = voicePack[len(phonemes) - 1]（与 kokoro pipeline.py 的 pack[len(ps)-1] 一致）
        let styleIndex = min(max(phonemes.count - 1, 0), voicePack.rows - 1)
        let style = try voicePack.style(at: styleIndex)

        let inputs = try Self.buildInputs(inputNames: inputNames, paddedIDs: paddedIDs, style: style, speed: speed)

        let outputs: [String: ORTValue]
        do {
            outputs = try session.run(withInputs: inputs, outputNames: [KokoroTTSService.waveformOutputName], runOptions: nil)
        } catch {
            // 兜底：部分导出的输出名不同（如 audio），改用"全部输出"取第一个
            outputs = try session.run(withInputs: inputs, outputNames: [], runOptions: nil)
        }
        guard let value = outputs[KokoroTTSService.waveformOutputName] ?? outputs.values.first else {
            return []
        }
        let data = try value.tensorData()
        let sampleCount = data.length / MemoryLayout<Float>.size
        guard sampleCount > 0 else { return [] }
        let bytes = data.bytes
        let ptr = bytes.bindMemory(to: Float.self, capacity: sampleCount)
        return Array(UnsafeBufferPointer(start: ptr, count: sampleCount))
    }

    /// 组 ORT 输入张量。兼容新旧导出：
    /// - 新（input_ids）：tokens 名 input_ids，speed=int32
    /// - 旧（tokens）：tokens 名 tokens，speed=float32
    private static func buildInputs(inputNames: [String], paddedIDs: [Int64], style: [Float], speed: Float) throws -> [String: ORTValue] {
        let usesInputIDs = inputNames.contains("input_ids")
        let tokenName = usesInputIDs ? "input_ids" : "tokens"

        var tokenData = Data()
        paddedIDs.withUnsafeBytes { tokenData = Data($0) }
        let tokensValue = try ORTValue(
            tensorData: NSMutableData(data: tokenData),
            elementType: .int64,
            shape: [NSNumber(value: 1), NSNumber(value: paddedIDs.count)]
        )

        var styleData = Data()
        style.withUnsafeBytes { styleData = Data($0) }
        let styleValue = try ORTValue(
            tensorData: NSMutableData(data: styleData),
            elementType: .float,
            shape: [NSNumber(value: 1), NSNumber(value: style.count)]
        )

        var inputs: [String: ORTValue] = [tokenName: tokensValue, "style": styleValue]

        if usesInputIDs {
            // 新导出：speed 为 int32（1=正常，2=两倍速；0.5~2.0 取整）
            let speedInt = Int32(min(max(Int(speed), 1), 9))
            var speedData = Data()
            withUnsafeBytes(of: speedInt) { speedData = Data($0) }
            inputs["speed"] = try ORTValue(
                tensorData: NSMutableData(data: speedData),
                elementType: .int32,
                shape: [NSNumber(value: 1)]
            )
        } else {
            // 旧导出：speed 为 float32
            var speedData = Data()
            withUnsafeBytes(of: speed) { speedData = Data($0) }
            inputs["speed"] = try ORTValue(
                tensorData: NSMutableData(data: speedData),
                elementType: .float,
                shape: [NSNumber(value: 1)]
            )
        }
        return inputs
    }
}