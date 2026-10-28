import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  // 与 Flutter MacToolbar 的高度一致（lib/mac_widgets.dart）。
  private let toolbarHeight: CGFloat = 45

  private func centerWindowButtons() {
    // 全屏时让 AppKit 管理自动隐藏的标题栏。
    guard !styleMask.contains(.fullScreen),
      let container = standardWindowButton(.closeButton)?.superview else { return }

    var frame = container.frame
    frame.origin.y = frame.maxY - toolbarHeight
    frame.size.height = toolbarHeight
    container.frame = frame

    for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
      guard let button = standardWindowButton(type) else { continue }
      button.setFrameOrigin(NSPoint(
        x: button.frame.minX,
        y: (toolbarHeight - button.frame.height) / 2))
    }
  }

  @objc private func scheduleWindowButtonLayout(_ notification: Notification) {
    // 在 AppKit 完成标题栏布局后调整，避免缩放、退出全屏时被系统重置。
    DispatchQueue.main.async { [weak self] in
      self?.centerWindowButtons()
    }
  }

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    // 连接栏、侧栏加网格在这个宽度以下挤不下；冒烟测试按这个尺寸验证不溢出
    self.contentMinSize = NSSize(width: 900, height: 600)

    // 工具栏和标题栏合成一条（Querious 的样子）：标题栏透明、内容铺满，红绿灯浮在 Flutter 画的工具栏上
    self.titlebarAppearsTransparent = true
    self.titleVisibility = .hidden
    self.styleMask.insert(.fullSizeContentView)

    // 内容铺满之后标题栏那块被 Flutter 盖住，拖不动窗口。工具栏空白处按下时 Flutter 通知这里，
    // 用当前的鼠标事件交给系统拖；双击按系统设置缩放或最小化
    let channel = FlutterMethodChannel(
      name: "cdata/window",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let window = self else {
        result(nil)
        return
      }
      switch call.method {
      case "startDrag":
        if let event = NSApp.currentEvent {
          window.performDrag(with: event)
        }
        result(nil)
      case "titleDoubleClick":
        let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")
        if action == "Minimize" {
          window.performMiniaturize(nil)
        } else {
          window.performZoom(nil)
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()

    for name in [NSWindow.didResizeNotification, NSWindow.didExitFullScreenNotification,
                 NSWindow.didBecomeKeyNotification] {
      NotificationCenter.default.addObserver(
        self, selector: #selector(scheduleWindowButtonLayout(_:)), name: name, object: self)
    }
    scheduleWindowButtonLayout(Notification(name: NSWindow.didResizeNotification))
  }
}
