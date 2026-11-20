import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let channel = FlutterMethodChannel(
      name: "split_together/bank_launcher",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      let value = call.arguments as? String ?? ""
      switch call.method {
      case "openApp":
        Self.open(Self.launchURL(for: value), result: result)
      case "openOfficialPage":
        Self.open(Self.storeURL(for: value), result: result)
      case "copyAccount":
        guard (6...20).contains(value.utf8.count),
              value.utf8.allSatisfy({ (48...57).contains($0) }) else {
          result(FlutterError(code: "invalid-account", message: "帳號格式不正確", details: nil))
          return
        }
        UIPasteboard.general.setItems(
          [["public.utf8-plain-text": value]],
          options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)]
        )
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "SplitTogetherMealShare") {
      let shareChannel = FlutterMethodChannel(
        name: "split_together/meal_share", binaryMessenger: registrar.messenger()
      )
      shareChannel.setMethodCallHandler { call, result in
        guard call.method == "shareText" else {
          result(FlutterMethodNotImplemented)
          return
        }
        guard let text = call.arguments as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          result(FlutterError(code: "empty-list", message: "沒有可分享的聚餐清單", details: nil))
          return
        }
        guard let presenter = registrar.viewController,
              presenter.viewIfLoaded?.window != nil,
              presenter.presentedViewController == nil else {
          result(FlutterError(code: "share-unavailable", message: "無法開啟系統分享選單", details: nil))
          return
        }
        let sheet = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        if let popover = sheet.popoverPresentationController {
          let bounds = presenter.view.bounds
          popover.sourceView = presenter.view
          popover.sourceRect = CGRect(x: bounds.midX, y: bounds.midY, width: 1, height: 1)
          popover.permittedArrowDirections = []
        }
        presenter.present(sheet, animated: true) { result(nil) }
      }
    }
  }

  private static func launchURL(for id: String) -> URL? {
    switch id {
    case "com.chinatrust.mobilebank":
      // The general-purpose link from CTBC's PRO_URL.html, with no transaction.
      return URL(string: "ctbcmobilebank://?openExternalBrowser=1&task_id=")
    case "tw.com.taishinbank.mobile":
      return URL(string: "tsmb://")
    default:
      let prefix = "ios-shortcut:"
      guard id.hasPrefix(prefix) else { return nil }
      let name = String(id.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty, name.count <= 100,
            name.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
      var url = URLComponents()
      url.scheme = "shortcuts"
      url.host = "run-shortcut"
      url.queryItems = [URLQueryItem(name: "name", value: name)]
      return url.url
    }
  }

  private static func storeURL(for id: String) -> URL? {
    let storeID: String
    switch id {
    case "com.chinatrust.mobilebank": storeID = "417698185"
    case "tw.com.taishinbank.mobile": storeID = "388917170"
    case "tw.gov.post.mpost": storeID = "1598092335"
    default: return nil
    }
    return URL(string: "https://apps.apple.com/tw/app/id" + storeID)
  }

  private static func open(_ url: URL?, result: @escaping FlutterResult) {
    guard let url = url else {
      result(false)
      return
    }
    UIApplication.shared.open(url, options: [:]) { opened in result(opened) }
  }
}
