import HamsterUIKit
import SwiftUI
import UIKit

class ClawTalkViewController: NibLessViewController {
  private let viewModel = ClawTalkViewModel()

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "Now ClawTalk"

    let hostingController = UIHostingController(rootView: ClawTalkRootView(viewModel: self.viewModel))
    addChild(hostingController)
    view.addSubview(hostingController.view)
    hostingController.view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
      hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
    ])
    hostingController.didMove(toParent: self)
  }
}
