import AppKit
import CoreGraphics

extension InputEvent {
    /// The parts of a real event the other Mac needs to play it; nil for events that aren't sent.
    init?(_ event: CGEvent) {
        let type = event.type
        self.init(type: type.rawValue, flags: event.flags.rawValue)
        switch type {
        case .keyDown, .keyUp, .flagsChanged:
            fields[CGEventField.keyboardEventKeycode.rawValue] = Double(event.getIntegerValueField(.keyboardEventKeycode))
            fields[CGEventField.keyboardEventAutorepeat.rawValue] = Double(event.getIntegerValueField(.keyboardEventAutorepeat))
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            fields[CGEventField.mouseEventDeltaX.rawValue] = event.getDoubleValueField(.mouseEventDeltaX)
            fields[CGEventField.mouseEventDeltaY.rawValue] = event.getDoubleValueField(.mouseEventDeltaY)
            fields[CGEventField.mouseEventButtonNumber.rawValue] = Double(event.getIntegerValueField(.mouseEventButtonNumber))
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            fields[CGEventField.mouseEventButtonNumber.rawValue] = Double(event.getIntegerValueField(.mouseEventButtonNumber))
            fields[CGEventField.mouseEventClickState.rawValue] = Double(event.getIntegerValueField(.mouseEventClickState))
        case .scrollWheel:
            for field in InputEvent.scrollFields {
                fields[field.rawValue] = InputEvent.doubleFields.contains(field)
                    ? event.getDoubleValueField(field) : Double(event.getIntegerValueField(field))
            }
        default:
            // Media keys (volume, play/pause, brightness) are system-defined events of subtype 8.
            guard type.rawValue == 14, let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else { return nil }
            fields[InputEvent.subtypeField] = 8
            fields[InputEvent.data1Field] = Double(ns.data1)
            fields[InputEvent.data2Field] = Double(ns.data2)
        }
    }
}

/// The CGEvent fields each kind of event carries across.
extension InputEvent {
    static let scrollFields: [CGEventField] = [
        .scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2,
        .scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2,
        .scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2,
        .scrollWheelEventIsContinuous, .scrollWheelEventScrollPhase, .scrollWheelEventMomentumPhase,
        .scrollWheelEventScrollCount,
    ]
    static let scrollDeltaFields: Set<CGEventField> = [
        .scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2,
        .scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2,
        .scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2,
    ]
    static let doubleFields: Set<CGEventField> = [.scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2]
}
