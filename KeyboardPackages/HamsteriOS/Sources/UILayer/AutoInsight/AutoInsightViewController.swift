import HamsterUIKit
import SwiftUI
import UIKit

public class AutoInsightViewController: NibLessViewController {
  public override init() {
    super.init(nibName: nil, bundle: nil)
  }
  public override func loadView() {
    view = UIView()
    title = "每日洞察"
  }

  public override func viewDidLoad() {
    super.viewDidLoad()
    let host = UIHostingController(rootView: AutoInsightRootView())
    addChild(host)
    host.view.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(host.view)
    NSLayoutConstraint.activate([
      host.view.topAnchor.constraint(equalTo: view.topAnchor),
      host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
    ])
    host.didMove(toParent: self)
  }
}
