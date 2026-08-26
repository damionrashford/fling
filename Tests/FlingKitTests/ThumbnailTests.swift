import XCTest
@testable import FlingKit

final class ThumbnailTests: XCTestCase {

    // MARK: - video id extraction

    func test_extracts_id_from_watch_url() {
        XCTAssertEqual(URLClassifier.youTubeVideoID("https://www.youtube.com/watch?v=gCcx85zbxz4"),
                       "gCcx85zbxz4")
    }

    func test_extracts_id_when_other_query_params_present() {
        XCTAssertEqual(URLClassifier.youTubeVideoID("https://www.youtube.com/watch?t=90&v=abc123XYZ_-"),
                       "abc123XYZ_-")
    }

    func test_extracts_id_from_short_link() {
        XCTAssertEqual(URLClassifier.youTubeVideoID("https://youtu.be/gCcx85zbxz4"), "gCcx85zbxz4")
    }

    func test_extracts_id_from_short_link_with_timestamp() {
        XCTAssertEqual(URLClassifier.youTubeVideoID("https://youtu.be/gCcx85zbxz4?t=42"), "gCcx85zbxz4")
    }

    func test_extracts_id_from_embed_url() {
        XCTAssertEqual(URLClassifier.youTubeVideoID("https://www.youtube.com/embed/gCcx85zbxz4"),
                       "gCcx85zbxz4")
    }

    func test_extracts_id_from_shorts_url() {
        XCTAssertEqual(URLClassifier.youTubeVideoID("https://www.youtube.com/shorts/gCcx85zbxz4"),
                       "gCcx85zbxz4")
    }

    func test_youtube_home_page_has_no_video_id() {
        XCTAssertNil(URLClassifier.youTubeVideoID("https://www.youtube.com"))
    }

    func test_non_youtube_url_has_no_video_id() {
        XCTAssertNil(URLClassifier.youTubeVideoID("https://vimeo.com/123456"))
    }

    // MARK: - thumbnail

    func test_youtube_tab_exposes_a_thumbnail() {
        let tab = TabRef(url: "https://www.youtube.com/watch?v=gCcx85zbxz4",
                         title: "T", browser: .chrome)
        XCTAssertEqual(tab.thumbnailURL?.absoluteString,
                       "https://img.youtube.com/vi/gCcx85zbxz4/hqdefault.jpg")
    }

    /// Rule 1 still holds for everything else — no thumbnail means the panel
    /// reserves no space for one.
    func test_non_youtube_tab_has_no_thumbnail() {
        let tab = TabRef(url: "https://news.ycombinator.com", title: "HN", browser: .chrome)
        XCTAssertNil(tab.thumbnailURL)
    }

    func test_bundle_identifiers_are_the_real_ones() {
        XCTAssertEqual(Browser.chrome.bundleIdentifier, "com.google.Chrome")
        XCTAssertEqual(Browser.safari.bundleIdentifier, "com.apple.Safari")
    }
}
