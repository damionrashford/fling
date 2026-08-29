import XCTest
@testable import FlingKit

final class CastPlannerTests: XCTestCase {

    private func tab(_ url: String) -> TabRef {
        TabRef(url: url, title: "t", browser: .chrome)
    }

    private func media(stream: String? = nil, resume: Double? = nil,
                       duration: Double? = nil, playing: Bool = true) -> TabMedia {
        TabMedia(streamURL: stream, resumeAt: resume, duration: duration, isPlaying: playing)
    }

    // MARK: YouTube — receiver keeps the page URL, seek attaches

    func test_youtube_keeps_page_url_and_kind_with_seek() {
        let t = tab("https://www.youtube.com/watch?v=abc")
        let plan = CastPlanner.plan(tab: t, media: media(stream: "https://cdn/vid.mp4", resume: 300))
        XCTAssertEqual(plan, CastPlan(url: t.url, kind: .youtube, seekTo: 300))
    }

    func test_youtube_without_probe_has_no_seek() {
        let t = tab("https://youtu.be/abc")
        XCTAssertEqual(CastPlanner.plan(tab: t, media: nil),
                       CastPlan(url: t.url, kind: .youtube, seekTo: nil))
    }

    // MARK: direct stream

    func test_castable_stream_becomes_directMedia_with_seek() {
        let t = tab("https://vimeo.com/123")
        let plan = CastPlanner.plan(tab: t, media: media(stream: "https://a/master.m3u8", resume: 42))
        XCTAssertEqual(plan, CastPlan(url: "https://a/master.m3u8", kind: .directMedia, seekTo: 42))
    }

    func test_plain_http_stream_is_castable_too() {
        let t = tab("https://example.com/page")
        let plan = CastPlanner.plan(tab: t, media: media(stream: "http://cdn/movie.mp4", resume: 60))
        XCTAssertEqual(plan, CastPlan(url: "http://cdn/movie.mp4", kind: .directMedia, seekTo: 60))
    }

    // MARK: blob-only fallback

    func test_blob_only_falls_back_to_castable_tab_kind_with_seek() {
        let t = tab("https://vimeo.com/123")   // .extractableSite
        let plan = CastPlanner.plan(tab: t, media: media(stream: nil, resume: 90))
        XCTAssertEqual(plan, CastPlan(url: t.url, kind: .extractableSite, seekTo: 90))
    }

    func test_blob_only_on_notCastable_tab_drops_seek() {
        let t = tab("https://example.com/page")
        let plan = CastPlanner.plan(tab: t, media: media(stream: nil, resume: 90))
        XCTAssertEqual(plan.url, t.url)
        XCTAssertEqual(plan.kind, t.kind)
        XCTAssertNil(plan.seekTo)
        XCTAssertFalse(plan.kind.isCastable)
    }

    func test_blob_streamURL_is_never_cast_directly() {
        // A hand-built TabMedia carrying a blob: URL must not become the plan.
        let t = tab("https://vimeo.com/123")
        let plan = CastPlanner.plan(tab: t, media: media(stream: "blob:https://site/xyz", resume: 90))
        XCTAssertEqual(plan, CastPlan(url: t.url, kind: .extractableSite, seekTo: 90))
    }

    // MARK: no media

    func test_no_media_falls_back_to_tab_with_no_seek() {
        let t = tab("https://vimeo.com/123")
        XCTAssertEqual(CastPlanner.plan(tab: t, media: nil),
                       CastPlan(url: t.url, kind: .extractableSite, seekTo: nil))
    }

    // MARK: 5-second gate holds even for hand-built media

    func test_resume_under_five_seconds_never_propagates() {
        let t = tab("https://vimeo.com/123")
        let plan = CastPlanner.plan(tab: t, media: media(stream: "https://a/m.m3u8", resume: 3))
        XCTAssertNil(plan.seekTo)

        let yt = tab("https://www.youtube.com/watch?v=abc")
        XCTAssertNil(CastPlanner.plan(tab: yt, media: media(resume: 4.9)).seekTo)
    }
}
