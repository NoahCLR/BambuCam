import SwiftUI
import BambuKit

@main
struct BambuCamApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private var model: AppModel { appDelegate.model }

    var body: some Scene {
        Window("BambuCam", id: "main") {
            MainWindowView(model: model)
                .onAppear { model.startIfNeeded() }
        }
        .defaultSize(width: 1040, height: 700)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.presented)
        .defaultWindowPlacement { _, context in
            WindowPlacement(.center, size: Self.defaultMainWindowSize(in: context.defaultDisplay.visibleRect))
        }
        .windowIdealPlacement { _, context in
            WindowPlacement(.center, size: Self.fullScreenFriendlySize(in: context.defaultDisplay.visibleRect))
        }

        Settings {
            SettingsView(model: model)
        }
    }

    private static func defaultMainWindowSize(in visibleRect: CGRect) -> CGSize {
        let width = min(max(960, visibleRect.width * 0.72), visibleRect.width - 80)
        let height = min(max(620, visibleRect.height * 0.72), visibleRect.height - 80)
        return CGSize(width: width, height: height)
    }

    private static func fullScreenFriendlySize(in visibleRect: CGRect) -> CGSize {
        let targetAspect: CGFloat = 16 / 9
        let widthForHeight = visibleRect.height * targetAspect
        if widthForHeight <= visibleRect.width {
            return CGSize(width: widthForHeight, height: visibleRect.height)
        }
        return CGSize(width: visibleRect.width, height: visibleRect.width / targetAspect)
    }

}
