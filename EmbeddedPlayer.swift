import SwiftUI
import WebKit

@MainActor
final class EmbeddedPlayerState: ObservableObject {
    @Published var qualities: [StreamQuality] = []
    @Published var selectedQuality = -1
    @Published var error: String?
    weak var webView: WKWebView?
    var frame: WKFrameInfo?
    func reset() { qualities = []; selectedQuality = -1; error = nil; frame = nil; webView = nil }
    func select(_ quality: StreamQuality) {
        guard qualities.contains(quality), let webView, let frame else { return }
        webView.evaluateJavaScript("window.jwplayer().setCurrentQuality(\(quality.id));", in: frame, in: .page) { [weak self] result in
            if case .success = result { self?.selectedQuality = quality.id }
        }
    }
}

struct EmbeddedPlayerView: UIViewRepresentable {
    let url: URL
    let referrer: URL
    let state: EmbeddedPlayerState
    func makeCoordinator() -> Coordinator { Coordinator(state: state) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsAirPlayForMediaPlayback = true
        configuration.allowsPictureInPictureMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.add(context.coordinator, name: "footballQuality")
        // Expose only published player controls. Do not replace stream URLs, credentials, or DRM.
        let qualityBridge = """
        (() => {
          const report = () => {
            try {
              if (typeof window.jwplayer !== 'function') return;
              const p = window.jwplayer(), el = p.getContainer();
              if (!el || el.clientWidth < 180 || el.clientHeight < 90) return;
              const levels = p.getQualityLevels();
              if (!Array.isArray(levels) || !levels.length) return;
              window.webkit.messageHandlers.footballQuality.postMessage({
                levels: levels.slice(0, 20).map((q, i) => ({id:i, label:String(q.label || (q.height ? q.height+'p' : 'Auto')).slice(0,40)})),
                selected: p.getCurrentQuality()
              });
            } catch (_) {}
          };
          const timer = setInterval(report, 2000);
          addEventListener('pagehide', () => clearInterval(timer), {once:true});
          report();
        })();
        """
        configuration.userContentController.addUserScript(WKUserScript(source: qualityBridge, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false; view.backgroundColor = .black; view.scrollView.backgroundColor = .black
        view.scrollView.isScrollEnabled = false
        view.navigationDelegate = context.coordinator; view.uiDelegate = context.coordinator
        state.webView = view
        let escaped = url.absoluteString.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;")
        view.loadHTMLString("""
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;width:100%;height:100%;background:#000}iframe{width:100%;height:100%;border:0}</style>
        </head><body><iframe src="\(escaped)" allow="autoplay; encrypted-media; fullscreen; picture-in-picture" allowfullscreen referrerpolicy="strict-origin-when-cross-origin"></iframe></body></html>
        """, baseURL: referrer)
        return view
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "footballQuality")
        view.stopLoading(); view.loadHTMLString("", baseURL: nil)
        view.navigationDelegate = nil; view.uiDelegate = nil
    }
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        let state: EmbeddedPlayerState
        init(state: EmbeddedPlayerState) { self.state = state }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "footballQuality", let payload = message.body as? [String: Any],
                  let levels = payload["levels"] as? [[String: Any]], !levels.isEmpty, levels.count <= 20 else { return }
            let qualities = levels.compactMap { level -> StreamQuality? in
                guard let id = level["id"] as? Int, id >= 0, id < 20, let label = level["label"] as? String else { return nil }
                return StreamQuality(id: id, label: label.lowercased() == "auto" ? "تلقائي" : String(label.prefix(40)))
            }
            guard Set(qualities.map(\.id)).count == qualities.count else { return }
            state.frame = message.frameInfo
            if qualities != state.qualities { state.qualities = qualities }
            if let selected = payload["selected"] as? Int, selected != state.selectedQuality { state.selectedQuality = selected }
        }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.targetFrame == nil || (action.targetFrame?.isMainFrame == true && action.navigationType == .linkActivated) {
                decisionHandler(.cancel); return
            }
            if let scheme = action.request.url?.scheme, !["https", "about", "blob"].contains(scheme) {
                decisionHandler(.cancel); return
            }
            decisionHandler(.allow)
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
        private func failed(_ error: Error) {
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            state.error = "تعذّر تحميل هذا البث. أعد المحاولة أو اختر مصدرًا آخر."
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { state.error = "توقف البث. اضغط إعادة المحاولة." }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
    }
}
