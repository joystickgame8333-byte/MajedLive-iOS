import SwiftUI
import WebKit

@MainActor
final class EmbeddedPlayerState: ObservableObject {
    @Published var qualities: [StreamQuality] = []
    @Published var selectedQuality = -1
    @Published var error: String?
    @Published var started = false
    @Published var awaitingTap = false
    weak var webView: WKWebView?
    var frame: WKFrameInfo?
    var playbackFrame: WKFrameInfo?
    func reset() { qualities = []; selectedQuality = -1; error = nil; started = false; awaitingTap = false; frame = nil; playbackFrame = nil; webView = nil }
    func play() {
        guard let webView, let playbackFrame else { return }
        let script = """
        (() => {
          const video = Array.from(document.querySelectorAll('video')).sort((a,b) => b.clientWidth*b.clientHeight-a.clientWidth*a.clientHeight)[0];
          if (!video) return;
          video.playsInline = true;
          video.play().catch(() => { video.muted = true; video.play().catch(() => window.webkit.messageHandlers.footballQuality.postMessage({kind:'error',code:'play'})); });
        })();
        """
        webView.evaluateJavaScript(script, in: playbackFrame, in: .page) { _ in }
    }
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
          const send = value => window.webkit.messageHandlers.footballQuality.postMessage(value);
          let lastTime = -1, errorSince = 0;
          const report = () => {
            try {
              const videos = Array.from(document.querySelectorAll('video')).filter(v => v.clientWidth > 100 && v.clientHeight > 60);
              const video = videos.sort((a,b) => b.clientWidth*b.clientHeight-a.clientWidth*a.clientHeight)[0];
              if (video) {
                video.playsInline = true;
                video.setAttribute('playsinline','');
                video.setAttribute('webkit-playsinline','');
                if (!video.paused && video.readyState >= 2 && video.currentTime !== lastTime) {
                  send({kind:'playing'}); lastTime = video.currentTime; errorSince = 0;
                } else if (video.paused && !video.error && (video.currentSrc || video.src)) {
                  send({kind:'tap'});
                }
                if (video.error) send({kind:'error', code:video.error.code});
              }
              const text = (document.body?.innerText || '').slice(0,4000).toLowerCase();
              const failed = text.includes('parsed_data.status is not') || text.includes('stream loading failed') || text.includes('stream error');
              if (failed && (!video || video.readyState < 2)) {
                if (!errorSince) errorSince = Date.now();
                if (Date.now()-errorSince > 5000) send({kind:'error'});
              } else { errorSince = 0; }
            } catch (_) {}
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
          const timer = setInterval(report, 1000);
          addEventListener('pagehide', () => clearInterval(timer), {once:true});
          report();
        })();
        """
        configuration.userContentController.addUserScript(WKUserScript(source: qualityBridge, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        configuration.userContentController.addUserScript(WKUserScript(source: PlayerAdProtection.script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false; view.backgroundColor = .black; view.scrollView.backgroundColor = .black
        view.scrollView.isScrollEnabled = false
        view.navigationDelegate = context.coordinator; view.uiDelegate = context.coordinator
        state.webView = view
        // Navigate to the published embed itself so its real origin/cookies and nested
        // player navigation work normally, instead of creating an extra synthetic iframe.
        var request = URLRequest(url: url)
        request.setValue(referrer.absoluteString, forHTTPHeaderField: "Referer")
        request.timeoutInterval = 25
        // Install rules before the first request, including every nested frame.
        let coordinator = context.coordinator
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "football-player-ads-v2", encodedContentRuleList: PlayerAdProtection.rules) { [weak view, weak coordinator] rules, _ in
            DispatchQueue.main.async {
                guard let view, let coordinator, coordinator.active else { return }
                guard let rules else { state.error = "تعذّر تجهيز حجب الإعلانات. أعد المحاولة."; return }
                view.configuration.userContentController.add(rules)
                view.load(request)
            }
        }
        return view
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.active = false
        view.configuration.userContentController.removeScriptMessageHandler(forName: "footballQuality")
        view.stopLoading(); view.loadHTMLString("", baseURL: nil)
        view.navigationDelegate = nil; view.uiDelegate = nil
    }
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        let state: EmbeddedPlayerState
        var active = true
        init(state: EmbeddedPlayerState) { self.state = state }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard active, message.name == "footballQuality", message.webView === state.webView,
                  let payload = message.body as? [String: Any] else { return }
            if let kind = payload["kind"] as? String {
                if kind == "playing" { state.started = true; state.awaitingTap = false; state.error = nil }
                if kind == "tap", !state.started { state.playbackFrame = message.frameInfo; state.awaitingTap = true }
                if kind == "error", !state.started { state.error = "مصدر البث أبلغ عن خطأ في تحميل الفيديو." }
                return
            }
            guard let levels = payload["levels"] as? [[String: Any]], !levels.isEmpty, levels.count <= 20 else { return }
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
            if PlayerAdProtection.isBlocked(action.request.url) { decisionHandler(.cancel); return }
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
            guard active, (error as NSError).code != NSURLErrorCancelled else { return }
            state.error = "تعذّر الاتصال بالمشغّل (\((error as NSError).code)). اختر بثًا آخر."
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { state.error = "توقف البث. اضغط إعادة المحاولة." }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
    }
}

// Target advertising only: media CDNs, player libraries and signed stream URLs remain usable.
enum PlayerAdProtection {
    static let domains = ["hubeamily.com", "trovesleepit.com", "chatmate.tv", "chaturbate.com", "stripchat.com", "exoclick.com", "exosrv.com", "exdynsrv.com", "trafficjunky.net", "juicyads.com", "popads.net", "popcash.net", "adsterra.com", "doubleclick.net", "googlesyndication.com", "adsco.re"]
    static func isBlocked(_ url: URL?) -> Bool {
        guard let host = url?.host?.lowercased() else { return false }
        return domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }
    static let selectors = "[id='ad-overlay'],[id='adOverlay'],[id='ad-container'],[id='adContainer'],[id='ads-container'],[id='video-ad'],[id='videoAd'],.ad-overlay,.ads-overlay,.ad-container,.ads-container,.video-ad,.video-ads,.vast-overlay,.vast-container,.popunder,.pop-up-ad,iframe[src*='chatmate.tv'],iframe[src*='stripchat.com'],a[href*='chatmate.tv'],a[href*='chaturbate.com']"
    static var rules: String {
        let network: [[String: Any]] = domains.map { domain in
            ["trigger": ["url-filter": "^https?://([^/]+\\.)?" + NSRegularExpression.escapedPattern(for: domain) + "[:/]"], "action": ["type": "block"]]
        }
        let cosmetic: [String: Any] = ["trigger": ["url-filter": ".*"], "action": ["type": "css-display-none", "selector": selectors]]
        let data = try! JSONSerialization.data(withJSONObject: network + [cosmetic])
        return String(decoding: data, as: UTF8.self)
    }
    static let script = #"""
    (() => {
      window.open = () => null;
      const selectors = "[id='ad-overlay'],[id='adOverlay'],[id='ad-container'],[id='adContainer'],[id='ads-container'],[id='video-ad'],[id='videoAd'],.ad-overlay,.ads-overlay,.ad-container,.ads-container,.video-ad,.video-ads,.vast-overlay,.vast-container,.popunder,.pop-up-ad,iframe[src*='chatmate.tv'],iframe[src*='stripchat.com'],a[href*='chatmate.tv'],a[href*='chaturbate.com']";
      const hide = el => {
        if (el.dataset.footballAdHidden) return;
        el.dataset.footballAdHidden = '1';
        el.querySelectorAll('video,audio').forEach(v => { v.pause(); v.muted = true; });
        el.style.setProperty('display','none','important');
        el.style.setProperty('pointer-events','none','important');
      };
      let queued = false;
      const clean = () => {
        queued = false;
        document.querySelectorAll(selectors).forEach(hide);
        // Providers often randomize IDs. Identify the ad's own close control,
        // then hide only its positioned overlay, never the surrounding player.
        document.querySelectorAll('button,span,a,div').forEach(button => {
          if (button.children.length || !/^(close ad|close advertisement|إغلاق الإعلان)\s*[×x✕]?$/i.test((button.textContent || '').trim())) return;
          let el = button.parentElement;
          for (let depth = 0; el && el !== document.body && depth < 5; depth++, el = el.parentElement) {
            const style = getComputedStyle(el), rect = el.getBoundingClientRect();
            if (!el.querySelector('video, #player, .jwplayer, [data-player]') && (style.position === 'fixed' || style.position === 'absolute') && rect.width > 150 && rect.height > 100 && rect.width * rect.height < innerWidth * innerHeight * 0.95) { hide(el); break; }
          }
        });
      };
      const observer = new MutationObserver(() => { if (!queued) { queued = true; requestAnimationFrame(clean); } });
      observer.observe(document, {childList:true,subtree:true});
      addEventListener('DOMContentLoaded', clean, {once:true});
      addEventListener('pagehide', () => observer.disconnect(), {once:true});
    })();
    """#
}
