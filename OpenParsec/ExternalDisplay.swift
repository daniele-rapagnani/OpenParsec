import UIKit

// External monitor support (HDMI / USB-C / AirPlay).
//
// iOS hands the app its own scene for a connected monitor (the external display roles in
// Info.plist and AppDelegate). While a stream is open, the stream's render view and cursor move
// into a window on that scene, at the monitor's own size and scale, and the device screen
// becomes a trackpad (plus the on-screen keyboard and stream menu). With no stream open no window
// is made, so iOS keeps mirroring the device screen as before.

final class ExternalDisplayManager {
	static let shared = ExternalDisplayManager()

	private var scene: UIWindowScene?
	private var window: UIWindow?
	private weak var stream: ParsecViewController?
	private weak var attached: ParsecViewController?

	var isConnected: Bool { scene != nil }
	var isShowingStream: Bool { window != nil }

	private init() {}

	// MARK: Scene lifecycle

	func sceneConnected(_ scene: UIWindowScene) {
		let screen = scene.screen
		appNote("[display] external display connected, \(Int(screen.bounds.width))x\(Int(screen.bounds.height)) pt at \(screen.scale)x")
		self.scene = scene
		update()
	}

	func sceneDisconnected(_ scene: UIWindowScene) {
		guard scene === self.scene else { return }
		appNote("[display] external display disconnected")
		self.scene = nil
		update()
	}

	// MARK: Stream lifecycle

	/// A stream is open: shows it on the monitor if one is connected.
	func attach(_ controller: ParsecViewController) {
		stream = controller
		update()
	}

	/// The stream is closing: gives the render view back to the device screen.
	func detach() {
		stream = nil
		update()
	}

	/// Re-evaluates where the stream shows (monitor connected, setting on, stream open).
	func update() {
		let wanted = scene != nil && stream != nil && SettingsHandler.useExternalDisplay
		if wanted, window == nil, let scene = scene, let controller = stream {
			let host = ExternalStreamViewController()
			let window = UIWindow(windowScene: scene)
			window.rootViewController = host
			window.backgroundColor = .black
			window.isHidden = false
			self.window = window
			host.loadViewIfNeeded()
			host.view.frame = window.bounds
			host.onLayout = { [weak controller] in controller?.layoutStream() }
			attached = controller
			controller.moveStream(to: host)
			appNote("[display] stream moved to the external display")
			applyClientResolution()
		} else if !wanted, let window = window {
			attached?.moveStreamBack()
			attached = nil
			window.isHidden = true
			window.rootViewController = nil
			self.window = nil
			appNote("[display] stream back on this screen")
			applyClientResolution()
		}
	}

	// MARK: Resolution

	/// With "Client Resolution", asks the host for the size of the screen the stream is on.
	private func applyClientResolution() {
		guard SettingsHandler.resolution == .client else { return }
		let pixels: CGSize
		if let screen = window?.screen {
			pixels = CGSize(width: screen.bounds.width * screen.scale, height: screen.bounds.height * screen.scale)
		} else if let view = attached?.view ?? stream?.view, view.bounds.width > 0 {
			let scale = view.window?.screen.nativeScale ?? UIScreen.main.nativeScale
			pixels = CGSize(width: view.bounds.width * scale, height: view.bounds.height * scale)
		} else {
			return
		}
		ParsecResolution.updateClientResolution(width: Int(pixels.width), height: Int(pixels.height))
		// before the host sent its video config, its first config picks the new size up itself
		guard ParsecBackgroundManager.shared.hasActiveConnection, DataManager.model.bitrate > 0 else { return }
		DataManager.model.resolutionX = SettingsHandler.resolution.width
		DataManager.model.resolutionY = SettingsHandler.resolution.height
		CParsec.updateHostVideoConfig()
	}
}

// MARK: - Scene delegate

/// The monitor's scene. It only reports to the manager: the device's SceneDelegate keeps owning
/// the connection, so unplugging a monitor never ends or pauses the stream.
class ExternalDisplaySceneDelegate: UIResponder, UIWindowSceneDelegate {
	func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
		guard let scene = scene as? UIWindowScene else { return }
		ExternalDisplayManager.shared.sceneConnected(scene)
	}

	func sceneDidDisconnect(_ scene: UIScene) {
		guard let scene = scene as? UIWindowScene else { return }
		ExternalDisplayManager.shared.sceneDisconnected(scene)
	}
}

// MARK: - The monitor's view

final class ExternalStreamViewController: UIViewController {
	var onLayout: (() -> Void)?

	override var prefersStatusBarHidden: Bool { true }
	override var prefersHomeIndicatorAutoHidden: Bool { true }

	override func viewDidLoad() {
		super.viewDidLoad()
		view.backgroundColor = .black
		view.clipsToBounds = true
		view.isUserInteractionEnabled = false
	}

	override func viewDidLayoutSubviews() {
		super.viewDidLayoutSubviews()
		onLayout?()
	}
}
