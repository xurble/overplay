import AVFoundation
import Testing
@testable import Overplay

@Suite("Audio output pill")
struct AudioOutputPresentationTests {
    @Test("the built-in speaker is named for the device")
    func builtInSpeakerUsesDeviceName() {
        let ports = [AudioOutputPort(type: .builtInSpeaker, name: "Speaker")]
        #expect(AudioOutputPresentation.name(for: ports, deviceName: "iPhone") == "iPhone Speaker")
        #expect(AudioOutputPresentation.name(for: ports, deviceName: "iPad") == "iPad Speaker")
    }

    @Test("no reported output falls back to the device speaker")
    func emptyRouteIsDeviceSpeaker() {
        #expect(AudioOutputPresentation.name(for: [], deviceName: "iPhone") == "iPhone Speaker")
    }

    @Test("wired headphones are named generically")
    func wiredHeadphones() {
        let ports = [AudioOutputPort(type: .headphones, name: "Headphones Port")]
        #expect(AudioOutputPresentation.name(for: ports, deviceName: "iPhone") == "Headphones")
    }

    @Test("AirPlay and Bluetooth outputs keep the system's name")
    func namedOutputs() {
        #expect(AudioOutputPresentation.name(
            for: [AudioOutputPort(type: .airPlay, name: "Big Tee Vee")], deviceName: "iPhone"
        ) == "Big Tee Vee")
        #expect(AudioOutputPresentation.name(
            for: [AudioOutputPort(type: .bluetoothA2DP, name: "AirPods Pro ")], deviceName: "iPhone"
        ) == "AirPods Pro")
        #expect(AudioOutputPresentation.name(
            for: [AudioOutputPort(type: .airPlay, name: " ")], deviceName: "iPhone"
        ) == "Audio Output")
    }

    @Test("several outputs are named by the first, without repeats")
    func groupedOutputs() {
        let ports = [
            AudioOutputPort(type: .airPlay, name: "Kitchen"),
            AudioOutputPort(type: .airPlay, name: "Living Room"),
            AudioOutputPort(type: .airPlay, name: "Kitchen"),
        ]
        #expect(AudioOutputPresentation.name(for: ports, deviceName: "iPhone") == "Kitchen + 1")
    }

    @Test("dragging the full width covers the whole range, clamped")
    func dragMapsWidthToRange() {
        #expect(AudioOutputPresentation.volume(from: 0.5, dragged: 100, across: 400) == 0.75)
        #expect(AudioOutputPresentation.volume(from: 0.5, dragged: -100, across: 400) == 0.25)
        #expect(AudioOutputPresentation.volume(from: 0.9, dragged: 400, across: 400) == 1)
        #expect(AudioOutputPresentation.volume(from: 0.1, dragged: -400, across: 400) == 0)
        #expect(AudioOutputPresentation.volume(from: 0.5, dragged: 100, across: 0) == 0.5)
    }

    @Test("VoiceOver adjusts in hardware button steps")
    func adjustableSteps() {
        #expect(AudioOutputPresentation.volume(0.5, steppedBy: 1) == 0.5625)
        #expect(AudioOutputPresentation.volume(0.5, steppedBy: -1) == 0.4375)
        // Snaps an in-between level to the nearest step before moving.
        #expect(AudioOutputPresentation.volume(0.51, steppedBy: 1) == 0.5625)
        #expect(AudioOutputPresentation.volume(1, steppedBy: 1) == 1)
        #expect(AudioOutputPresentation.volume(0, steppedBy: -1) == 0)
    }

    @Test("the volume is read as a whole percentage")
    func percentText() {
        #expect(AudioOutputPresentation.percentText(0.5) == "50 percent")
        #expect(AudioOutputPresentation.percentText(0.333) == "33 percent")
        #expect(AudioOutputPresentation.percentText(1.2) == "100 percent")
    }
}
