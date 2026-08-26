import XCTest
@testable import FlingKit

final class URLClassifierTests: XCTestCase {

    func test_nil_is_not_castable() {
        guard case .notCastable(let reason) = URLClassifier.classify(nil) else {
            return XCTFail("expected notCastable")
        }
        XCTAssertEqual(reason, "No page open")
    }

    func test_empty_string_is_not_castable() {
        guard case .notCastable = URLClassifier.classify("") else {
            return XCTFail("expected notCastable")
        }
    }

    // JXA returns the literal string "missing value" for an unset property.
    func test_missing_value_sentinel_is_not_castable() {
        guard case .notCastable = URLClassifier.classify("missing value") else {
            return XCTFail("expected notCastable")
        }
    }

    func test_non_http_scheme_is_not_castable() {
        guard case .notCastable = URLClassifier.classify("file:///Users/x/a.mp4") else {
            return XCTFail("expected notCastable")
        }
    }

    func test_youtube_watch_url() {
        XCTAssertEqual(URLClassifier.classify("https://www.youtube.com/watch?v=abc123"), .youtube)
    }

    func test_youtube_short_url() {
        XCTAssertEqual(URLClassifier.classify("https://youtu.be/abc123"), .youtube)
    }

    func test_youtube_music_is_youtube() {
        XCTAssertEqual(URLClassifier.classify("https://music.youtube.com/watch?v=abc"), .youtube)
    }

    func test_direct_mp4() {
        XCTAssertEqual(URLClassifier.classify("https://ex.com/a/b.mp4"), .directMedia)
    }

    func test_hls_manifest() {
        XCTAssertEqual(URLClassifier.classify("https://ex.com/live/x.m3u8"), .directMedia)
    }

    func test_dash_manifest() {
        XCTAssertEqual(URLClassifier.classify("https://ex.com/live/x.mpd"), .directMedia)
    }

    func test_media_url_with_query_string_still_direct() {
        XCTAssertEqual(URLClassifier.classify("https://ex.com/a.mp4?token=xyz&t=9"), .directMedia)
    }

    func test_uppercase_extension_still_direct() {
        XCTAssertEqual(URLClassifier.classify("https://ex.com/A.MP4"), .directMedia)
    }

    func test_known_extractable_site() {
        XCTAssertEqual(URLClassifier.classify("https://vimeo.com/123456"), .extractableSite)
    }

    func test_plain_web_page_is_not_castable() {
        guard case .notCastable(let reason) = URLClassifier.classify("https://news.ycombinator.com") else {
            return XCTFail("expected notCastable")
        }
        XCTAssertEqual(reason, "Not a video page")
    }
}
