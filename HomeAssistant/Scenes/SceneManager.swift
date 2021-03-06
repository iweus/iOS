import Foundation
import UIKit
import PromiseKit
import Shared
import MBProgressHUD

// todo: can i combine this with the enum?
@available(iOS 13, *)
struct SceneQuery<DelegateType: UIWindowSceneDelegate> {
    let activity: SceneActivity
}

@available(iOS 13, *)
extension UIWindowSceneDelegate {
    func informManager(from connectionOptions: UIScene.ConnectionOptions) {
        let pendingResolver: (Self) -> Void = Current.sceneManager
            .pendingResolver(from: connectionOptions.userActivities)

        pendingResolver(self)
    }
}

@available(iOS, deprecated: 13.0)
struct SceneManagerPreSceneCompatibility {
    var windowController: WebViewWindowController?
    var urlHandler: IncomingURLHandler?
    let windowControllerPromise: Guarantee<WebViewWindowController>
    let windowControllerSeal: (WebViewWindowController) -> Void

    init() {
        (self.windowControllerPromise, self.windowControllerSeal) = Guarantee<WebViewWindowController>.pending()
    }

    mutating func willFinishLaunching() {
        let window = UIWindow(haForiOS12: ())
        let windowController = WebViewWindowController(window: window, restorationActivity: nil)
        self.windowController = windowController
        self.urlHandler = IncomingURLHandler(windowController: windowController)
        windowControllerSeal(windowController)
    }

    mutating func didFinishLaunching() {
        windowController?.setup()
    }
}

class SceneManager {
    // types too hard here
    fileprivate static var activityUserInfoKeyResolver = "resolver"
    private var pendingResolvers: [String: Any] = [:]

    @available(iOS, deprecated: 13.0)
    var compatibility = SceneManagerPreSceneCompatibility()

    var webViewWindowControllerPromise: Guarantee<WebViewWindowController> {
        if #available(iOS 13, *) {
            return firstly { () -> Guarantee<WebViewSceneDelegate> in
                scene(for: .init(activity: .webView))
            }.map { delegate in
                delegate.windowController!
            }
        } else {
            return compatibility.windowControllerPromise
        }
    }

    fileprivate func pendingResolver<T>(from activities: Set<NSUserActivity>) -> (T) -> Void {
        let (promise, outerResolver) = Guarantee<T>.pending()

        if supportsMultipleScenes {
            activities.compactMap { activity in
                activity.userInfo?[Self.activityUserInfoKeyResolver] as? String
            }.compactMap { token in
                pendingResolvers[token] as? (T) -> Void
            }.forEach { resolver in
                promise.done { resolver($0) }
            }
        } else {
            pendingResolvers
                .values
                .compactMap { $0 as? (T) -> Void }
                .forEach { resolver in promise.done { resolver($0) } }
        }

        return outerResolver
    }

    @available(iOS 13, *)
    private func existingScenes(for activity: SceneActivity) -> [UIScene] {
        UIApplication.shared.connectedScenes.filter { scene in
            scene.session.configuration.name.flatMap(SceneActivity.init(configurationName:)) == activity
        }.sorted { a, b in
            switch (a.activationState, b.activationState) {
            case (.unattached, .unattached): return true
            case (.unattached, _): return false
            case (_, .unattached): return true
            case (.foregroundActive, _): return true
            case (_, .foregroundActive): return false
            case (.foregroundInactive, _): return true
            case (_, .foregroundInactive): return false
            case (_, _): return true
            }
        }
    }

    public var supportsMultipleScenes: Bool {
        if #available(iOS 13, *) {
            return UIApplication.shared.supportsMultipleScenes
        } else {
            return false
        }
    }

    @available(iOS 13, *)
    public func activateAnyScene(for activity: SceneActivity) {
        UIApplication.shared.requestSceneSessionActivation(
            existingScenes(for: activity).first?.session,
            userActivity: activity.activity,
            options: nil
        ) { error in
            Current.Log.error(error)
        }
    }

    @available(iOS 13, *)
    public func scene<DelegateType: UIWindowSceneDelegate>(
        for query: SceneQuery<DelegateType>
    ) -> Guarantee<DelegateType> {
        if let active = existingScenes(for: query.activity).first,
           let delegate = active.delegate as? DelegateType {
            UIApplication.shared.requestSceneSessionActivation(
                active.session,
                userActivity: nil,
                options: nil,
                errorHandler: nil
            )
            return .value(delegate)
        }

        assert(supportsMultipleScenes || query.activity == .webView,
               "if we don't support multiple scenes, how are we running without one besides at immediate startup?")

        let (promise, resolver) = Guarantee<DelegateType>.pending()

        let token = UUID().uuidString
        pendingResolvers[token] = resolver

        if supportsMultipleScenes {
            let activity = query.activity.activity
            activity.userInfo = [
                Self.activityUserInfoKeyResolver: token
            ]

            UIApplication.shared.requestSceneSessionActivation(
                nil,
                userActivity: activity,
                options: nil,
                errorHandler: { error in
                    // error is called in most cases, even when no error occurs, so we silently swallow it
                    // todo: does this actually happen in normal circumstances?
                    Current.Log.error("scene activation error: \(error)")
                }
            )
        }

        return promise
    }

    public func showFullScreenConfirm(
        icon: MaterialDesignIcons,
        text: String
    ) {
        firstly {
            webViewWindowControllerPromise
        }.compactMap {
            $0.window
        }.done { window in
            let hud = MBProgressHUD.showAdded(to: window, animated: true)
            hud.mode = .customView
            hud.backgroundView.style = .blur
            hud.customView = with(IconImageView(frame: .init(x: 0, y: 0, width: 64, height: 64))) {
                $0.iconDrawable = icon
            }
            hud.label.text = text
            hud.hide(animated: true, afterDelay: 3)
        }.cauterize()
    }
}
