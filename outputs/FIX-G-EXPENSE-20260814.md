# FIX-G 记账报表（子智能体 G 批次 2026-08-14）

## 任务（断点线 G）
1. 拍照记账：拍照/选图 → 本机 OCR 识别金额+类别+备注，识别不完整手动补齐
2. 记账补照片：每笔记账可附带照片（文件落盘+列表缩略图+点开大图）
3. 专业 xlsx 导出：本月/全部账目导出 Excel（xlsx），文件可分享

## 改动清单（白名单 5 文件 + 2 新文件）
1. ClawTalk/Features/Expense/ExpenseEntry.swift —— 数据模型加 photoFileName（Codable 兼容旧数据，缺省 nil）
2. ClawTalk/Features/Expense/ExpenseStore.swift —— add() 支持 photoFileName；delete() 联动删照片；新增照片存储助手（savePhoto/deletePhoto/photoURL）+ ExpensePhotoStore（Application Support/ClawTalk/ExpensePhotos/，复用 ParkingPhotoStore 模式）
3. ClawTalk/Features/Expense/ExpenseListView.swift ——
   - 「拍照记账」按钮（相机/相册 confirmationDialog）+「导出 Excel」按钮（本月/全部范围）
   - 相机（UIImagePickerController 封装）+ 相册（PhotosPicker）→ VisionOCRService 本机 OCR → ExpenseOCRTextParser 解析（先语音规则，再收据小票合计/总额/末尾独立金额行）；解析不出如实弹手动补齐（照片自动带上，不假装识别成功）
   - 手动填写表单新增「照片」区（添加/移除）；保存时照片落盘
   - 列表行显示缩略图，点开大图（ExpensePhotoViewer）
   - 导出 Excel：ExpenseXLSXExporter 生成后 ShareLink 分享
   - 确认 alert 附「已附带照片」提示；空状态文案补「拍照记账」入口
   - 保留并行代理（线 F）的底部录音区与空状态文案，未删除任何既有功能
4. ClawTalk/Features/Expense/ExpenseCameraPicker.swift（新）—— 相机封装 + ExpenseOCRTextParser（收据金额/类别解析）
5. ClawTalk/Features/Expense/ExpenseXLSXExporter.swift（新）—— OOXML xlsx 生成器（记账明细+类别汇总两表、表头加粗/合计底色、列宽、XML 转义）+ 极简 ZIP 写入器（STORE+CRC32，不依赖第三方库）

## 自查结果
- 5 文件均为 UTF-8 无 BOM、FFFD 计数 = 0、括号配对 OK（含注释/字符串/多行字符串的严格检查）
- xlsx 导出算法已用等价实现验证：zipfile.testzip 通过、全部 XML 部件可解析、Content_Types/工作簿 rels/表名引用一致、特殊字符转义正确（样本：outputs/G-xlsx-sample.xlsx）
- OCR 收据解析 11 组用例全过（合计/总额/应付/末尾独立金额/¥ 前缀/无金额诚实返回 nil）
- git status：Expense 目录仅上述 5 文件（3 改 2 新）；仓库内其余已修改文件为并行子代理（线 F/H 等）改动，未触碰
- Windows 无 Xcode，未本地编译；改动按 Swift 5.10 / iOS 17 API 静态核对，编译由 CI 验证
- 并行代理（线 F 语音页统一）曾与本批次同时编辑 ExpenseListView.swift，本批次已在最终文件上保留其底部录音区改动并重新验证

## SHA256
- ClawTalk\Features\Expense\ExpenseEntry.swift  SHA256: 3275c9e8f4b852859e31ba79208622eaa549148b6506474fd348a9d5de38a38b
- ClawTalk\Features\Expense\ExpenseStore.swift  SHA256: 427e7d5d5dd559f4156bb29adc396af22629aeb64bdaf909f9ef940446d310a2
- ClawTalk\Features\Expense\ExpenseListView.swift  SHA256: 55c10fab20a52b529ae47e1ec6699b84bf0a5a2438728ccb553069215136449f
- ClawTalk\Features\Expense\ExpenseCameraPicker.swift  SHA256: 7585439c233241b020f11881799b9d808ea40932f504f5e6dd73c170c62e005d
- ClawTalk\Features\Expense\ExpenseXLSXExporter.swift  SHA256: 33857573141672cc3aae269d71d596a4041b72b46a2234ee366e67edb8f8f328

## 风险
- 照片以 JPEG 落盘在 Application Support，删除账目会联动删照片；用户手动删 App 数据会一并消失（本地存储特性）
- OCR 只识别金额/类别关键词，识别不完整一律弹手动补齐（诚实，不做假解析）；无相机设备自动回退相册
- xlsx 为 STORE（不压缩）打包，文件稍大但 Excel/WPS/Numbers 均可打开；未在真机 Excel 实测
- 与并行子代理改动同仓共存，需 CI 整包编译 + 真机回归（拍照 OCR、照片附注、Excel 分享打开）后交付