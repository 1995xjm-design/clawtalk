import Foundation
import UIKit
import Vision

/// 本地 OCR 服务：识别聊天截图文字（不联网、不花 token）
public class VisionOCRService {
  public static let shared = VisionOCRService()

  public enum OCRError: Error {
    case invalidImage
  }

  public func recognizeText(in image: UIImage, completion: @escaping (Result<String, Error>) -> Void) {
    guard let cgImage = image.cgImage else {
      ClawLog.record(module: "键盘OCR", "OCR 识别失败：图像无效")
      completion(.failure(OCRError.invalidImage))
      return
    }
    let request = VNRecognizeTextRequest { request, error in
      if let error {
        ClawLog.record(module: "键盘OCR", "OCR 识别失败：\(error.localizedDescription)")
        DispatchQueue.main.async { completion(.failure(error)) }
        return
      }
      let lines = (request.results as? [VNRecognizedTextObservation])?.compactMap { $0.topCandidates(1).first?.string } ?? []
      let text = lines.joined(separator: "\n")
      DispatchQueue.main.async { completion(.success(text)) }
    }
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["zh-Hans", "en-US"]
    request.usesLanguageCorrection = true

    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        try handler.perform([request])
      } catch {
        ClawLog.record(module: "键盘OCR", "OCR 识别失败：\(error.localizedDescription)")
        DispatchQueue.main.async { completion(.failure(error)) }
      }
    }
  }
}