import Foundation
import IOKit.pwr_mgt

/// Inspects live macOS power assertions to identify processes preventing system sleep.
enum PowerAssertions {
    /// Returns the set of PIDs currently holding sleep-blocking assertions.
    static func sleepBlockerPids() -> Set<pid_t> {
        var assertionsByProcess: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&assertionsByProcess) == kIOReturnSuccess,
              let dict = assertionsByProcess?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else {
            return []
        }
        var blockers = Set<pid_t>()
        for (pidNum, assertions) in dict {
            for assertion in assertions {
                guard let type = assertion[kIOPMAssertionTypeKey as String] as? String else { continue }
                if type == "PreventUserIdleSystemSleep" ||
                   type == "PreventSystemSleep" ||
                   type == "NoIdleSleepAssertion" {
                    blockers.insert(pidNum.int32Value)
                    break
                }
            }
        }
        return blockers
    }
}
