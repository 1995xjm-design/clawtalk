# FIX-K-NINEGRID-20260814 旧九宫格恢复 + 新旧分发分离

> 线 K 子智能体交付（2026-08-14）。未提交、未推送，编译待 CI。

## 根因
- v049l/m 新增「IOS原生」布局（`.chineseNineGridIOS`），但 `KeyboardRootView.chooseKeyboard` 把
  `.chineseNineGrid` / `.chineseNineGridIOS` 合并分发到同一个新样式视图；同时
  `isChineseNineGrid`/`isClawIOSNativeKeyboard` 让旧 `.chineseNineGrid` 也套用新样式
  （新布局引擎、写死配色、双层候选栏），导致用户旧 Hamster 原版中文九键「不见了」。
- 键盘扩展入口 `viewDidLoad` 无条件 `setKeyboardType(.chineseNineGridIOS)`，设置页即使选了
  「中文9键」也会被覆盖，旧九宫格无法独立生效。

## 改动清单（10 文件，全部 UTF-8 无 BOM、FFFD=0）
### 键盘包（HamsterKeyboardKit）
1. `Sources/View/StandarKeyboard/ChineseNineGridKeyboard.swift` — 恢复 de90be2 Hamster 原版九宫格视图
   （左侧 SymbolsVerticalView 符号列表 + 原版按键排布 + 原版候选栏 + UICollectionViewDelegate 符号上屏逻辑），
   仅一处偏差：init 固定使用 `LegacyChineseNineGridLayoutProvider()`（不再走 `StandardKeyboardLayoutProvider.chineseNineGridLayoutProvider`）。
2. `Sources/View/StandarKeyboard/ChineseNineGridIOSKeyboard.swift`（新文件）— v049l/m 新样式视图，
   类名 `ChineseNineGridKeyboard` → `ChineseNineGridIOSKeyboard`，内容零改动（ClawNineGridLayoutEngine / 双层候选 / 文档布局）。
3. `Sources/KeyboardKit/Layout/Providers/LegacyChineseNineGridLayoutProvider.swift`（新文件）— 旧按键排布：
   行1 @/. ABC DEF 删除｜行2 GHI JKL MNO 重输｜行3 PQRS TUV WXYZ 回车(跨行)｜行4 符号 数字 空格 中/英。
4. `Sources/View/KeyboardRootView.swift` — `chooseKeyboard` 分发分离：
   `case .chineseNineGrid:` → `legacyChineseNineGridKeyboardView`（旧视图）；
   `case .chineseNineGridIOS:` → `chineseNineGridKeyboardView`（原属性保留给 IOS原生，指向新类）。
5. `Sources/View/CandidateBarView.swift` — 候选栏三态：`.chineseNineGridIOS` 双层（拼音行+汉字行，不变）；
   `.chineseNineGrid` 旧版单层（顶部 T9 拼音 Label + 单行候选）；其余页面单层（不变）。
   旧九宫格候选栏背景/文字样式保留主题跟随（不套 IOS原生 写死配色）。
6. `Sources/View/KeyboardToolbarView.swift` — 输入变化时给旧九宫格候选栏拼音 Label 填 `t9UserInputKey`；
   旧九宫格工具栏背景跟随主题。
7. `Sources/View/ClawTalkIOSNativePalette.swift` — `clawCandidateBarHeight` 分流：
   `.chineseNineGridIOS`=88pt 双层 / `.chineseNineGrid`=原版工具栏高度（默认55）/ 其余 44pt；
   `isClawIOSNativeKeyboard` 移除 `.chineseNineGrid`（旧九宫格走主题外观，不套写死配色）。
8. `Sources/KeyboardKit/Keyboard/KeyboardContext.swift` — `clawResetPanelState` 回主页：
   主键盘为九宫格（新旧任一）时回 `selectKeyboard`（旧用户不再被强制弹回 IOS原生 9键主页）。

### 键盘扩展 / 配置（为「独立可选 + 默认 IOS原生」必需）
9. `ClawTalkKeyboard/ClawTalkKeyboardInputViewController.swift` — 去掉无条件强制 `chineseNineGridIOS`：
   配置已显式选择时尊重设置页选择；配置缺失（全新安装）回退 IOS原生，装完即生效。
10. `ClawTalk/Resources/SharedSupport/hamster.yaml` — `useKeyboardType: chineseNineGrid` → `chineseNineGridIOS`
    （设置页默认选中 IOS原生；键盘 `selectKeyboard` 默认值同步）。

### 文件 SHA256
- ChineseNineGridKeyboard.swift: EB884A8D86836E331545207B83E794A85CDA9245EA6744A4F9AC81FD59C69BDB
- ChineseNineGridIOSKeyboard.swift: FA9204511749B54B4E58FDE2C53A39C1CED15F9FF77D942E208EDD87FBC19168
- LegacyChineseNineGridLayoutProvider.swift: 00E7A5549862BABE8DA249E9C9AE8483BEF95DC6D88A3C256A21FDF3FAC0C6C3
- KeyboardRootView.swift: 322F925916CE50A822D68E691C171BA1C780C901E546BB2CB85B4EB0E9ACCDE9
- CandidateBarView.swift: 23BE482B48234CC0AA270AAD6B83A7AE432FB6E7170D78E0CBF96503F2E2751B
- KeyboardToolbarView.swift: BBA6A89FA241A07D21D2344259FDA3268848B520BC542C26BB9A60CD9AC23092
- ClawTalkIOSNativePalette.swift: 85041E8052D41AB167395AFE320257AFC9D01F91E0C183718F5012ACD58378AE
- KeyboardContext.swift: 9470FAD908BCAC0569518FFBA56700E8A2D7ABE736E11D21532AFE79112DA0B6
- ClawTalkKeyboardInputViewController.swift: 14397E5AA22355F12ACA8F449B3E0EF6DCEC08B1F14F602E354E52079A6BDD06
- hamster.yaml: 60FB63F3774DAD23E82A8516F711D037B9FAAB3E58F04A341CED678A4310E681

## 部署步骤（小强）
1. `git diff` 复核键盘包改动（工作区已就绪，未提交）。
2. 跑 CI 编译（Windows 无 Xcode，编译验证依赖 CI）。
3. 出包后安装验证：
   - 设置 → 键盘 → 键盘布局：默认勾选「IOS原生」；切「中文9键」后键盘重启即 Hamster 原版九宫格（左侧符号列表 + 3×3 字母键 + 原版候选栏）；
   - 「IOS原生」保持 v049m 文档布局（5 列首行 + 双层候选栏 + 底部系统栏）；
   - 旧九宫格打字：T9 拼音显示在候选栏顶部，候选单行滚动，左侧符号列表点击上屏。

## 自查结果
- 10 文件均 UTF-8 无 BOM、FFFD=0；括号/圆括号/方括号配对通过。
- 旧视图与 de90be2 对比：仅 init 布局提供器一处偏差（`git diff de90be2` 验证）。
- 旧 `.chineseNineGrid` 不引用新引擎（ClawNineGridLayoutEngine/ClawIOSNativePalette 均无引用）；
  新 `.chineseNineGridIOS` 不引用被恢复的旧组件（SymbolsVerticalView/LegacyChineseNineGridLayoutProvider 均无引用）。
- Rime 输入逻辑（`isChineseNineGrid` 编码转换、KeyboardInputViewController 977/997 行）未动，两类型打字共用。
- 键盘设置布局列表（KeyboardSettingsViewModel.keyboardLayoutList）已含 中文9键(chineseNineGrid)/IOS原生(chineseNineGridIOS)。

## 风险 / 待明哥确认
1. **旧用户行为变化**：已装 v049m 且从未改设置的用户，其 AppGroup 配置为 chineseNineGrid → 升级后回到旧九宫格
   （这正是「恢复旧九键」的目标）；如希望老用户也默认新样式，需在部署脚本/升级逻辑里改写 useKeyboardType。
2. **底部系统栏（🌐/🎤，44pt）为全键盘共用 Chrome**：旧九宫格主页也显示（de90be2 原版无此栏），
   为避免动态约束切换抖动未隐藏；如需完全原版渲染可后续迭代处理。
3. **旧九宫格的子页面**（数字九宫格/符号页/英文页）仍为 v049m 新样式（共享页面，不在本次恢复范围），
   旧九宫格用户的 ABC 键 → 标准 26 键（走 `isClawIOSNativeMode=false` 分支），数字/符号页为新样式。
4. **旧九宫格模式下无 AI/超会说/眼睛业务按钮**（业务按钮内嵌于新双层候选栏汉字行，旧单层候选栏不注入）。
5. 未本地编译（Windows 无 Xcode），依赖 CI 编译验证；如有编译错误请回传。