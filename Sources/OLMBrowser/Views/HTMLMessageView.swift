import SwiftUI
import WebKit

struct HTMLMessageView: NSViewRepresentable {
    let html: String
    let inlineImages: [String: String]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = true
        webView.setAccessibilityLabel("HTML email body")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let resolved = Self.resolvingInlineImages(in: html, images: inlineImages)
        guard context.coordinator.lastHTML != resolved else { return }
        context.coordinator.lastHTML = resolved
        webView.loadHTMLString(Self.securedDocument(containing: resolved), baseURL: nil)
    }

    static func resolvingInlineImages(in html: String, images: [String: String]) -> String {
        var result = html
        for (rawID, dataURL) in images {
            let id = rawID.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t\r\n"))
            guard !id.isEmpty else { continue }
            result = result.replacingOccurrences(of: "cid:\(id)", with: dataURL, options: .caseInsensitive)
            result = result.replacingOccurrences(of: "cid:<\(id)>", with: dataURL, options: .caseInsensitive)
        }
        return result
    }

    private static func securedDocument(containing messageHTML: String) -> String {
        let securityHead = """
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src data:; media-src 'none'; frame-src 'none'; connect-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
        <meta name="referrer" content="no-referrer">
        <style>
          :root { color-scheme: light dark; }
          html, body { background: transparent !important; }
          body {
            margin: 0; padding: 4px 2px 28px;
            font: -apple-system-body;
            color: CanvasText;
            overflow-wrap: anywhere;
          }
          img { max-width: 100% !important; height: auto !important; }
          table { max-width: 100% !important; }
          pre { white-space: pre-wrap; }
          a { color: LinkText; }
        </style>
        """

        if let headEnd = messageHTML.range(of: "<head", options: .caseInsensitive),
           let closingBracket = messageHTML[headEnd.lowerBound...].firstIndex(of: ">") {
            var secured = messageHTML
            secured.insert(contentsOf: securityHead, at: secured.index(after: closingBracket))
            return secured
        }

        return """
        <!doctype html>
        <html><head>\(securityHead)</head><body>\(messageHTML)</body></html>
        """
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var lastHTML: String?

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .linkActivated {
                decisionHandler(.cancel)
                return
            }
            let scheme = navigationAction.request.url?.scheme?.lowercased()
            decisionHandler(scheme == nil || scheme == "about" ? .allow : .cancel)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            nil
        }
    }
}
