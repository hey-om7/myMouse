//
//  ButtonRemapper.swift
//  MouseSpaceSwitcher
//
//  Final working version with:
//  ✔ HID side button detection
//  ✔ Blocking default macOS back/forward
//  ✔ Mouse-only scroll inversion
//  ✔ Trackpad scroll untouched
//  ✔ Full debug logs
//

import Foundation
import IOKit.hid
import Cocoa

class ButtonRemapper {

    var manager: IOHIDManager!
    var eventTap: CFMachPort?
    var buttonBlockerTap: CFMachPort?

    init() {
        setupHIDButtonListener()
        setupScrollEventTap()
        setupButtonBlockerEventTap()   // <--- IMPORTANT
        NSLog("[Remapper] Initialized")
    }

    // -----------------------
    // MARK: - HID BUTTON LISTENER
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
// HID Callback — detects side buttons via IOHID
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

    let pressed = IOHIDValueGetIntegerValue(value) == 1
    if !pressed { return }

    NSLog("[HID] Button usage \(usage) pressed")

    // Side buttons usually usage 4 or 5
    if usage == 4 || usage == 5 {
        NSLog("[HID] Side button pressed → triggering CMD+F")
        triggerTestShortcut()
    }
}

// ---------------------------------------------------
// CMD + F Shortcut Trigger
// ---------------------------------------------------

func triggerTestShortcut() {
    sendKeyCombo(key: 0x03, flags: .maskCommand)
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
// SCROLL WHEEL FIX — invert only mouse
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
            let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
            NSLog("[Remapper] Scroll event tap installed")
        } else {
            NSLog("[Remapper] ERROR installing scroll event tap")
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
    let deltaY = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
    let fixedY = event.getIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1)
    let pointY = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)

    NSLog("[ScrollDebug] isContinuous=\(isContinuous), delta=\(deltaY), fixed=\(fixedY), point=\(pointY)")

    if isContinuous == 1 {
        NSLog("[ScrollDetect] TRACKPAD → no inversion")
        return Unmanaged.passRetained(event)
    }

    // Mouse → invert all relevant fields
    if deltaY != 0 {
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: -deltaY)
    }
    if fixedY != 0 {
        event.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1, value: -fixedY)
    }
    if pointY != 0 {
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: -pointY)
    }

    NSLog("[ScrollAction] MOUSE → inverted delta")
    return Unmanaged.passRetained(event)
}

// ---------------------------------------------------
// BLOCK SIDE BUTTON DEFAULT ACTIONS
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
            NSLog("[Remapper] Button blocker event tap installed")
        } else {
            NSLog("[Remapper] ERROR installing button blocker tap")
        }
    }
}

private func blockSideButtonCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {

    let btn = event.getIntegerValueField(.mouseEventButtonNumber)

    NSLog("[BlockDebug] type=\(type.rawValue), btn=\(btn)")

    // Many mice report side buttons as 3, 4, or 5
    if btn == 3 || btn == 4 || btn == 5 {
        NSLog("[ButtonBlock] BLOCKED side button \(btn)")
        return nil  // <-- BLOCK the default macOS action
    }

    return Unmanaged.passRetained(event)
}
