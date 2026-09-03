//
//  CatapultTests.swift
//  CatapultTests
//
//  Created by Henry Perzinski on 4/19/26.
//

import Testing
import Foundation
@testable import Catapult

struct CatapultTests {

    @Test func detectsKnownSocialLinksBeforeGenericLinks() async throws {
        let text = "read this https://example.com first, then grab https://www.instagram.com/reel/ABC123/?utm_source=copy-link"
        let picked = await MainActor.run { ClipboardMonitor.firstDownloadURL(in: text) }
        #expect(picked == "https://www.instagram.com/reel/ABC123/?utm_source=copy-link")
    }

    @Test func trimsCommonCopiedLinkPunctuation() async throws {
        let picked = await MainActor.run {
            ClipboardMonitor.firstDownloadURL(in: "watch: https://www.tiktok.com/@catapult/video/12345).")
        }
        #expect(picked == "https://www.tiktok.com/@catapult/video/12345")
    }

    @Test func fallsBackToGenericYtDlpURL() async throws {
        let picked = await MainActor.run {
            ClipboardMonitor.firstDownloadURL(in: "https://example.com/media/clip")
        }
        #expect(picked == "https://example.com/media/clip")
    }

    @Test func heliumCookieBridgeExport() async throws {
        let file = HeliumCookieBridge.exportCookieFile(maxAge: 0)
        print("Exported helium cookie file:", String(describing: file))
        if let file {
            let content = try? String(contentsOf: file)
            print("Exported cookies count:", content?.components(separatedBy: "\n").filter { !$0.hasPrefix("#") && !$0.isEmpty }.count ?? 0)
        }
    }

    @Test func defaultConcurrentFragmentsIsEight() async throws {
        let defaultFragments = await MainActor.run {
            AppSettings.shared.concurrentFragments
        }
        #expect(defaultFragments >= 8)
    }

    @Test func enhancedEnvironmentIncludesToolPaths() async throws {
        let env = DependencyManager.enhancedEnvironment
        let path = env["PATH"] ?? ""
        #expect(path.contains("/opt/homebrew/bin"))
        #expect(path.contains("/usr/local/bin"))
        #expect(path.contains(".deno/bin"))
    }

    @Test func cookieSourceResolution() async throws {
        await MainActor.run {
            let s = AppSettings.shared
            let oldSource = s.cookieSource
            let oldSites = s.siteCookies

            s.cookieSource = .safari
            s.siteCookies = [SupportedSite.youtube]

            #expect(s.cookieSource(for: "https://www.youtube.com/watch?v=dQw4w9WgXcQ") == .safari)
            // Generic sites receive the global cookie source when enabled
            #expect(s.cookieSource(for: "https://customdomain.org/video.mp4") == .safari)
            // Un-toggled supported sites do not receive it
            #expect(s.cookieSource(for: "https://www.tiktok.com/@user/video/12345") == .off)

            // When cookieSource is off, nothing receives cookies
            s.cookieSource = .off
            #expect(s.cookieSource(for: "https://www.youtube.com/watch?v=dQw4w9WgXcQ") == .off)
            #expect(s.cookieSource(for: "https://customdomain.org/video.mp4") == .off)

            // Restore original settings
            s.cookieSource = oldSource
            s.siteCookies = oldSites
        }
    }

    @Test func friendlyErrorMapping() async throws {
        let botCheck = DownloadManager.friendlyError(for: "Sign in to confirm you’re not a bot. This helps protect our community.")
        #expect(botCheck.contains("bot") || botCheck.contains("Cookies") || botCheck.contains("sign into") || botCheck.contains("signed in"))

        let ageGated = DownloadManager.friendlyError(for: "Sign in to confirm your age. This video may be inappropriate for some users.")
        #expect(ageGated.contains("age") || ageGated.contains("Cookies") || ageGated.contains("Settings") || ageGated.contains("signed in"))

        let formatErr = DownloadManager.friendlyError(for: "ERROR: Requested format is not available")
        #expect(formatErr.contains("format") || formatErr.contains("quality") || formatErr.contains("yt-dlp"))
    }

}
