import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController

    self.title = "SecureShell Go"
    // Below this, there is no longer comfortable room for the side-by-side
    // terminal + SFTP browser layout that `WindowSizeClass.isAtLeastMedium`
    // (lib/services/layout_breakpoints.dart, >=600dp) switches on.
    self.contentMinSize = NSSize(width: 900, height: 600)
    self.setContentSize(NSSize(width: 1100, height: 720))
    self.setFrame(self.frame, display: true)
    self.center()

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
