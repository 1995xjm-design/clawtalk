//
//  ClawTalkKeyboardInputViewController.swift
//  ClawTalkKeyboard
//
//  咕噜（GuruIM）极简搬运：键盘扩展入口，继承 Hamster 键盘控制器。
//

import HamsterKeyboardKit
import UIKit

public class ClawTalkKeyboardInputViewController: KeyboardInputViewController {
  /// 极简简体拼音九宫格：默认布局尊重设置页选择（中文9键 / IOS原生 独立可选）；
  /// 配置未显式选择时（全新安装未打开设置）回退「IOS原生」，装完即生效。
  public override func viewDidLoad() {
    super.viewDidLoad()
    if keyboardContext.hamsterConfiguration?.keyboard?.useKeyboardType == nil {
      setKeyboardType(.chineseNineGridIOS)
    }
  }
}
