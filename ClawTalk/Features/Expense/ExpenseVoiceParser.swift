import Foundation

/// 语音记账的自然语言解析：把「今天买咖啡花了28」「打车35块」「收到工资8000」
/// 拆成金额 + 类型（收入/支出）+ 类别 + 备注（转写原文）。
/// 解析不出金额返回 nil，由页面弹 alert 引导手动填写（诚实，不做假解析）。
///
/// 规则表（纯本地规则，不引第三方库）：
/// - 金额识别（按优先级）：
///   1. ¥/￥ 前缀数字：「¥28」→ 28
///   2. 数字 + 单位：「28元」「35块」「28.5元」「28块钱」
///   3. 中文数字 + 单位：「二十八块」「八百元」
///   4. 花钱动词后裸数字（动词与数字间可隔最多 4 个非数字字符，如「交房租2000」）：
///      「花了28」「付了35」「买咖啡花了28」「交房租2000」
///   5. 收入词 + 阿拉伯裸数字：「收到工资8000」
///   6. 收入词 + 中文裸数字：「工资八千五」→ 8500
///   其余裸数字不认（例如「打车28」没有单位/动词 → nil，诚实弹手动填）
/// - 类型：含收入词 → 收入；否则默认支出。
/// - 类别关键词（长词优先、按优先级检测，避免「买咖啡」被「买」误判购物）：
///   医疗：药/医院/看病/挂号/检查/诊所
///   居住：房租/房贷/租房/水电/水费/电费/燃气/物业
///   交通：打车/出租车/滴滴/车费/地铁/公交/加油/油费/停车/高铁/火车/机票
///   娱乐：电影/游戏/娱乐/KTV/唱歌/门票/演唱会/充值/健身/会员
///   餐饮：吃饭/早餐/午餐/晚餐/午饭/晚饭/宵夜/夜宵/咖啡/奶茶/外卖/点餐/餐厅/火锅/烧烤/零食/水果/买菜/吃
///   购物：买衣服/衣服/买鞋/鞋/购物/包包/化妆品/超市/商场/网购/淘宝/京东/买
///   其他：兜底
enum ExpenseVoiceParser {

    /// 解析草稿：金额 / 类型 / 类别 / 备注（转写原文）
    struct Draft: Equatable {
        let amount: Double
        let type: ExpenseType
        let category: ExpenseCategory
        let note: String
    }

    static func parse(_ raw: String) -> Draft? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        guard let amount = extractAmount(from: text) else { return nil }

        let isIncome = classifyIncome(text: text)
        let type: ExpenseType = isIncome ? .income : .expense
        return Draft(
            amount: amount,
            type: type,
            category: category(from: text),
            note: text
        )
    }


    /// 多笔解析：一次语音可能说多笔收支（如“买了咖啡28，打车35，收到工资8000”）。
    /// 按标点/连词切段后逐段解析，返回所有成功解析的草稿（保留顺序，去重）。
    static func parseAll(_ raw: String) -> [Draft] {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        let normalized = text
            .replacingOccurrences(of: "，", with: "|")
            .replacingOccurrences(of: ",", with: "|")
            .replacingOccurrences(of: "。", with: "|")
            .replacingOccurrences(of: "；", with: "|")
            .replacingOccurrences(of: ";", with: "|")
            .replacingOccurrences(of: "然后", with: "|")
            .replacingOccurrences(of: "还有", with: "|")
            .replacingOccurrences(of: "以及", with: "|")
            .replacingOccurrences(of: "再", with: "|")
        let segments = normalized
            .components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var drafts: [Draft] = []
        var seen = Set<String>()
        for segment in segments {
            guard let draft = parse(segment) else { continue }
            if seen.contains(draft.note) { continue }
            seen.insert(draft.note)
            drafts.append(draft)
        }
        return drafts
    }

    // MARK: - 金额

    private static func extractAmount(from text: String) -> Double? {
        // 1) ¥/￥ 前缀数字
        if let match = firstCapture(#"[¥￥]\s*(\d+(?:\.\d+)?)"#, in: text),
           let amount = Double(match), amount > 0 {
            return amount
        }

        // 2) 数字 + 单位（长单位优先）
        if let match = firstCapture(#"(\d+(?:\.\d+)?)\s*(?:块钱|元|块)"#, in: text),
           let amount = Double(match), amount > 0 {
            return amount
        }

        // 3) 中文数字 + 单位
        if let match = firstCapture(#"([零一二两三四五六七八九十百千]+)\s*(?:块钱|元|块)"#, in: text),
           let amount = chineseNumber(match) {
            return amount
        }

        // 4) 花钱动词后裸数字（长动词优先；「交」与数字间允许少量文字，如「交房租2000」；
        //    间隔上限 4 字符避免把「买奶茶，电话138000」里的电话号码当金额）
        if let match = firstCapture(#"(?:花了|付了|交了|买了|付款|消费|支付|花费|支出|用了|交|花|买)[^0-9]{0,4}(\d+(?:\.\d+)?)"#, in: text),
           let amount = Double(match), amount > 0 {
            return amount
        }

        // 5) 收入词 + 阿拉伯裸数字（只有句子里有收入词才接受裸数字）
        if incomeKeywords.contains(where: { text.contains($0) }),
           let match = firstCapture(#"(\d+(?:\.\d+)?)"#, in: text),
           let amount = Double(match), amount > 0 {
            return amount
        }

        // 6) 收入词 + 中文裸数字（如「工资八千五」→ 8500）
        if incomeKeywords.contains(where: { text.contains($0) }),
           let match = firstCapture(#"([零一二两三四五六七八九十百千]+)"#, in: text),
           let amount = chineseNumber(match) {
            return amount
        }

        return nil
    }

    /// 中文数字 → 金额（支持到 9999 的组合）。
    /// 末尾省略单位的数字按「上一位单位 ÷ 10」进位：
    /// 十五=15、二十三=23、二百三=230、八千五=8500、八百=800。
    private static func chineseNumber(_ text: String) -> Double? {
        let digits: [Character: Double] = [
            "零": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4,
            "五": 5, "六": 6, "七": 7, "八": 8, "九": 9
        ]
        let units: [Character: Double] = ["十": 10, "百": 100, "千": 1000]

        var total: Double = 0
        var current: Double = 0
        var lastUnit: Double = 0
        for character in text {
            if let digit = digits[character] {
                current = digit
            } else if let unit = units[character] {
                if current == 0 { current = 1 } // 「十五」「一百二」里的省略写法
                total += current * unit
                lastUnit = unit
                current = 0
            } else {
                return nil
            }
        }
        if current > 0 {
            let scale = lastUnit > 0 ? lastUnit / 10 : 1
            total += current * scale
        }
        return total > 0 ? total : nil
    }

    // MARK: - 类别

    private static func category(from text: String) -> ExpenseCategory {
        for (category, keywords) in categoryRules {
            if keywords.contains(where: { text.contains($0) }) {
                return category
            }
        }
        return .other
    }

    /// 类别规则：数组顺序即优先级（医疗 > 居住 > 交通 > 娱乐 > 餐饮 > 购物），
    /// 每组内长词在前，避免「买咖啡」被「买」误判购物、「买药」被「买」误判购物。
    private static let categoryRules: [(ExpenseCategory, [String])] = [
        (.medical, ["医院", "看病", "挂号", "检查", "诊所", "药"]),
        (.housing, ["房租", "房贷", "租房", "水电", "水费", "电费", "燃气", "物业"]),
        (.transport, ["打车", "出租车", "滴滴", "车费", "地铁", "公交", "加油", "油费", "停车", "高铁", "火车", "机票"]),
        (.entertainment, ["电影", "游戏", "娱乐", "KTV", "唱歌", "门票", "演唱会", "充值", "健身", "会员"]),
        (.food, ["吃饭", "早餐", "午餐", "晚餐", "午饭", "晚饭", "宵夜", "夜宵", "咖啡", "奶茶", "外卖", "点餐", "餐厅", "火锅", "烧烤", "零食", "水果", "买菜", "吃"]),
        (.shopping, ["买衣服", "衣服", "买鞋", "鞋", "购物", "包包", "化妆品", "超市", "商场", "网购", "淘宝", "京东", "买"])
    ]

    // MARK: - 收入词

    /// 强收入词：单独出现即判收入
    private static let incomeKeywords = [
        "??", "??", "??", "??", "??", "??", "??", "??", "??", "??", "??"
    ]
    /// 弱收入词：需排除支付场景后才判收入（如收款/红包）
    private static let incomeAmbiguousKeywords = ["收款", "红包"]
    /// 支付场景词：支付截图常见（收款方/付款/支付/转账），优先判支出
    private static let paymentSceneKeywords = ["收款方", "付款", "支付", "转账"]

    /// 收入/支出判定（抗支付截图误判）：
    /// “收款方”等支付场景词出现时只有强收入词才判收入；红包排除“发红包”。
    static func classifyIncome(text: String) -> Bool {
        let hasStrong = incomeKeywords.contains { text.contains($0) }
        let hasPaymentScene = paymentSceneKeywords.contains { text.contains($0) }
        if hasPaymentScene {
            return hasStrong
        }
        if hasStrong { return true }
        guard incomeAmbiguousKeywords.contains(where: { text.contains($0) }) else { return false }
        // 弱词有明确支出语义时判支出
        if text.contains("发红包") || text.contains("发了个红包") { return false }
        return true
    }

    // MARK: - 文本辅助

    /// 首个捕获组；无匹配返回 nil。
    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsText = text as NSString
        guard let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: nsText.length)) else {
            return nil
        }
        guard match.numberOfRanges > 1, match.range(at: 1).location != NSNotFound else { return nil }
        return nsText.substring(with: match.range(at: 1))
    }
}
