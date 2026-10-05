import Foundation
import CoreServices

enum LaunchContext {
    static func isLoginLaunch(_ event: NSAppleEventDescriptor?) -> Bool {
        guard let event,
              event.eventClass == AEEventClass(kCoreEventClass),
              event.eventID == AEEventID(kAEOpenApplication) else { return false }
        return event.paramDescriptor(forKeyword: keyAEPropData)?.typeCodeValue
            == keyAELaunchedAsLogInItem
    }
}
