import CoreAudio
@testable import HSAudio
import HSCore
import XCTest

final class ChannelMapTests: XCTestCase {
    // An unknown device ID makes the preferred-pair query fall back to (1, 2).
    let noDevice = AudioObjectID(kAudioObjectUnknown)
    let L = Int8(HS_SRC_LEFT), R = Int8(HS_SRC_RIGHT), Z = Int8(HS_SRC_ZERO), M = Int8(HS_SRC_MONO)

    func testEmptyLayoutDoesNotCrash() { XCTAssertEqual(TapManager.outputChannelMap(outputDevice: noDevice, layout: []), [Z]) }
    func testMonoDeviceGetsSum() { XCTAssertEqual(TapManager.outputChannelMap(outputDevice: noDevice, layout: [1]), [M]) }
    func testStereo() { XCTAssertEqual(TapManager.outputChannelMap(outputDevice: noDevice, layout: [2]), [L, R]) }
    func testMultichannelSplitBuffers() {
        XCTAssertEqual(TapManager.outputChannelMap(outputDevice: noDevice, layout: [1, 1, 1, 1]), [L, R, Z, Z])
    }
}
