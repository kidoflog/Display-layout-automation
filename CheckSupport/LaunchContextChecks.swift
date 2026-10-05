import Foundation
import CoreServices

@main struct LaunchContextChecks {
    static func main() {
        precondition(!LaunchContext.isLoginLaunch(nil), "直接起動では画面を表示")
        let normal = makeEvent(kAEOpenApplication)
        precondition(!LaunchContext.isLoginLaunch(normal), "通常起動では画面を表示")
        normal.setParam(NSAppleEventDescriptor(typeCode: keyAELaunchedAsLogInItem),
                        forKeyword: keyAEPropData)
        precondition(LaunchContext.isLoginLaunch(normal), "ログインの印があれば画面を隠す")
        let reopen = makeEvent(kAEReopenApplication)
        reopen.setParam(NSAppleEventDescriptor(typeCode: keyAELaunchedAsLogInItem),
                        forKeyword: keyAEPropData)
        precondition(!LaunchContext.isLoginLaunch(reopen), "起動以外のイベントはログイン扱いしない")
        let otherClass = NSAppleEventDescriptor(eventClass: AEEventClass(0),
            eventID: AEEventID(kAEOpenApplication), targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        otherClass.setParam(NSAppleEventDescriptor(typeCode: keyAELaunchedAsLogInItem),
                            forKeyword: keyAEPropData)
        precondition(!LaunchContext.isLoginLaunch(otherClass), "別クラスのイベントはログイン扱いしない")
        print("LaunchContextChecks: all checks passed")
    }

    private static func makeEvent(_ id: AEEventID) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: id,
            targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID))
    }
}
