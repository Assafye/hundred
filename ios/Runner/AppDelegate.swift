import Firebase
import FirebaseAuth
import FirebaseMessaging
import Flutter
import UIKit
import UserNotifications

@UIApplicationMain
@objc class AppDelegate: FlutterAppDelegate, MessagingDelegate {
  private static var hasApnsToken = false
  private static var pendingApnsResults: [UUID: FlutterResult] = [:]
  private static let apnsChannelName = "com.hundred.hundred/apns_status"
  private static let phoneAuthChannelName = "com.hundred.hundred/phone_auth_diagnostics"

  private static let sensitiveErrorKeys = [
    "appcredential", "credential", "phone", "phonenumber", "receipt", "secret", "token",
  ]

  private static func normalizedErrorKey(_ key: String) -> String {
    key.lowercased().filter { $0.isLetter }
  }

  private static func sanitizeErrorText(_ value: String) -> String {
    var sanitized = value
    let patterns = [#"\+?\d{8,15}"#, #"[A-Za-z0-9_\-./+=]{40,}"#]
    for pattern in patterns {
      guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
      let range = NSRange(sanitized.startIndex..<sanitized.endIndex, in: sanitized)
      sanitized = regex.stringByReplacingMatches(
        in: sanitized,
        range: range,
        withTemplate: "<redacted>"
      )
    }
    return sanitized
  }

  private static func sanitizeErrorValue(_ value: Any, key: String? = nil) -> Any {
    if let key,
      sensitiveErrorKeys.contains(where: { normalizedErrorKey(key).contains($0) })
    {
      return "<redacted>"
    }
    if let dictionary = value as? [String: Any] {
      var sanitized: [String: Any] = [:]
      for (nestedKey, nestedValue) in dictionary {
        sanitized[nestedKey] = sanitizeErrorValue(nestedValue, key: nestedKey)
      }
      return sanitized
    }
    if let dictionary = value as? [AnyHashable: Any] {
      var sanitized: [String: Any] = [:]
      for (nestedKey, nestedValue) in dictionary {
        let keyString = String(describing: nestedKey)
        sanitized[keyString] = sanitizeErrorValue(nestedValue, key: keyString)
      }
      return sanitized
    }
    if let values = value as? [Any] {
      return values.map { sanitizeErrorValue($0) }
    }
    if let text = value as? String {
      return sanitizeErrorText(text)
    }
    if value is NSNull || value is NSNumber {
      return value
    }
    return sanitizeErrorText(String(describing: value))
  }

  private static func diagnosticDetails(for error: NSError, depth: Int = 0) -> [String: Any] {
    var details: [String: Any] = [
      "nativeDomain": error.domain,
      "nativeCode": error.code,
      "localizedDescription": sanitizeErrorText(error.localizedDescription),
      "userInfoKeys": error.userInfo.keys.map { String(describing: $0) }.sorted(),
    ]
    if let authErrorName = error.userInfo[AuthErrorUserInfoNameKey] as? String {
      details["authErrorName"] = authErrorName
    }
    if let failureReason = error.userInfo[NSLocalizedFailureReasonErrorKey] as? String {
      details["failureReason"] = sanitizeErrorText(failureReason)
    }
    if let recoverySuggestion = error.userInfo[NSLocalizedRecoverySuggestionErrorKey] as? String {
      details["recoverySuggestion"] = sanitizeErrorText(recoverySuggestion)
    }
    if let deserializedResponse =
      error.userInfo["FIRAuthErrorUserInfoDeserializedResponseKey"]
    {
      details["backendResponse"] = sanitizeErrorValue(deserializedResponse)
    }
    if depth < 4,
      let underlyingError = error.userInfo[NSUnderlyingErrorKey] as? NSError
    {
      details["underlyingError"] = diagnosticDetails(for: underlyingError, depth: depth + 1)
    }
    return details
  }

  private static func flutterErrorCode(for error: NSError) -> String {
    guard let authErrorName = error.userInfo[AuthErrorUserInfoNameKey] as? String else {
      return "internal-error"
    }
    return authErrorName
      .replacingOccurrences(of: "ERROR_", with: "")
      .replacingOccurrences(of: "_", with: "-")
      .lowercased()
  }

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    FirebaseApp.configure()
    Messaging.messaging().delegate = self

    if let controller = window?.rootViewController as? FlutterViewController {
      let apnsChannel = FlutterMethodChannel(
        name: AppDelegate.apnsChannelName,
        binaryMessenger: controller.binaryMessenger
      )
      apnsChannel.setMethodCallHandler { call, result in
        switch call.method {
        case "isApnsTokenReady":
          result(AppDelegate.hasApnsToken)
        case "waitForApnsToken":
          if AppDelegate.hasApnsToken {
            result(true)
            return
          }
          let timeoutMs = (call.arguments as? [String: Any])?["timeoutMs"] as? Int ?? 2500
          let waiterId = UUID()
          AppDelegate.pendingApnsResults[waiterId] = result
          DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(timeoutMs)) {
            if let pending = AppDelegate.pendingApnsResults.removeValue(forKey: waiterId) {
              pending(false)
            }
          }
        default:
          result(FlutterMethodNotImplemented)
        }
      }

      let phoneAuthChannel = FlutterMethodChannel(
        name: AppDelegate.phoneAuthChannelName,
        binaryMessenger: controller.binaryMessenger
      )
      phoneAuthChannel.setMethodCallHandler { call, result in
        guard call.method == "verifyPhoneNumber" else {
          result(FlutterMethodNotImplemented)
          return
        }
        guard let arguments = call.arguments as? [String: Any],
          let phoneNumber = arguments["phoneNumber"] as? String,
          !phoneNumber.isEmpty,
          let attemptId = arguments["attemptId"] as? String,
          !attemptId.isEmpty
        else {
          result(FlutterError(
            code: "invalid-arguments",
            message: "Phone number and attempt ID are required.",
            details: nil
          ))
          return
        }

        print("PHONE_AUTH_NATIVE_START | attemptId=\(attemptId)")
        PhoneAuthProvider.provider(auth: Auth.auth()).verifyPhoneNumber(
          phoneNumber,
          uiDelegate: nil
        ) { verificationId, error in
          if let error = error as NSError? {
            var details = AppDelegate.diagnosticDetails(for: error)
            details["attemptId"] = attemptId
            print("PHONE_AUTH_NATIVE_FAILED | attemptId=\(attemptId) | details=\(details)")
            result(FlutterError(
              code: AppDelegate.flutterErrorCode(for: error),
              message: AppDelegate.sanitizeErrorText(error.localizedDescription),
              details: details
            ))
            return
          }
          guard let verificationId, !verificationId.isEmpty else {
            result(FlutterError(
              code: "missing-verification-id",
              message: "Phone verification returned no verification ID.",
              details: ["attemptId": attemptId]
            ))
            return
          }
          print("PHONE_AUTH_NATIVE_CODE_SENT | attemptId=\(attemptId)")
          result(["verificationId": verificationId])
        }
      }
    }

    if #available(iOS 10.0, *) {
      UNUserNotificationCenter.current().delegate = self as? UNUserNotificationCenterDelegate
      let authOptions: UNAuthorizationOptions = [.alert, .badge, .sound]
      UNUserNotificationCenter.current().requestAuthorization(options: authOptions) { _, _ in }
    } else {
      let settings: UIUserNotificationSettings =
        UIUserNotificationSettings(types: [.alert, .badge, .sound], categories: nil)
      application.registerUserNotificationSettings(settings)
    }

    application.registerForRemoteNotifications()
    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
    // The Flutter Firebase Messaging plugin handles token sync and registration.
  }

  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    // App Delegate proxy is disabled in Info.plist, so Firebase Auth must
    // receive the APNs token explicitly for iOS phone verification.
    Auth.auth().setAPNSToken(deviceToken, type: .unknown)
    Messaging.messaging().apnsToken = deviceToken
    AppDelegate.hasApnsToken = true
    let waiters = AppDelegate.pendingApnsResults
    AppDelegate.pendingApnsResults.removeAll()
    for waiter in waiters.values {
      waiter(true)
    }
    super.application(
      application,
      didRegisterForRemoteNotificationsWithDeviceToken: deviceToken
    )
  }

  override func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    print("APNs registration failed: \(error.localizedDescription)")
    super.application(
      application,
      didFailToRegisterForRemoteNotificationsWithError: error
    )
  }

  override func application(
    _ application: UIApplication,
    didReceiveRemoteNotification userInfo: [AnyHashable: Any],
    fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
  ) {
    // Silent push used by phone verification must be consumed by Firebase Auth first.
    if Auth.auth().canHandleNotification(userInfo) {
      completionHandler(.noData)
      return
    }
    super.application(
      application,
      didReceiveRemoteNotification: userInfo,
      fetchCompletionHandler: completionHandler
    )
  }

  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    if Auth.auth().canHandle(url) {
      return true
    }
    return super.application(app, open: url, options: options)
  }
}
