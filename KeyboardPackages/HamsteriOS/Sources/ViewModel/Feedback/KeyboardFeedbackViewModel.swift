//
//  KeyboardFeedbackViewModel.swift
//
//
//  Created by morse on 14/7/2023.
//

import Combine
import HamsterKeyboardKit
import HamsterKit
import HamsterUIKit
import OSLog
import UIKit

public class KeyboardFeedbackViewModel {
  // MARK: properties

  public var enableKeySounds: Bool {
    get {
      HamsterConfigurationStore.shared.configuration.keyboard?.enableKeySounds ?? false
    }
    set {
      HamsterConfigurationStore.shared.configuration.keyboard?.enableKeySounds = newValue
      HamsterConfigurationStore.shared.applicationConfiguration.keyboard?.enableKeySounds = newValue
    }
  }

  public var enableHapticFeedback: Bool {
    get {
      HamsterConfigurationStore.shared.configuration.keyboard?.enableHapticFeedback ?? false
    }
    set {
      HamsterConfigurationStore.shared.configuration.keyboard?.enableHapticFeedback = newValue
      HamsterConfigurationStore.shared.applicationConfiguration.keyboard?.enableHapticFeedback = newValue
    }
  }

  public let hapticFeedbackStateSubject = PassthroughSubject<Bool, Never>()
  public var hapticFeedbackStatePublished: AnyPublisher<Bool, Never> {
    hapticFeedbackStateSubject.eraseToAnyPublisher()
  }

  public var hapticFeedbackIntensity: Int {
    get {
      HamsterConfigurationStore.shared.configuration.keyboard?.hapticFeedbackIntensity ?? 2
    }
    set {
      HamsterConfigurationStore.shared.configuration.keyboard?.hapticFeedbackIntensity = newValue
      HamsterConfigurationStore.shared.applicationConfiguration.keyboard?.hapticFeedbackIntensity = newValue
    }
  }

  public let minimumHapticFeedbackIntensity: Int = 0

  public let maximumHapticFeedbackIntensity: Int = 4

  // MARK: methods

  init() {}

  @objc func changeHaptic(_ control: UIControl) {
    if let control = control as? StepSlider {
      Logger.statistics.debug("change haptic: \(control.index)")
      hapticFeedbackIntensity = Int(control.index)
    }
  }

  @objc func toggleAction(_ sender: UISwitch) {
    enableHapticFeedback = sender.isOn
    hapticFeedbackStateSubject.send(sender.isOn)
  }
}
