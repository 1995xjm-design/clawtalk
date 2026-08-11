//
//  ClawTalkKeyboardInputViewController.swift
//  ClawTalkKeyboard
//
//  咕噜（GuruIM）极简搬运：键盘扩展入口，继承 Hamster 键盘控制器。
//

import HamsterKeyboardKit
import UIKit

public class ClawTalkKeyboardInputViewController: KeyboardInputViewController {
  /// 极简简体拼音九宫格：默认使用 chineseNineGrid 布局
  public override func viewDidLoad() {
    super.viewDidLoad()
    setKeyboardType(.chineseNineGrid)
  }
}
