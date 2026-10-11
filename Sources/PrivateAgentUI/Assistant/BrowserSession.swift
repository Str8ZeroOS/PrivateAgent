import Foundation
import Observation
import WebKit
#if os(iOS)
import UIKit
#endif

/// A real browser the assistant drives one step at a time. Each run starts clean:
/// no saved logins, cookies or history (non-persistent data store).
@MainActor
@Observable
final class BrowserSession: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    var currentURL: String = ""
    var title: String = ""
    var isLoading: Bool = false

    struct Element: Sendable {
        let index: Int
        let tag: String
        let type: String
        let text: String
        let href: String
    }

    struct Observation: Sendable {
        let url: String
        let title: String
        let text: String
        let elements: [Element]
        let scrollY: Int
        let height: Int
    }

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
    }

    // MARK: Navigation delegate
    nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        Task { @MainActor in self.isLoading = true }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            self.isLoading = false
            self.currentURL = self.webView.url?.absoluteString ?? ""
            self.title = self.webView.title ?? ""
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.isLoading = false }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.isLoading = false }
    }

    // MARK: Actions
    func load(_ urlString: String) async -> String {
        var s = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.lowercased().hasPrefix("http") { s = "https://" + s }
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return "That is not a valid web address."
        }
        webView.load(URLRequest(url: url))
        await settle()
        return "Opened \(currentURL)"
    }

    func goBack() async -> String {
        guard webView.canGoBack else { return "There is no earlier page." }
        webView.goBack()
        await settle()
        return "Went back."
    }

    func goForward() async -> String {
        guard webView.canGoForward else { return "There is no later page." }
        webView.goForward()
        await settle()
        return "Went forward."
    }

    func scroll(down: Bool) async -> String {
        let js = "window.scrollBy(0, window.innerHeight * \(down ? "0.8" : "-0.8")); true"
        _ = try? await webView.evaluateJavaScript(js)
        try? await Task.sleep(nanoseconds: 400_000_000)
        return down ? "Scrolled down." : "Scrolled up."
    }

    func click(_ index: Int) async -> String {
        let js = "(function(){var e=window.__pa_els&&window.__pa_els[\(index)];if(!e)return 'missing';e.scrollIntoView({block:'center'});e.click();return 'ok';})()"
        let result = (try? await webView.evaluateJavaScript(js)) as? String
        guard result == "ok" else { return "That element is no longer on the page. Look at the page again." }
        await settle()
        return "Clicked [\(index)]."
    }

    func type(_ index: Int, text: String, submit: Bool) async -> String {
        let lit = Self.jsString(text)
        var js = "(function(){var e=window.__pa_els&&window.__pa_els[\(index)];if(!e)return 'missing';e.scrollIntoView({block:'center'});e.focus();"
        js += "var d=Object.getOwnPropertyDescriptor(Object.getPrototypeOf(e),'value');if(d&&d.set){d.set.call(e,\(lit));}else{e.value=\(lit);}"
        js += "e.dispatchEvent(new Event('input',{bubbles:true}));e.dispatchEvent(new Event('change',{bubbles:true}));"
        if submit {
            js += "if(e.form){if(e.form.requestSubmit){e.form.requestSubmit();}else{e.form.submit();}}else{e.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',keyCode:13,bubbles:true}));}"
        }
        js += "return 'ok';})()"
        let result = (try? await webView.evaluateJavaScript(js)) as? String
        guard result == "ok" else { return "That field is no longer on the page. Look at the page again." }
        if submit { await settle() }
        return submit ? "Typed into [\(index)] and submitted." : "Typed into [\(index)]."
    }

    func observe() async -> Observation {
        let raw = (try? await webView.evaluateJavaScript(Self.observeJS)) as? String
        guard let raw, let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Observation(url: currentURL, title: title, text: "(blank page)", elements: [], scrollY: 0, height: 0)
        }
        var els: [Element] = []
        for item in (obj["items"] as? [[String: Any]]) ?? [] {
            els.append(Element(
                index: (item["i"] as? Int) ?? els.count,
                tag: (item["tag"] as? String) ?? "",
                type: (item["type"] as? String) ?? "",
                text: (item["text"] as? String) ?? "",
                href: (item["href"] as? String) ?? ""
            ))
        }
        return Observation(
            url: (obj["url"] as? String) ?? currentURL,
            title: (obj["title"] as? String) ?? title,
            text: (obj["text"] as? String) ?? "",
            elements: els,
            scrollY: (obj["scrollY"] as? Int) ?? 0,
            height: (obj["height"] as? Int) ?? 0
        )
    }

    static func copyToClipboard(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #endif
    }

    // MARK: Helpers
    private func settle() async {
        try? await Task.sleep(nanoseconds: 900_000_000)
        var waited = 0
        while isLoading && waited < 16 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            waited += 1
        }
        currentURL = webView.url?.absoluteString ?? currentURL
        title = webView.title ?? title
    }

    private static func jsString(_ text: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [text]),
              var s = String(data: data, encoding: .utf8) else { return "\"\"" }
        s.removeFirst()
        s.removeLast()
        return s
    }

    private static let observeJS = #"""
    (function(){
      function vis(el){var r=el.getBoundingClientRect();var s=getComputedStyle(el);return r.width>0&&r.height>0&&s.visibility!=='hidden'&&s.display!=='none';}
      var sel='a[href],button,input,select,textarea,[role=button],[role=link],[onclick]';
      var els=Array.prototype.slice.call(document.querySelectorAll(sel)).filter(vis).slice(0,60);
      window.__pa_els=els;
      var items=els.map(function(el,i){
        var t=(el.innerText||el.value||el.getAttribute('aria-label')||el.placeholder||el.title||el.name||'');
        return {i:i,tag:el.tagName.toLowerCase(),type:(el.type||'').toLowerCase(),text:String(t).replace(/\s+/g,' ').trim().slice(0,80),href:el.href?String(el.href).slice(0,120):''};
      });
      return JSON.stringify({title:document.title,url:location.href,text:(document.body?document.body.innerText:'').replace(/\s+/g,' ').slice(0,3500),items:items,scrollY:Math.round(window.scrollY),height:document.documentElement.scrollHeight});
    })()
    """#
}