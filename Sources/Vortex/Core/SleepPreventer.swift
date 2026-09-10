import Foundation
import IOKit.pwr_mgt

public final class SleepPreventer: @unchecked Sendable {
    public static let shared = SleepPreventer()

    private let lock = NSLock()
    private var assertionID: IOPMAssertionID = 0
    private var activeCount: Int = 0

    private init() {}

    public func retainSleepAssertion(reason: String = "Vortex Active Downloads") {
        lock.lock()
        defer { lock.unlock() }

        activeCount += 1
        if activeCount == 1 {
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertPreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason as CFString,
                &assertionID
            )
            if result == kIOReturnSuccess {
                print("[Vortex] Sleep assertion acquired: Mac will stay awake during download.")
            } else {
                print("[Vortex] Failed to acquire sleep assertion: \(result)")
            }
        }
    }

    public func releaseSleepAssertion() {
        lock.lock()
        defer { lock.unlock() }

        guard activeCount > 0 else { return }
        activeCount -= 1

        if activeCount == 0 && assertionID != 0 {
            let result = IOPMAssertionRelease(assertionID)
            assertionID = 0
            if result == kIOReturnSuccess {
                print("[Vortex] Sleep assertion released.")
            }
        }
    }

    public var isHoldingAssertion: Bool {
        lock.lock()
        defer { lock.unlock() }
        return assertionID != 0
    }
}
