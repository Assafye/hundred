import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
  private var contentHandler: ((UNNotificationContent) -> Void)?
  private var bestAttemptContent: UNMutableNotificationContent?

  override func didReceive(
    _ request: UNNotificationRequest,
    withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
  ) {
    self.contentHandler = contentHandler

    guard let bestAttemptContent = request.content.mutableCopy() as? UNMutableNotificationContent else {
      contentHandler(request.content)
      return
    }

    self.bestAttemptContent = bestAttemptContent

    guard let imageUrl = notificationImageUrl(from: bestAttemptContent.userInfo) else {
      contentHandler(bestAttemptContent)
      return
    }

    downloadAttachment(from: imageUrl) { attachment in
      if let attachment {
        bestAttemptContent.attachments = [attachment]
      }
      contentHandler(bestAttemptContent)
    }
  }

  override func serviceExtensionTimeWillExpire() {
    if let contentHandler, let bestAttemptContent {
      contentHandler(bestAttemptContent)
    }
  }

  private func notificationImageUrl(from userInfo: [AnyHashable: Any]) -> URL? {
    let candidates = [
      userInfo["notificationImageUrl"],
      userInfo["postImageUrl"],
      userInfo["chatAvatarUrl"],
      userInfo["groupImageUrl"],
      userInfo["actorAvatarUrl"],
      (userInfo["fcm_options"] as? [String: Any])?["image"],
      (userInfo["fcm_options"] as? [String: Any])?["imageUrl"],
    ]

    for candidate in candidates {
      guard let value = candidate as? String else { continue }
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, let url = URL(string: trimmed) else { continue }
      if url.scheme == "https" || url.scheme == "http" {
        return url
      }
    }

    return nil
  }

  private func downloadAttachment(
    from url: URL,
    completion: @escaping (UNNotificationAttachment?) -> Void
  ) {
    let task = URLSession.shared.downloadTask(with: url) { temporaryUrl, response, _ in
      guard
        let temporaryUrl,
        let response = response as? HTTPURLResponse,
        (200...299).contains(response.statusCode)
      else {
        completion(nil)
        return
      }

      let fileExtension = self.fileExtension(for: response, fallbackUrl: url)
      let localUrl = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension(fileExtension)

      do {
        try FileManager.default.moveItem(at: temporaryUrl, to: localUrl)
        let attachment = try UNNotificationAttachment(
          identifier: "notification-media",
          url: localUrl,
          options: nil
        )
        completion(attachment)
      } catch {
        completion(nil)
      }
    }

    task.resume()
  }

  private func fileExtension(for response: HTTPURLResponse, fallbackUrl: URL) -> String {
    if let mimeType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() {
      if mimeType.contains("png") { return "png" }
      if mimeType.contains("gif") { return "gif" }
      if mimeType.contains("webp") { return "webp" }
      if mimeType.contains("jpeg") || mimeType.contains("jpg") { return "jpg" }
    }

    let pathExtension = fallbackUrl.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
    return pathExtension.isEmpty ? "jpg" : pathExtension
  }
}
