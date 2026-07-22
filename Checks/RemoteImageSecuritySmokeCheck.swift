import Foundation

@main
enum RemoteImageSecuritySmokeCheck {
    static func main() throws {
        let html = """
        <html><head>
          <style>
            .hero { background-image: url('https://styles.example/hero.png'); }
            @font-face { src: url(https://fonts.example/tracker.woff2); }
          </style>
          <script src="https://scripts.example/run.js">fetch('https://connections.example')</script>
        </head><body>
          <img src="https://images.example/pixel.png">
          <img srcset="https://images.example/small.png 1x, https://retina.example/large.png 2x">
          <img src="http://insecure.example/pixel.png">
          <img src="cid:local-image">
          <iframe src="https://frames.example/content"></iframe>
          <form action="https://forms.example/submit"><input name="secret"></form>
          <video src="https://media.example/movie.mp4"></video>
          <object data="https://objects.example/object"></object>
        </body></html>
        """

        let policy = RemoteImagePolicy.inspect(html)
        try require(policy.httpsOrigins == [
            "https://images.example",
            "https://retina.example",
            "https://styles.example"
        ], "only HTTPS image origins are discovered")
        try require(policy.insecureHTTPResourceCount == 1, "HTTP image is reported")
        try require(policy.hasRemoteImages, "remote images are detected")

        let blocked = HTMLMessageView.securedDocument(containing: html)
        try require(blocked.contains("img-src data: olm-inline-image:;"), "remote images are blocked by default")
        try require(!blocked.contains("img-src data: olm-inline-image: https://"), "default CSP has no remote image source")

        let approved = HTMLMessageView.securedDocument(
            containing: html,
            allowedRemoteImageOrigins: policy.httpsOrigins
        )
        try require(
            approved.contains("img-src data: olm-inline-image: https://images.example https://retina.example https://styles.example;"),
            "approved HTTPS image origins enter CSP"
        )
        for forbidden in [
            "scripts.example", "frames.example", "forms.example", "media.example",
            "objects.example", "connections.example", "fonts.example", "insecure.example"
        ] {
            try require(!csp(in: approved).contains(forbidden), "\(forbidden) stays outside CSP")
        }
        for directive in [
            "script-src 'none'", "media-src 'none'", "frame-src 'none'", "child-src 'none'",
            "connect-src 'none'", "object-src 'none'", "base-uri 'none'", "form-action 'none'",
            "manifest-src 'none'", "worker-src 'none'"
        ] {
            try require(csp(in: approved).contains(directive), "CSP retains \(directive)")
        }
        try require(approved.contains("name=\"referrer\" content=\"no-referrer\""), "referrer suppression")
        let injectionAttempt = HTMLMessageView.securedDocument(
            containing: html,
            allowedRemoteImageOrigins: ["https://images.example; connect-src *", "http://insecure.example"]
        )
        try require(csp(in: injectionAttempt).contains("img-src data: olm-inline-image:;"), "invalid CSP sources are rejected")

        let localDataURL = "data:image/png;base64,c3ludGhldGlj"
        let resolved = HTMLMessageView.resolvingInlineImages(
            in: "<img src=\"cid:local-image\"><img src=\"CID:&lt;other&gt;\">",
            images: ["local-image": localDataURL]
        )
        try require(resolved.contains("olm-inline-image://resource/"), "local cid image resolves")
        try require(!resolved.contains(localDataURL), "local attachment bytes stay outside message HTML")
        try require(resolved.contains("CID:&lt;other&gt;"), "unmatched cid remains unresolved")
        try require(csp(in: approved).contains("img-src data: olm-inline-image:"), "local images remain allowed")

        let archiveSessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let first = MessageRemoteContentIdentity(
            archiveSessionID: archiveSessionID,
            messageID: "message-1",
            folderID: "folder-a"
        )
        let second = MessageRemoteContentIdentity(
            archiveSessionID: archiveSessionID,
            messageID: "message-2",
            folderID: "folder-a"
        )
        var approval = RemoteImageApprovalState()
        try require(!approval.isApproved(for: first), "approval starts blocked")
        approval.approve(first)
        try require(approval.isApproved(for: first), "current message is approved")
        try require(!approval.isApproved(for: second), "approval does not cover another message")
        approval.selectionChanged(to: second)
        try require(!approval.isApproved(for: first) && !approval.isApproved(for: second), "selection change resets approval")
        approval.approve(second)
        let reopenedSecond = MessageRemoteContentIdentity(
            archiveSessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            messageID: second.messageID,
            folderID: second.folderID
        )
        approval.selectionChanged(to: reopenedSecond)
        try require(!approval.isApproved(for: reopenedSecond), "approval does not cross archive sessions")
        approval.approve(second)
        approval.block()
        try require(!approval.isApproved(for: second), "images can be blocked again")

        print("Remote image security smoke check passed")
    }

    private static func csp(in document: String) -> String {
        document.components(separatedBy: "Content-Security-Policy\" content=\"").dropFirst().first?
            .components(separatedBy: "\">").first ?? ""
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ description: String) throws {
        guard condition() else { throw CheckFailure("Failed: \(description)") }
    }
}

private struct CheckFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
