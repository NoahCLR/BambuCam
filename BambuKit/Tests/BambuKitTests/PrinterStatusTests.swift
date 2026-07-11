import Foundation
import Testing
@testable import BambuKit

@Suite struct StatusAccumulatorTests {
    @Test func fullReportDecodes() throws {
        var acc = StatusAccumulator()
        let msg = #"{"print":{"nozzle_temper":219.5,"nozzle_target_temper":220.0,"bed_temper":55.0,"bed_target_temper":55.0,"layer_num":42,"total_layer_num":128,"mc_percent":63,"mc_print_stage":"2","mc_remaining_time":37,"gcode_state":"RUNNING","lights_report":[{"node":"chamber_light","mode":"on"}]}}"#
        let status = acc.ingest(Data(msg.utf8))
        #expect(status != nil)
        #expect(status?.nozzleTemper == 219.5)
        #expect(status?.nozzleTargetTemper == 220.0)
        #expect(status?.bedTemper == 55.0)
        #expect(status?.bedTargetTemper == 55.0)
        #expect(status?.layerNum == 42)
        #expect(status?.totalLayerNum == 128)
        #expect(status?.mcPercent == 63)
        #expect(status?.mcPrintStage == "2")
        #expect(status?.mcRemainingTime == 37)
        #expect(status?.gcodeState == "RUNNING")
        #expect(status?.lightOn == true)
    }

    @Test func partialReportMergesOverPrevious() throws {
        var acc = StatusAccumulator()
        _ = acc.ingest(Data(#"{"print":{"nozzle_temper":220.0,"mc_percent":10,"gcode_state":"RUNNING"}}"#.utf8))
        let status = acc.ingest(Data(#"{"print":{"mc_percent":11}}"#.utf8))
        #expect(status != nil)
        #expect(status?.mcPercent == 11)
        #expect(status?.nozzleTemper == 220.0)      // retained from earlier report
        #expect(status?.gcodeState == "RUNNING")    // retained
    }

    @Test func intTemperatureDecodesAsDouble() throws {
        var acc = StatusAccumulator()
        let status = acc.ingest(Data(#"{"print":{"nozzle_temper":220}}"#.utf8))
        #expect(status != nil)
        #expect(status?.nozzleTemper == 220.0)
    }

    @Test func lightReportAcceptsCameraLightFallback() throws {
        var acc = StatusAccumulator()
        let status = acc.ingest(Data(#"{"print":{"lights_report":[{"node":"camera_light","mode":"off"}]}}"#.utf8))
        #expect(status != nil)
        #expect(status?.lightOn == false)
    }

    @Test func lightReportPersistsAcrossPartialReports() throws {
        var acc = StatusAccumulator()
        _ = acc.ingest(Data(#"{"print":{"lights_report":[{"node":"chamber_light","mode":"on"}]}}"#.utf8))
        let status = acc.ingest(Data(#"{"print":{"bed_temper":29.2}}"#.utf8))
        #expect(status != nil)
        #expect(status?.lightOn == true)
        #expect(status?.bedTemper == 29.2)
    }

    @Test func directLedControlMessageUpdatesLightState() throws {
        var acc = StatusAccumulator()
        let status = acc.ingest(Data(#"{"system":{"command":"ledctrl","led_node":"chamber_light","led_mode":"on"}}"#.utf8))
        #expect(status != nil)
        #expect(status?.lightOn == true)
    }

    @Test func nonReportMessageReturnsNil() {
        var acc = StatusAccumulator()
        #expect(acc.ingest(Data(#"{"system":{"command":"ledctrl"}}"#.utf8)) == nil)
        #expect(acc.ingest(Data("not json".utf8)) == nil)
    }

    @Test func unknownKeysIgnored() throws {
        var acc = StatusAccumulator()
        let status = acc.ingest(Data(#"{"print":{"wifi_signal":"-40dBm","mc_percent":5}}"#.utf8))
        #expect(status != nil)
        #expect(status?.mcPercent == 5)
    }
}
