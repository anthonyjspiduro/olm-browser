import SwiftUI
import WebKit

struct HTMLMessageView: NSViewRepresentable {
    let html: String
    let inlineImages: [String: String]
    let allowedRemoteImageOrigins: [String]
    let onExternalLinkRequested: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onExternalLinkRequested: onExternalLinkRequested) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.setURLSchemeHandler(
            context.coordinator.inlineImageHandler,
            forURLScheme: Self.inlineImageScheme
        )

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = true
        webView.setAccessibilityLabel("HTML email body")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onExternalLinkRequested = onExternalLinkRequested
        context.coordinator.inlineImageHandler.update(resources: inlineImages)
        let resolved = Self.resolvingInlineImages(in: html, images: inlineImages)
        let document = Self.securedDocument(
            containing: resolved,
            allowedRemoteImageOrigins: allowedRemoteImageOrigins
        )
        guard context.coordinator.lastDocument != document else { return }
        context.coordinator.lastDocument = document
        webView.loadHTMLString(document, baseURL: nil)
    }

    static func resolvingInlineImages(in html: String, images: [String: String]) -> String {
        var result = html
        for rawID in images.keys {
            let id = rawID.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t\r\n"))
            guard !id.isEmpty else { continue }
            let localURL = inlineImageURL(for: id)
            result = result.replacingOccurrences(of: "cid:\(id)", with: localURL, options: .caseInsensitive)
            result = result.replacingOccurrences(of: "cid:<\(id)>", with: localURL, options: .caseInsensitive)
        }
        return result
    }

    private static let inlineImageScheme = "olm-inline-image"

    fileprivate static func inlineImageURL(for contentID: String) -> String {
        let token = Data(contentID.lowercased().utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "\(inlineImageScheme)://resource/\(token)"
    }

    static func securedDocument(
        containing messageHTML: String,
        allowedRemoteImageOrigins: [String] = []
    ) -> String {
        let remoteSources = RemoteImagePolicy.sanitizedCSPOrigins(allowedRemoteImageOrigins)
            .joined(separator: " ")
        let localImageSources = "data: \(inlineImageScheme):"
        let imageSources = remoteSources.isEmpty ? localImageSources : "\(localImageSources) \(remoteSources)"
        let securityHead = """
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; img-src \(imageSources); style-src 'unsafe-inline'; font-src data:; media-src 'none'; frame-src 'none'; child-src 'none'; connect-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'; manifest-src 'none'; worker-src 'none'">
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

        return """
        <!doctype html>
        <html><head>\(securityHead)</head><body>\(messageHTML)</body></html>
        """
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var lastDocument: String?
        fileprivate let inlineImageHandler = InlineImageSchemeHandler()
        var onExternalLinkRequested: (URL) -> Void

        init(onExternalLinkRequested: @escaping (URL) -> Void) {
            self.onExternalLinkRequested = onExternalLinkRequested
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .linkActivated {
                decisionHandler(.cancel)
                if let url = navigationAction.request.url {
                    onExternalLinkRequested(url)
                }
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
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                onExternalLinkRequested(url)
            }
            return nil
        }
    }
}

fileprivate final class InlineImageSchemeHandler: NSObject, WKURLSchemeHandler, @unchecked Sendable {
    private let lock = NSLock()
    private var resourcesByURL: [String: (mimeType: String, data: Data)] = [:]

    func update(resources: [String: String]) {
        var updated: [String: (mimeType: String, data: Data)] = [:]
        for (rawID, dataURL) in resources {
            let id = rawID.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t\r\n"))
            guard !id.isEmpty, let resource = Self.decode(dataURL: dataURL) else { continue }
            updated[HTMLMessageView.inlineImageURL(for: id)] = resource
        }
        lock.withLock { resourcesByURL = updated }
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              let resource = lock.withLock({ resourcesByURL[url.absoluteString] }) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        urlSchemeTask.didReceive(URLResponse(
            url: url,
            mimeType: resource.mimeType,
            expectedContentLength: resource.data.count,
            textEncodingName: nil
        ))
        urlSchemeTask.didReceive(resource.data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}

    private static func decode(dataURL: String) -> (mimeType: String, data: Data)? {
        guard dataURL.hasPrefix("data:"), let comma = dataURL.firstIndex(of: ",") else { return nil }
        let header = dataURL[dataURL.index(dataURL.startIndex, offsetBy: 5)..<comma]
        let parts = header.split(separator: ";")
        guard let mimeType = parts.first.map(String.init),
              parts.dropFirst().contains(where: { $0.lowercased() == "base64" }),
              let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])) else { return nil }
        return (mimeType, data)
    }
}
