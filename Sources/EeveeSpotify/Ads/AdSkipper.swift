import Foundation
import ObjectiveC
import EeveeSpotifyC

// Active "block ads AND skip them" layer. The service kills and response blocks
// in EeveeAdBlockerExtended starve most ad surfaces before they render, but a
// cached/fallback in-stream break can still reach the player. When the player
// reports an ad track as current, this class skips it immediately instead of
// letting it play out.
//
// Detection is intentionally strict: it only fires for tracks/state that
// explicitly advertise themselves as an ad (isAd flag, ad metadata, or an ad
// URI). A false positive would skip a real song, so anything ambiguous is
// ignored.
final class AdSkipper {
    static let shared = AdSkipper()

    private let queue = DispatchQueue(label: "com.eevee.adskipper")
    private let skipCooldown: TimeInterval = 1.5
    private var lastSkipTime: TimeInterval = 0

    // MARK: - Entry point (called from the player-state observer)

    func processStateChange(player: AnyObject, state: AnyObject) {
        let isPlaying = (Self.bool(state, "isPlaying") ?? false)
        let duration = Self.number(state, "duration")

        queue.async {
            guard isPlaying else { return }
            guard let detection = Self.detectAd(in: state, duration: duration) else { return }
            self.skip(player: player, detection: detection)
        }
    }

    // MARK: - Detection

    private struct AdDetection {
        let reason: String
        let duration: Double
    }

    private static func detectAd(in state: AnyObject, duration: Double) -> AdDetection? {
        var objects: [AnyObject] = []
        // The current track is the authoritative source; the playing state is
        // checked too because some builds surface the ad flag on the state.
        if let track = Self.read(state, "track") { objects.append(track as AnyObject) }
        objects.append(state)

        for obj in objects {
            for key in ["isAd", "isAdvertisement", "isInAdBreak", "inAdBreak", "adBreakActive"] {
                if Self.bool(obj, key) == true {
                    return AdDetection(reason: "\(key)=true", duration: duration)
                }
            }

            for key in ["adMetadata", "adInfo", "adContext", "adBreakMetadata",
                        "advertisement", "adSession", "adBreak"] {
                if let value = Self.read(obj, key), !(value is NSNull) {
                    return AdDetection(reason: "\(key) present", duration: duration)
                }
            }

            for key in ["URI", "uri", "URIString", "identifier"] {
                if let uri = Self.string(obj, key), Self.isAdURI(uri) {
                    return AdDetection(reason: "ad URI: \(uri)", duration: duration)
                }
            }
        }
        return nil
    }

    private static func isAdURI(_ uri: String) -> Bool {
        let s = uri.lowercased()
        if s.hasPrefix("spotify:ad") || s.hasPrefix("ad:") || s.hasPrefix("spotify:adbreak") {
            return true
        }
        if s.contains(":ad:") || s.contains("/ad/") || s.contains("ad-break") || s.contains("adbreak") {
            return true
        }
        return false
    }

    // MARK: - Skipping

    private func skip(player: AnyObject, detection: AdDetection) {
        let now = Self.uptimeSec()
        guard now - lastSkipTime >= skipCooldown else {
            writeDebugLog("[AdSkip] cooldown active, ignoring (\(detection.reason))")
            return
        }
        lastSkipTime = now
        writeDebugLog("[AdSkip] ad detected (\(detection.reason)), skipping")

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            // 1. Ad-specific skip APIs (if this Spotify build exposes one).
            if Self.invoke([
                "skipAd", "skipAdBreak", "dismissAd", "finishAd",
                "endAd", "adSkipped", "skipCurrentAd"
            ], on: player) {
                writeDebugLog("[AdSkip] skipped via ad API")
                return
            }

            // 2. Normal "next track" — cheapest and most reliable fallback.
            if Self.invoke([
                "next", "nextTrack", "nextItem", "nextEntry",
                "skipToNext", "skipNext", "goNext", "playNext",
                "moveToNextTrack"
            ], on: player) {
                writeDebugLog("[AdSkip] skipped to next track")
                return
            }

            // 3. Last resort: seek to the very end so the break ends instantly.
            let duration = detection.duration
            if duration > 0, duration < 900, Self.seekToEnd(player: player, duration: duration) {
                writeDebugLog("[AdSkip] skipped by seeking to ad end")
            } else {
                writeDebugLog("[AdSkip] no usable skip mechanism on this player")
            }
        }
    }

    @discardableResult
    private static func invoke(_ names: [String], on player: AnyObject) -> Bool {
        guard let obj = player as? NSObject else { return false }
        for name in names {
            let selector = NSSelectorFromString(name)
            guard obj.responds(to: selector) else { continue }
            _ = obj.perform(selector)
            return true
        }
        return false
    }

    @discardableResult
    private static func seekToEnd(player: AnyObject, duration: Double) -> Bool {
        let target = max(0, duration - 0.25)
        for name in ["seekTo:", "seekToPosition:", "seekToMs:", "seek:"] {
            let selector = NSSelectorFromString(name)
            guard player.responds(to: selector) else { continue }

            // Spotify player variants take either seconds or milliseconds.
            // Read the argument type encoding instead of guessing.
            var argument = target
            let cls = object_getClass(player)
            if let method = class_getInstanceMethod(cls, selector),
               let rawType = method_copyArgumentType(method, 2) {
                let type = String(cString: rawType)
                free(rawType)
                if type != "d" { argument = target * 1000.0 }
            }
            EeveeSBInvokeSeekDouble(player, selector, argument)
            return true
        }
        return false
    }

    // MARK: - Safe KVC helpers (must not throw on unknown keys)

    private static func read(_ obj: AnyObject, _ key: String) -> Any? {
        let selector = NSSelectorFromString(key)
        guard obj.responds(to: selector) else { return nil }
        return obj.value(forKey: key)
    }

    private static func bool(_ obj: AnyObject, _ key: String) -> Bool? {
        read(obj, key) as? Bool
    }

    private static func number(_ obj: AnyObject, _ key: String) -> Double {
        guard let value = read(obj, key) else { return 0 }
        if let number = value as? NSNumber { return number.doubleValue }
        if let double = value as? Double { return double }
        return 0
    }

    private static func string(_ obj: AnyObject, _ key: String) -> String? {
        guard let value = read(obj, key) else { return nil }
        if let string = value as? String { return string }
        if let url = value as? URL { return url.absoluteString }
        return nil
    }

    private static func uptimeSec() -> TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000.0
    }
}
