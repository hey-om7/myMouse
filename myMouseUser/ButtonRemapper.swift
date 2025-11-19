//
//  ButtonRemapper.swift
//  MouseSpaceSwitcher
//

import Foundation
import IOKit.hid
import Cocoa

class ButtonRemapper {

    var manager: IOHIDManager!
    var scrollTap: CFMachPort?
    var buttonBlockerTap: CFMachPort?

    init() {
        setupHIDButtonListener()
        setupScrollEventTap()
        setupButtonBlockerEventTap()
    }

    // -----------------------
    // HID BUTTON LISTENER
    // -----------------------

    func setupHIDButtonListener() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)

        let matching: CFDictionary = [
            kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey: kHIDUsage_GD_Mouse
        ] as CFDictionary

        IOHIDManagerSetDeviceMatching(manager, matching)
        IOHIDManagerRegisterInputValueCallback(manager, hidCallback, nil)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, 0)
    }
}

// ---------------------------------------------------
// HID Callback (Side buttons 4 & 5)
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

    if page != kHIDPage_Button { return }
    if IOHIDValueGetIntegerValue(value) != 1 { return }

    if usage == 4 {
        sendCtrlArrow(key: 0x7B) // left arrow
    }

    if usage == 5 {
        sendCtrlArrow(key: 0x7C) // right arrow
    }
}

// ---------------------------------------------------
// REAL Control + Arrow simulation (perfect method)
// ---------------------------------------------------

func sendCtrlArrow(key: CGKeyCode) {
    guard let src = CGEventSource(stateID: .hidSystemState) else { return }

    let ctrlKey: CGKeyCode = 0x3B  // Control

    let ctrlDown = CGEvent(keyboardEventSource: src, virtualKey: ctrlKey, keyDown: true)!
    ctrlDown.post(tap: .cghidEventTap)

    usleep(1000) // ensure modifier is registered

    let arrowDown = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true)!
    arrowDown.post(tap: .cghidEventTap)

    let arrowUp = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false)!
    arrowUp.post(tap: .cghidEventTap)

    usleep(1000)

    let ctrlUp = CGEvent(keyboardEventSource: src, virtualKey: ctrlKey, keyDown: false)!
    ctrlUp.post(tap: .cghidEventTap)
}

// ---------------------------------------------------
// SCROLL INVERSION — MOUSE ONLY
// ---------------------------------------------------

extension ButtonRemapper {
    func setupScrollEventTap() {
        let mask = (1 << CGEventType.scrollWheel.rawValue)

        scrollTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: scrollCallback,
            userInfo: nil
        )

        if let tap = scrollTap {
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }
}

private func scrollCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {

    guard type == .scrollWheel else { return Unmanaged.passRetained(event) }

    let isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous)

    if isContinuous == 1 {
        return Unmanaged.passRetained(event) // trackpad
    }

    let dy = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
    let fy = event.getIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1)
    let py = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)

    if dy != 0 { event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: -dy) }
    if fy != 0 { event.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1, value: -fy) }
    if py != 0 { event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: -py) }

    return Unmanaged.passRetained(event)
}

// ---------------------------------------------------
// BLOCK DEFAULT BACK/FORWARD (Button 4/5)
// ---------------------------------------------------

extension ButtonRemapper {

    func setupButtonBlockerEventTap() {
        let mask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.rightMouseUp.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.otherMouseUp.rawValue)

        buttonBlockerTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: blockSideButtonCallback,
            userInfo: nil
        )

        if let tap = buttonBlockerTap {
            let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        }
    }
}

private func blockSideButtonCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {

    let button = event.getIntegerValueField(.mouseEventButtonNumber)

    if button == 3 || button == 4 || button == 5 {
        return nil // BLOCK
    }

    return Unmanaged.passRetained(event)
}
