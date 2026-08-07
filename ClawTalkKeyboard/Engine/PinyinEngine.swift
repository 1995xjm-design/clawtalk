import Foundation

/// 拼音输入引擎 - 处理拼音到汉字的转换
class PinyinEngine {

    // MARK: - 属性

    /// 拼音到汉字的映射字典
    private var pinyinDict: [String: [String]] = [:]

    /// 是否已加载字典
    private var isLoaded: Bool = false

    // MARK: - 初始化

    init() {
        loadBasicDict()
    }

    // MARK: - 公共方法

    /// 根据拼音获取候选词列表
    func getCandidates(for pinyin: String) -> [String] {
        guard !pinyin.isEmpty else { return [] }

        let lowercased = pinyin.lowercased()
        var results: [String] = []

        // 精确匹配
        if let exact = pinyinDict[lowercased] {
            results.append(contentsOf: exact)
        }

        // 前缀匹配
        for (key, values) in pinyinDict {
            if key.hasPrefix(lowercased) && key != lowercased {
                results.append(contentsOf: values.prefix(3))
            }
        }

        return Array(results.prefix(9))
    }

    // MARK: - 私有方法

    /// 加载基础拼音字典
    private func loadBasicDict() {
        // 常用单字 A-D
        pinyinDict["a"] = ["啊", "阿", "呵"]
        pinyinDict["ai"] = ["爱", "哎", "唉", "矮"]
        pinyinDict["an"] = ["安", "按", "暗", "岸"]
        pinyinDict["ba"] = ["吧", "把", "爸", "八"]
        pinyinDict["bai"] = ["白", "百", "拜", "败"]
        pinyinDict["ban"] = ["半", "办", "班", "般"]
        pinyinDict["bei"] = ["被", "北", "背", "杯"]
        pinyinDict["bi"] = ["比", "笔", "必", "闭"]
        pinyinDict["bu"] = ["不", "步", "部", "布"]
        pinyinDict["da"] = ["大", "打", "达", "答"]
        pinyinDict["de"] = ["的", "得", "地", "德"]
        pinyinDict["dui"] = ["对", "队", "堆"]
        pinyinDict["duo"] = ["多", "朵", "躲"]

        // E-J
        pinyinDict["en"] = ["嗯", "恩"]
        pinyinDict["er"] = ["二", "耳", "而"]
        pinyinDict["ge"] = ["个", "哥", "歌"]
        pinyinDict["guo"] = ["过", "国", "果"]
        pinyinDict["hao"] = ["好", "号", "毫"]
        pinyinDict["he"] = ["和", "喝", "河"]
        pinyinDict["hen"] = ["很", "恨", "狠"]
        pinyinDict["hui"] = ["会", "回", "灰"]
        pinyinDict["ji"] = ["几", "机", "鸡"]
        pinyinDict["jiu"] = ["就", "九", "酒"]

        isLoaded = true
    }
}
