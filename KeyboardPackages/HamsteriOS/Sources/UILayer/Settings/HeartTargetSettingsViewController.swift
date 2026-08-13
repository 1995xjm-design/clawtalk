import HamsterKit
import PhotosUI
import UIKit

/// 聊天对象档案列表页（设置 → 聊天对象档案）
public final class HeartTargetSettingsViewController: UITableViewController {
  private let service = HeartTargetService.shared

  public init() {
    super.init(style: .insetGrouped)
    title = "聊天对象档案"
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  public override func viewDidLoad() {
    super.viewDidLoad()
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
    navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(addTapped))
    NotificationCenter.default.addObserver(self, selector: #selector(profilesChanged), name: .heartTargetProfilesDidChange, object: nil)
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  @objc private func profilesChanged() {
    tableView.reloadData()
  }

  @objc private func addTapped() {
    let edit = HeartTargetEditViewController(profile: nil)
    navigationController?.pushViewController(edit, animated: true)
  }

  public override func numberOfSections(in tableView: UITableView) -> Int { 1 }

  public override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    let count = service.profiles.count
    return count == 0 ? 1 : count
  }

  public override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
    if service.profiles.isEmpty {
      cell.textLabel?.text = "暂无档案，点击右上角 + 添加"
      cell.textLabel?.textColor = .secondaryLabel
      cell.accessoryType = .none
      cell.imageView?.image = nil
      return cell
    }
    let profile = service.profiles[indexPath.row]
    cell.textLabel?.text = profile.displayName
    cell.textLabel?.textColor = .label
    cell.detailTextLabel?.text = profile.bio.isEmpty ? "未填写描述" : profile.bio
    if let image = profile.avatarImage {
      cell.imageView?.image = image
      cell.imageView?.layer.cornerRadius = 16
      cell.imageView?.layer.masksToBounds = true
    } else {
      cell.imageView?.image = UIImage(systemName: "person.crop.circle")
    }
    cell.accessoryType = .disclosureIndicator
    return cell
  }

  public override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    guard !service.profiles.isEmpty else { return }
    let profile = service.profiles[indexPath.row]
    let edit = HeartTargetEditViewController(profile: profile)
    navigationController?.pushViewController(edit, animated: true)
  }

  public override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
    guard editingStyle == .delete, !service.profiles.isEmpty else { return }
    let profile = service.profiles[indexPath.row]
    service.delete(id: profile.id)
    tableView.reloadData()
  }
}

/// 聊天对象档案编辑页（名称 + 描述 + 头像）
public final class HeartTargetEditViewController: UITableViewController, PHPickerViewControllerDelegate, UITextFieldDelegate, UITextViewDelegate {
  private let service = HeartTargetService.shared
  private let existing: HeartTargetProfile?
  private var avatarImage: UIImage?
  private var name = ""
  private var bio = ""

  private let nameField = UITextField()
  private let bioView = UITextView()
  private let avatarCellImageView = UIImageView()

  public init(profile: HeartTargetProfile?) {
    self.existing = profile
    super.init(style: .insetGrouped)
    title = profile == nil ? "新建档案" : "编辑档案"
    name = profile?.name ?? ""
    bio = profile?.bio ?? ""
    avatarImage = profile?.avatarImage
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  public override func viewDidLoad() {
    super.viewDidLoad()
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
    navigationItem.rightBarButtonItem = UIBarButtonItem(title: "保存", style: .done, target: self, action: #selector(saveTapped))
  }

  @objc private func saveTapped() {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty else {
      let alert = UIAlertController(title: "请填写姓名", message: nil, preferredStyle: .alert)
      alert.addAction(UIAlertAction(title: "好", style: .default))
      present(alert, animated: true)
      return
    }
    var profile = existing ?? HeartTargetProfile()
    profile.name = trimmedName
    profile.bio = bio.trimmingCharacters(in: .whitespacesAndNewlines)
    profile.avatarData = avatarImage?.jpegData(compressionQuality: 0.8)
    service.upsert(profile)
    navigationController?.popViewController(animated: true)
  }

  @objc private func deleteTapped() {
    guard let existing else { return }
    service.delete(id: existing.id)
    navigationController?.popViewController(animated: true)
  }

  @objc private func pickAvatar() {
    var config = PHPickerConfiguration()
    config.filter = .images
    config.selectionLimit = 1
    let picker = PHPickerViewController(configuration: config)
    picker.delegate = self
    present(picker, animated: true)
  }

  public func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true)
    guard let provider = results.first?.itemProvider, provider.canLoadObject(ofClass: UIImage.self) else { return }
    provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
      DispatchQueue.main.async {
        guard let self, let image = object as? UIImage else { return }
        self.avatarImage = image
        self.avatarCellImageView.image = image
        self.tableView.reloadRows(at: [IndexPath(row: 0, section: 0)], with: .none)
      }
    }
  }

  // MARK: - Table

  public override func numberOfSections(in tableView: UITableView) -> Int {
    existing == nil ? 2 : 3
  }

  public override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    section == 1 ? 2 : 1
  }

  public override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
    switch section {
    case 0: return "头像"
    case 1: return "信息（名称与描述会作为 AI 聊天对象背景）"
    default: return nil
    }
  }

  public override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
    cell.textLabel?.text = nil
    cell.accessoryType = .none
    cell.selectionStyle = .default

    switch indexPath.section {
    case 0:
      avatarCellImageView.translatesAutoresizingMaskIntoConstraints = false
      avatarCellImageView.image = avatarImage ?? UIImage(systemName: "person.crop.circle.fill")
      avatarCellImageView.contentMode = .scaleAspectFill
      avatarCellImageView.layer.cornerRadius = 24
      avatarCellImageView.layer.masksToBounds = true
      cell.contentView.addSubview(avatarCellImageView)
      avatarCellImageView.centerXAnchor.constraint(equalTo: cell.contentView.centerXAnchor).isActive = true
      avatarCellImageView.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 12).isActive = true
      avatarCellImageView.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -12).isActive = true
      avatarCellImageView.widthAnchor.constraint(equalToConstant: 48).isActive = true
      avatarCellImageView.heightAnchor.constraint(equalToConstant: 48).isActive = true
      cell.textLabel?.text = avatarImage == nil ? "选择头像" : "更换头像"
      cell.textLabel?.textColor = .systemBlue
      return cell
    case 1:
      if indexPath.row == 0 {
        nameField.text = name
        nameField.placeholder = "姓名"
        nameField.delegate = self
        nameField.frame = CGRect(x: 20, y: 7, width: cell.contentView.bounds.width - 40, height: 30)
        nameField.autoresizingMask = [.flexibleWidth]
        cell.contentView.addSubview(nameField)
      } else {
        bioView.text = bio
        bioView.font = .systemFont(ofSize: 15)
        bioView.delegate = self
        bioView.backgroundColor = .clear
        bioView.frame = CGRect(x: 12, y: 6, width: cell.contentView.bounds.width - 24, height: 84)
        bioView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cell.contentView.addSubview(bioView)
      }
      return cell
    default:
      let delete = UIButton(type: .system)
      delete.setTitle("删除档案", for: .normal)
      delete.setTitleColor(.systemRed, for: .normal)
      delete.frame = CGRect(x: 0, y: 0, width: cell.contentView.bounds.width, height: 44)
      delete.autoresizingMask = [.flexibleWidth]
      delete.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)
      cell.contentView.addSubview(delete)
      return cell
    }
  }

  public override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
    if indexPath.section == 0 { return 80 }
    if indexPath.section == 1 { return indexPath.row == 0 ? 50 : 100 }
    return 44
  }

  public override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    if indexPath.section == 0 {
      pickAvatar()
    }
  }

  public func textFieldDidChangeSelection(_ textField: UITextField) {
    name = textField.text ?? ""
  }

  public func textViewDidChange(_ textView: UITextView) {
    bio = textView.text
  }
}