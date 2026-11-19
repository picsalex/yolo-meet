import Foundation
import Testing

@testable import YoloMeetCore

/// GitHub's and PyPI's answers are read, checked and written as the stage shows them, offline (no request is made).
@MainActor @Suite struct ProjectStatsTests {
    @Test func readsGitHub() throws {
        let json = #"{"full_name": "ultralytics/ultralytics", "stargazers_count": 63612, "forks_count": 12034}"#
        let counts = try #require(ProjectStats.parseRepository(Data(json.utf8)))
        #expect(counts.stars == 63612 && counts.forks == 12034)
        #expect(ProjectStats.parseRepository(Data(#"{"message": "API rate limit exceeded"}"#.utf8)) == nil)
    }

    @Test func readsPyPI() throws {
        let json = #"""
            {"info": {"version": "8.4.216", "name": "ultralytics"},
             "urls": [
               {"filename": "ultralytics-8.4.216.tar.gz", "packagetype": "sdist", "size": 900000},
               {"filename": "ultralytics-8.4.216-py3-none-any.whl", "packagetype": "bdist_wheel", "size": 1043210}
             ]}
            """#
        let release = try #require(ProjectStats.parsePackage(Data(json.utf8)))
        #expect(release.version == "8.4.216" && release.wheelBytes == 1_043_210)
        #expect(ProjectStats.parsePackage(Data(#"{"info": {"version": "1.0"}, "urls": []}"#.utf8)) == nil)
    }

    @Test func rejectsOddNumbers() {
        let good = ProjectStats.Snapshot(stars: 63_600, forks: 12_000, version: "8.4.215", wheelBytes: 1_500_000)
        #expect(ProjectStats.checked(good) == good)
        for version in ["8.4.215rc1", "8", "8..1", "<b>8</b>", "8.4.215 ", "１.２"] {
            var odd = good
            odd.version = version
            #expect(ProjectStats.checked(odd) == nil, "\(version)")
        }
        var odd = good
        odd.stars = -1
        #expect(ProjectStats.checked(odd) == nil)
        odd = good
        odd.wheelBytes = 500_000_000
        #expect(ProjectStats.checked(odd) == nil)
    }

    @Test func writesCountsAsGitHub() {
        let cases = [
            (999, "999"), (1000, "1k"), (12_034, "12k"), (63_612, "63.6k"), (63_660, "63.7k"), (112_400, "112k"),
            (999_400, "999k"), (999_600, "1m"), (1_240_000, "1.2m"),
        ]
        for (n, text) in cases { #expect(ProjectStats.compact(n) == text, "\(n)") }
    }

    /// GitHub's and PyPI's real answers, only with `YOLO_MEET_LIVE_NUMBERS=1` (two requests to each; GitHub allows 60 an
    /// hour without a token).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["YOLO_MEET_LIVE_NUMBERS"] != nil))
    func fetchesLive() async throws {
        let defaults = try #require(UserDefaults(suiteName: "ProjectStatsLiveTests"))
        defer { defaults.removePersistentDomain(forName: "ProjectStatsLiveTests") }
        let fallback = ProjectStats.Snapshot(stars: 1, forks: 1, version: "1.0", wheelBytes: 20_000)
        let stats = ProjectStats(
            repository: "ultralytics/ultralytics", package: "ultralytics", fallback: fallback, defaults: defaults)
        #expect(await stats.refresh())
        #expect(stats.current.stars > 50_000 && stats.current.forks > 10_000 && stats.current.fetched != nil)
        // An answer longer than the limit is given up.
        let pypi = "https://pypi.org/pypi/ultralytics/json"
        let tiny = await ProjectStats.get(pypi, accept: "application/json", limit: 10_000) { $0.count }
        #expect(tiny == nil)
    }

    @Test func keepsNumbersBetweenLaunches() throws {
        let defaults = try #require(UserDefaults(suiteName: "ProjectStatsTests"))
        defer { defaults.removePersistentDomain(forName: "ProjectStatsTests") }
        let fallback = ProjectStats.Snapshot(stars: 1, forks: 1, version: "1.0", wheelBytes: 20_000)
        let kept = ProjectStats.Snapshot(stars: 5, forks: 2, version: "2.0.1", wheelBytes: 30_000, fetched: .now)
        defaults.set(try JSONEncoder().encode(kept), forKey: "ProjectStats.a/b.b")
        #expect(ProjectStats(repository: "a/b", package: "b", fallback: fallback, defaults: defaults).current == kept)
        #expect(
            ProjectStats(repository: "c/d", package: "d", fallback: fallback, defaults: defaults).current == fallback)
    }
}
