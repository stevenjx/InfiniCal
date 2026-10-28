//
//  HIDThermal.swift
//  The one place that talks to the AppleVendor temperature sensors.
//
//  Both the fan page and the calibration engine need these readings, and they
//  had grown two copies of the same IOKit plumbing — including the name filter
//  that decides what counts as the CPU. Keeping it here means a fix for one
//  page is a fix for both.
//
//  Everything is read through dlopen'd IOHIDEventSystemClient symbols: the
//  public headers do not declare these, and the app is not sandboxed, so no
//  entitlement is needed.
//

import Foundation
import Darwin

enum HIDThermal {

    /// Raw AppleVendor temperature services as (product name, °C).
    ///
    /// Names come straight from IOKit, so callers can show them verbatim
    /// instead of inventing labels. Sensors outside 0…130 °C are dropped: that
    /// range excludes the disarmed/garbage values the page reports when a
    /// service is present but not populated.
    static func readings() -> [(name: String, celsius: Double)] {
        typealias CreateFunc = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
        typealias MatchFunc = @convention(c) (AnyObject, CFDictionary) -> Void
        typealias ServicesFunc = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
        typealias PropertyFunc = @convention(c) (AnyObject, CFString) -> Unmanaged<CFTypeRef>?
        typealias EventFunc = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
        typealias FloatFunc = @convention(c) (AnyObject, UInt32) -> Double

        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else { return [] }
        defer { dlclose(handle) }
        guard let createSym = dlsym(handle, "IOHIDEventSystemClientCreate"),
              let matchSym = dlsym(handle, "IOHIDEventSystemClientSetMatching"),
              let servicesSym = dlsym(handle, "IOHIDEventSystemClientCopyServices"),
              let propertySym = dlsym(handle, "IOHIDServiceClientCopyProperty"),
              let eventSym = dlsym(handle, "IOHIDServiceClientCopyEvent"),
              let floatSym = dlsym(handle, "IOHIDEventGetFloatValue") else { return [] }

        let create = unsafeBitCast(createSym, to: CreateFunc.self)
        let match = unsafeBitCast(matchSym, to: MatchFunc.self)
        let copyServices = unsafeBitCast(servicesSym, to: ServicesFunc.self)
        let copyProperty = unsafeBitCast(propertySym, to: PropertyFunc.self)
        let copyEvent = unsafeBitCast(eventSym, to: EventFunc.self)
        let floatValue = unsafeBitCast(floatSym, to: FloatFunc.self)

        guard let client = create(kCFAllocatorDefault)?.takeRetainedValue() else { return [] }
        match(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        guard let services = copyServices(client)?.takeRetainedValue() as? [AnyObject] else { return [] }

        var rows: [(String, Double)] = []
        for service in services {
            guard let name = copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String else { continue }
            guard let event = copyEvent(service, 15, 0, 0)?.takeRetainedValue() else { continue }
            let celsius = floatValue(event, 0x000F0000)
            guard celsius > 0, celsius < 130 else { continue }
            rows.append((name, celsius))
        }
        return rows
    }

    /// Mean of the services whose name matches, restricted to `range`. Nil when
    /// nothing matches, so callers can tell "no sensor" from "0 °C".
    static func average(in range: ClosedRange<Double> = 0...130,
                        where matches: (String) -> Bool) -> Double? {
        let values = readings()
            .filter { matches($0.name) && range.contains($0.celsius) }
            .map(\.celsius)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}
