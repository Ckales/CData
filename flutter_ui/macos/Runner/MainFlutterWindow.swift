import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
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
  }
}
