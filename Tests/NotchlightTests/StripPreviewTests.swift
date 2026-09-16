import SwiftUI
import BorderOverlay
import Testing
@testable import Notchlight

struct StripPreviewTests {
    @Test("notch preview outset preserves the top edge")
    func asymmetricNotchOutset() {
        let base = PreviewNotchShape().path(in: CGRect(x: 0, y: 0, width: 156, height: 34)).cgPath
        let outset = PreviewNotchShape(outset: 6).path(in: CGRect(x: 0, y: 0, width: 156, height: 34)).cgPath
        #expect(base.boundingBoxOfPath.minY == 0)
        #expect(outset.boundingBoxOfPath.minY == 0)
        #expect(outset.boundingBoxOfPath.minX < base.boundingBoxOfPath.minX)
        #expect(outset.boundingBoxOfPath.maxX > base.boundingBoxOfPath.maxX)
        #expect(outset.boundingBoxOfPath.maxY > base.boundingBoxOfPath.maxY)
    }

    @Test("preview ticks retain all five markers for an empty progress range")
    func allMarkersRemainVisible() {
        let shape = BorderStripMarkerShape(
            style: BorderStripStyle(isEnabled: true, thickness: 1.5, length: 8, offset: 0, topPadding: 2),
            outset: 2
        )
        var moveCount = 0
        shape.path(in: CGRect(x: 0, y: 0, width: 156, height: 34)).cgPath.applyWithBlock { element in
            if element.pointee.type == .moveToPoint { moveCount += 1 }
        }
        #expect(moveCount == 5)
    }
}
