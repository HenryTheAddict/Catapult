//
//  CatapultTests.swift
//  CatapultTests
//
//  Created by Henry Perzinski on 4/19/26.
//

import Testing
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

}
