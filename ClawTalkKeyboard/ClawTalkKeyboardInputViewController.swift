//
//  ClawTalkKeyboardInputViewController.swift
//  ClawTalkKeyboard
//
//  咕噜（GuruIM）极简搬运：键盘扩展入口，继承 Hamster 键盘控制器。
//

import HamsterKeyboardKit
import UIKit

public class ClawTalkKeyboardInputViewController: KeyboardInputViewController {
  /// 极简简体拼音九宫格：默认使用「IOS原生」布局（v049m；配置里显式选其他类型时由运行时 subject 切换）
  public override func viewDidLoad() {
    super.viewDidLoad()
    setKeyboardType(.chineseNineGridIOS)
  }
}
