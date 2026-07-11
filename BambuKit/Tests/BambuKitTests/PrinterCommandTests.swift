import Testing
@testable import BambuKit

// Payloads match the local P1-series command protocol used by the app.
@Suite struct PrinterCommandTests {
    @Test func pausePayload() {
        #expect(PrinterCommand.pause.payload ==
            #"{"print": { "sequence_id": 1, "command": "pause"}, "user_id":"1234567890"}"#)
    }
    @Test func resumePayload() {
        #expect(PrinterCommand.resume.payload ==
            #"{"print": { "sequence_id": 2, "command": "resume"}, "user_id":"1234567890"}"#)
    }
    @Test func stopPayload() {
        #expect(PrinterCommand.stop.payload ==
            #"{"print": { "sequence_id": 3, "command": "stop"}, "user_id":"1234567890"}"#)
    }
    @Test func lightOnPayload() {
        #expect(PrinterCommand.light(on: true).payload ==
            #"{"system": {"sequence_id": "0", "command": "ledctrl", "led_node": "chamber_light", "led_mode": "on", "led_on_time": 500, "led_off_time": 500, "loop_times": 0, "interval_time": 0}, "user_id":"1234567890"}"#)
    }
    @Test func lightOffPayload() {
        #expect(PrinterCommand.light(on: false).payload ==
            #"{"system": {"sequence_id": "0", "command": "ledctrl", "led_node": "chamber_light", "led_mode": "off", "led_on_time": 500, "led_off_time": 500, "loop_times": 0, "interval_time": 0}, "user_id":"1234567890"}"#)
    }
    @Test(arguments: PrinterCommand.PrintSpeed.allCases)
    func speedPayload(speed: PrinterCommand.PrintSpeed) {
        #expect(PrinterCommand.speed(speed).payload ==
            #"{"print": {"sequence_id":"2004","command":"print_speed","param":"\#(speed.rawValue)"},"user_id":"1234567890"}"#)
    }
}
