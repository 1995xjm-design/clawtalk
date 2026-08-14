# FIX-V049M：IOS原生布局修订线（v049m 批次）

日期：2026-08-14
批次：v049m「IOS原生布局修订线」
工作目录：fusion/ClawTalk（Git 工作区，未提交未推送）

## 一、任务背景
v049l 已实现键盘「IOS原生」布局（双层候选栏/5 页）。明哥提供官方完整文档，
本次以文档为准修订：业务部分（中文 9 键主页双层候选栏 + AI帮你回/超会说/眼睛 3 业务按钮）
只保留在中文主页汉字候选行；其余页面 100% 按文档对齐 iOS 原生。

## 二、修订清单（11 项）与实现

1. 配色表（ClawTalkIOSNativePalette.swift 重写，深浅两套）
   - 浅色：底盘 #D1D1D1 / 普通键 #FFFFFF / 功能键 #B0B0B0 / 发送 #007AFF /
     按下普通 #949494 / 按下功能 #767676 / 按下发送 #0058CC / 文字 #000000 / 候选栏 #E8E8E8
   - 深色：底盘 #1C1C1E / 普通键 #3A3A3C / 功能键 #48484A / 发送 #007AFF /
     按下普通 #636366 / 按下功能 #545456 / 按下发送 #0058CC / 文字 #FFFFFF / 候选栏 #2C2C2E
   - 业务按钮（AI/超会说/眼睛）在候选行保留品牌色（ClawPanelPalette 不动）。
2. 布局常量：键盘总宽 375 / 按键区高 216 / 候选栏高 44 / 圆角 8 / gap 6 / padding 8 / 行高 46。
3. 中文 9 键主页第 4 行：😀 58×46 | 选拼音 58×46 | 空格 163×46（大空格）+ 发送/换行；
   去掉「选定」与右侧通高确认竖块（verticalSpan 移除）。
4. 英文页改 QWERTY 全键盘（ClawEnglishKeyboard 替换 EnglishT9Keyboard）：
   行1 10 键等分（30.5 目标）/ 行2 9 键等分（34.5 目标）/ 行3 SHIFT 52 + 字母等分 + 删除 52 /
   行4 123 52 | 😀 52 | 空格弹性 | send 52；SHIFT 切换大小写（.alphabetic(.uppercased/.lowercased)）。
5. 子面板补齐：
   - 数字页「更多」→ 数字更多（NumericMoreSymbolsKeyboard，123 返回数字）
   - 中文符号页「#+=」→ 中文符号更多（ClassifySymbolicMoreKeyboard，123 返回中文符号）
   - 英文数字页（EnglishNumericKeyboard，ABC 回英文小写，#+= 进英文符号更多）
   - 英文符号更多页（EnglishSymbolsMoreKeyboard，123 回英文数字，ABC 回英文小写）
   - 「更多/123」返回上一级子面板（不直接回主键盘）。
6. emoji 来源回退：KeyboardContext.clawEmojiPrevPanel 记录来源；EmojisKeyboard 底部新增
   TAB_BACK 按钮（按来源显示 ABC/123/更多/中），退出回来源面板；键盘收起清空来源。
7. 面板状态机：新增 ClawKeyboardPanel 枚举（9拼音/数字/数字更多/中文符号/中文符号更多/
   英文大写/英文小写/英文数字/英文符号更多/emoji）+ 文档映射表；切换由各页 actionRows 驱动。
8. 按压动画：无缩放，仅背景色渐变 0.12s（KeyboardButton + 业务按钮）；按下/抬起/移出取消/
   触摸打断（tryHandleCancel）均复位背景色；颜色按 keyType（普通/功能/发送）取配色表。
9. 输入框焦点：blur（键盘收起 viewWillDisappear）→ 重置按压 + 清 emoji 来源 + 面板回 9 键主页
   （clawResetPanelState）；focus → 保留上次面板；发送键由 keyboardReturnAction(for:)
   读 textDocumentProxy.returnKeyType 决定（发送蓝 / 换行灰），键盘不自行判断。
10. 候选栏：中文主页双层保留（拼音行 + 汉字行 + 3 业务按钮）；其他页面单层；
    背景 #E8E8E8（浅）/#2C2C2E（深）；选中高亮 #007AFF。
11. 🌐🎤 全局控件：ClawBottomSystemBarView 高 44pt、图标 40×40，不属于任何面板，
    每次渲染都绘制，切换面板不销毁；深浅色跟随切换。

## 三、改动文件清单
修改（22）：ClawTalkIOSNativePalette / ClawNineGridLayoutEngine / KeyboardType /
  KeyboardType+Button / KeyboardContext / KeyboardContext+KeyboardType(未动) /
  StandardKeyboardAppearance / PrefersAutocompleteResolver / Models(Yaml) /
  KeyboardRootView / ChineseNineGridLayoutProvider / NumericNineGridKeyboardLayoutProvider /
  ChineseNineGridKeyboard / NumericNineGridKeyboard / ClassifySymbolicKeyboard /
  KeyboardButton / CandidateBarView / KeyboardToolbarView / PinyinCandidateRowView /
  ClawBottomSystemBarView / EmojisKeyboard / KeyboardInputViewController
删除（1）：EnglishT9Keyboard.swift
新增（6）：ClawKeyboardPanel / ClawEnglishKeyboard / NumericMoreSymbolsKeyboard /
  ClassifySymbolicMoreKeyboard / EnglishNumericKeyboard / EnglishSymbolsMoreKeyboard

## 四、自查结果
- 全部改动文件 UTF-8 无 BOM，FFFD=0（Models.swift 括号 262/261 为 HEAD 既有，非本次引入）。
- 花括号/方括号逐文件配对通过；色值 18 项与文档逐一核对通过。
- 状态机映射逐条核对通过（见上）。
- 按压动画无缩放（业务按钮 scaleX 已移除），0.12s。
- git status 只含本次改动文件（22 M + 1 D + 6 ??）。
- 无 Xcode：静态自查完成，编译由 CI 验证。

## 五、风险与注意
- 面板切换目前依赖 keyboardType 视图重建（与 v049l 一致）；SHIFT/大小写切换同样重建页面。
- 数字页与中文符号页之间无直接跳转（按文档各自从 9 键主页分支进入）。
- 文档行宽数值（30.5/34.5/58/163/52）为键帽目标宽，实际按等分/固定 pt 布局近似实现。
- EnglishT9 类型/动作 case 保留以兼容旧配置，但不再被主页使用。
- 深浅色切换依赖 layoutSubviews 刷新；CI 编译通过后建议真机验证一轮。