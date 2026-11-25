import Foundation
import Orion

struct AdSkipperGroup: HookGroup {}

// Dedicated player observer so ad skipping does not depend on SponsorBlock
// being enabled (or on its hook attaching successfully).
@objc final class EeveeAdPlayerObserver: NSObject {
    @objc func player(_ player: AnyObject, stateDidChange newState: AnyObject) {
        AdSkipper.shared.processStateChange(player: player, state: newState)
    }

    @objc func player(_ player: AnyObject, stateDidChange newState: AnyObject, fromState oldState: AnyObject) {
        AdSkipper.shared.processStateChange(player: player, state: newState)
    }
}

private var adObserverRegistered = false
private let adObserver = EeveeAdPlayerObserver()

class AdSkipperObserverHook: ClassHook<NSObject> {
    typealias Group = AdSkipperGroup
    static let targetName = "SPTPlayerServiceImplementation"

    func addPlayerObserver(_ observer: AnyObject) {
        orig.addPlayerObserver(observer)
        if !adObserverRegistered {
            adObserverRegistered = true
            writeDebugLog("[AdSkip] registered player observer")
            orig.addPlayerObserver(adObserver)
        }
    }
}

func activateAdSkipper() {
    guard NSClassFromString("SPTPlayerServiceImplementation") != nil else {
        writeDebugLog("[AdSkip] SPTPlayerServiceImplementation missing; skipping activation")
        return
    }
    AdSkipperGroup().activate()
    writeDebugLog("[AdSkip] activated player-state ad skipper")
}
