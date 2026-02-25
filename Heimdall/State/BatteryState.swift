import Foundation

@Observable
class BatteryState {
    var battery = BatteryInfo()

    func apply(_ result: BatteryReaderResult) {
        battery = result.battery
    }
}
