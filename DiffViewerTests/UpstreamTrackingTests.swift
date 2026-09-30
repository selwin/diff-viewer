import Foundation
import Testing

@testable import DiffViewer

struct UpstreamTrackingTests {
    @Test(arguments: [
        (field: "", expected: UpstreamTracking.counts(ahead: 0, behind: 0)),
        (field: "gone", expected: .gone),
        (field: "ahead 7", expected: .counts(ahead: 7, behind: 0)),
        (field: "behind 2", expected: .counts(ahead: 0, behind: 2)),
        (field: "ahead 1, behind 2", expected: .counts(ahead: 1, behind: 2)),
        // Anything unrecognised reads as up to date, which shows nothing on the face.
        (field: "sideways 3", expected: .counts(ahead: 0, behind: 0)),
    ])
    func parsesGitsTrackField(field: String, expected: UpstreamTracking) {
        #expect(UpstreamTracking.parse(field) == expected)
    }

    @Test(arguments: [
        (tracking: UpstreamTracking.counts(ahead: 0, behind: 0), summary: String?.none),
        (tracking: .counts(ahead: 2, behind: 3), summary: "2 ahead · 3 behind"),
        (tracking: .counts(ahead: 3, behind: 0), summary: "3 ahead"),
        (tracking: .counts(ahead: 0, behind: 2), summary: "2 behind"),
        (tracking: .gone, summary: "upstream gone"),
    ])
    func summariesReadAheadFirst(tracking: UpstreamTracking, summary: String?) {
        #expect(tracking.summary == summary)
    }
}
