//
//  ButtonRemapper.swift
//  MouseSpaceSwitcher
//
//  Drop-in replacement that includes verbose console logging for scroll device detection.
//

import Foundation
import IOKit.hid
import Cocoa

class ButtonRemapper {

    var manager: IOHIDManager!
    var eventTap: CFMachPort?

    init() {
        setupHIDButtonListener()
        setupScrollEventTap()
        NSLog("[Remapper] Initialized")
    }

    // -----------------------
    // MARK: - MOUSE BUTTONS
    // -----------------------

    func setupHIDButtonListener() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

        let matching = [
            kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey: kHIDUsage_GD_Mouse
        ] as CFDictionary

        IOHIDManagerSetDeviceMatching(manager, matching)
        IOHIDManagerRegisterInputValueCallback(manager, hidCallback, nil)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        NSLog("[Remapper] HID manager started")
    }
}

// ---------------------------------------------------
// HID Callback for mouse buttons
// ---------------------------------------------------

private func hidCallback(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    value: IOHIDValue
) {
    let elem = IOHIDValueGetElement(value)
    let usage = IOHIDElementGetUsage(elem)
    let page = IOHIDElementGetUsagePage(elem)

    // Only care about buttons
    if page != kHIDPage_Button { return }

    let pressed = IOHIDValueGetIntegerValue(value) == 1
    if !pressed { return }

    // Log which usage/button fired
    NSLog("[HID] Button usage \(usage) pressed (page \(page))")

    // TEST MODE: Both side buttons perform CMD + F
    if usage == 4 || usage == 5 {
        NSLog("[HID] Side button detected (usage \(usage)). Triggering test shortcut CMD+F")
        triggerTestShortcut()
    }
}

// ---------------------------------------------------
// CMD + F Shortcut Trigger for Testing
// ---------------------------------------------------

func triggerTestShortcut() {
    sendKeyCombo(key: 0x03, flags: .maskCommand) // F key code = 0x03
}

func sendKeyCombo(key: CGKeyCode, flags: CGEventFlags) {
    guard let src = CGEventSource(stateID: .hidSystemState) else { return }

    let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true)
    down?.flags = flags

    let up = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false)
    up?.flags = flags

    down?.post(tap: .cghidEventTap)
    up?.post(tap: .cghidEventTap)
}

// ---------------------------------------------------
// SCROLL WHEEL FIX — INVERT ONLY MOUSE, NOT TRACKPAD
// with verbose logging
// ---------------------------------------------------

extension ButtonRemapper {

    func setupScrollEventTap() {
        let mask = (1 << CGEventType.scrollWheel.rawValue)

        eventTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: scrollCallback,
            userInfo: nil
        )

        if let eventTap = eventTap {
            let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            NSLog("[Remapper] Scroll event tap installed")
        } else {
            NSLog("[Remapper] Failed to create event tap. Make sure Accessibility permissions are granted.")
        }
    }
}

private func scrollCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {

    // Defensive: only handle scroll events
    guard type == .scrollWheel else {
        return Unmanaged.passRetained(event)
    }

    // Read multiple scroll-related fields for debugging and robust detection
    let isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous)
    let deltaY = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
    let pointDeltaY = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
    let fixedPtDeltaY = event.getIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1)
    let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase) // may be 0 if not present

    // Timestamp and thread info for better debugging
    let ts = Date()
    let formatter = ISO8601DateFormatter()
    let timeStr = formatter.string(from: ts)

    // Log all the fields (use NSLog so it appears in Console.app)
    NSLog("[ScrollDebug] \(timeStr) — isContinuous: \(isContinuous), deltaY: \(deltaY), pointDeltaY: \(pointDeltaY), fixedPtDeltaY: \(fixedPtDeltaY), momentumPhase: \(momentum)")

    // Primary detection: use isContinuous
    if isContinuous == 1 {
        NSLog("[ScrollDetect] Classified as TRACKPAD (isContinuous == 1). No inversion applied.")
        return Unmanaged.passRetained(event)
    }

    // Fallback checks (in case some mice report continuous incorrectly)
    // If pointDeltaY is non-zero but extremely small we might treat as trackpad; otherwise assume mouse.
    

    if pointDeltaY != 0 {
        // Log that event also contains pointDelta
        NSLog("[ScrollDetect] Event contains pointDeltaY = \(pointDeltaY). Because isContinuous != 1, we'll still treat it as MOUSE by default.")
    }

    // If we reached here, treat as MOUSE wheel (discrete ticks). Invert the delta.
    let newDelta = -deltaY
    event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: newDelta)

    // For completeness, also invert fixedPt delta if it exists (helps some mice)
    if fixedPtDeltaY != 0 {
        event.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1, value: -fixedPtDeltaY)
    }

    NSLog("[ScrollAction] Classified as MOUSE. Inverted scroll: old deltaY=\(deltaY) -> new deltaY=\(newDelta)")

    return Unmanaged.passRetained(event)
}
