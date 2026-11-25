import SwiftUI
import WebKit

// SAML SSO login, following the same flow as the Parsec web dashboard (dash.parsec.app/saml/login):
// 1. POST /v2/saml/weblogin/{team_id} -> { sso_url }
// 2. The user signs in with their identity provider at sso_url. Parsec then redirects to
//    https://dash.parsec.app/saml/complete?signed_token=...
// 3. POST /v2/saml/session/token { signed_token } -> { session_id }
enum SAMLLogin {
	static let apiBase = "https://kessel-api.parsec.app"
	static let userAgent = "parsec/150-93b Windows/11 libmatoya/4.0"
	static let sessionScopes = ["api.writer", "team.admin", "ws.client"]

	private static let teamIDKey = "OPSAMLTeamID"

	struct Failure: Error {
		let message: String
	}

	static var lastTeamID: String {
		get { UserDefaults.standard.string(forKey: teamIDKey) ?? "" }
		set { UserDefaults.standard.set(newValue, forKey: teamIDKey) }
	}

	// True when a failed /v1/auth response says the account has to log in with SAML.
	static func isSAMLRequired(_ data: Data) -> Bool {
		guard let dict = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
			return false
		}
		if let codes = dict["codes"] as? [[String: Any]], codes.contains(where: { ($0["type"] as? String) == "saml_required" }) {
			return true
		}
		if let error = dict["error"] as? String, error.lowercased().contains("saml") {
			return true
		}
		return false
	}

	// Step 1: ask Parsec for the identity provider URL of the team.
	static func start(teamID: String, completion: @escaping (Result<URL, Failure>) -> Void) {
		var allowed = CharacterSet.urlPathAllowed
		allowed.remove("/")
		guard let team = teamID.addingPercentEncoding(withAllowedCharacters: allowed),
		      let url = URL(string: "\(apiBase)/v2/saml/weblogin/\(team)") else {
			completion(.failure(Failure(message: "Invalid team ID")))
			return
		}

		post(url, body: ["session_scopes": sessionScopes]) { result in
			completion(result.flatMap { data in
				guard let dict = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any],
				      let ssoString = dict["sso_url"] as? String,
				      let ssoURL = URL(string: ssoString) else {
					return .failure(Failure(message: "Bad response from the server"))
				}
				return .success(ssoURL)
			})
		}
	}

	// Step 3: exchange the signed token for a session. Returns the raw response so it can be saved like a regular login.
	static func finish(signedToken: String, completion: @escaping (Result<Data, Failure>) -> Void) {
		let url = URL(string: "\(apiBase)/v2/saml/session/token")!
		post(url, body: ["signed_token": signedToken]) { result in
			completion(result.flatMap { data in
				guard (try? JSONDecoder().decode(ClientInfo.self, from: data)) != nil else {
					return .failure(Failure(message: "Bad response from the server"))
				}
				return .success(data)
			})
		}
	}

	// The signed token from the page Parsec redirects to once the identity provider accepted the login.
	static func signedToken(from url: URL) -> String? {
		guard let host = url.host?.lowercased(), host == "parsec.app" || host.hasSuffix(".parsec.app"),
		      url.path.hasSuffix("/saml/complete"),
		      let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
		      let token = items.first(where: { $0.name == "signed_token" })?.value,
		      !token.isEmpty else {
			return nil
		}
		return token
	}

	// Forget identity provider cookies, so the next SAML login starts fresh.
	static func clearWebData() {
		let store = WKWebsiteDataStore.default()
		store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
	}

	private static func post(_ url: URL, body: [String: Any], completion: @escaping (Result<Data, Failure>) -> Void) {
		var request = URLRequest(url: url)
		request.httpMethod = "POST"
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
		request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [])

		URLSession.shared.dataTask(with: request) { data, response, error in
			let result: Result<Data, Failure>
			if let data = data, let status = (response as? HTTPURLResponse)?.statusCode {
				if (200..<300).contains(status) {
					result = .success(data)
				} else if let info = try? JSONDecoder().decode(ErrorInfo.self, from: data), !info.error.isEmpty {
					result = .failure(Failure(message: info.error))
				} else {
					result = .failure(Failure(message: "SAML login failed (HTTP \(status))"))
				}
			} else {
				result = .failure(Failure(message: error?.localizedDescription ?? "Could not reach the server"))
			}
			DispatchQueue.main.async { completion(result) }
		}.resume()
	}
}

struct SAMLRequest: Identifiable {
	let id = UUID()
	let url: URL
}

// Sheet showing the identity provider's login page.
struct SAMLLoginSheet: View {
	let url: URL
	let onToken: (String) -> Void
	let onError: (String) -> Void
	let onCancel: () -> Void

	@State private var isLoading = true

	var body: some View {
		NavigationView {
			ZStack {
				SAMLWebView(url: url, isLoading: $isLoading, onToken: onToken, onError: onError)
					.edgesIgnoringSafeArea(.bottom)
				if isLoading {
					ActivityIndicator(isAnimating: $isLoading, style: .large, tint: .gray)
				}
			}
			.navigationBarTitle("SAML Single Sign-On", displayMode: .inline)
			.navigationBarItems(leading: Button("Cancel", action: onCancel))
		}
		.navigationViewStyle(StackNavigationViewStyle())
	}
}

struct SAMLWebView: UIViewRepresentable {
	let url: URL
	@Binding var isLoading: Bool
	let onToken: (String) -> Void
	let onError: (String) -> Void

	func makeCoordinator() -> Coordinator {
		Coordinator(self)
	}

	func makeUIView(context: Context) -> WKWebView {
		let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
		webView.navigationDelegate = context.coordinator
		webView.uiDelegate = context.coordinator
		webView.load(URLRequest(url: url))
		return webView
	}

	func updateUIView(_ webView: WKWebView, context: Context) {
		context.coordinator.parent = self
	}

	class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
		var parent: SAMLWebView
		private var finished = false

		init(_ parent: SAMLWebView) {
			self.parent = parent
		}

		func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
			if let url = navigationAction.request.url, let token = SAMLLogin.signedToken(from: url) {
				// Don't let the dashboard page use the token, we exchange it for a session ourselves.
				decisionHandler(.cancel)
				if !finished {
					finished = true
					webView.stopLoading()
					parent.onToken(token)
				}
				return
			}
			decisionHandler(.allow)
		}

		func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
			parent.isLoading = true
		}

		func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
			parent.isLoading = false
		}

		func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
			parent.isLoading = false
		}

		func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
			parent.isLoading = false
			let nsError = error as NSError
			// Cancelled loads and the interrupted load from our own .cancel above aren't real errors.
			if finished || nsError.code == NSURLErrorCancelled || (nsError.domain == "WebKitErrorDomain" && nsError.code == 102) {
				return
			}
			finished = true
			parent.onError(error.localizedDescription)
		}

		// Identity providers sometimes open links in a new window; keep them in this one.
		func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
			if navigationAction.targetFrame == nil {
				webView.load(navigationAction.request)
			}
			return nil
		}
	}
}
