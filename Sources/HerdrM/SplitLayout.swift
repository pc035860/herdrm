import CoreGraphics
import SwiftUI

/// Clamp shared by the canvas (and formerly SplitContainer): dividers live
/// in 0.2...0.8 so neither pane can be dragged out of existence.
enum SplitContainerRatioBounds {
    static let bounds = 0.2...0.8

    static func clamp(_ value: Double) -> Double {
        Swift.min(Swift.max(value, bounds.lowerBound), bounds.upperBound)
    }
}

/// Dims the unfocused panes enough to show which leaf has the keyboard without
/// making their text unreadable. Tuned visually; deliberately not a setting.
let inactivePaneOpacity = 0.55

/// One draggable divider, positioned by the layout pass. `path` is the child
/// index trail from the root ([0] = first, [1] = second) and doubles as the
/// stable identity and the ratio write-back address.
struct SplitDividerLayout: Identifiable {
    let path: [Int]
    let axis: SplitAxis
    let ratio: Double
    let rect: CGRect

    var id: String { path.map(String.init).joined(separator: "/") }
}

/// Pure geometry: partitions `rect` by the tree into leaf rects plus divider
/// rects. UI-framework-free and unit-testable. Mirrors SplitContainer's
/// geometry exactly: first cell gets total*clamped(ratio), a 1pt divider,
/// second cell fills the rest.
func splitLayout(
    _ tree: AppModel.SplitNode?,
    in rect: CGRect
) -> (leaves: [AppModel.SplitLeafID: CGRect], dividers: [SplitDividerLayout]) {
    guard let tree else { return ([.agent: rect], []) }
    var leaves: [AppModel.SplitLeafID: CGRect] = [:]
    var dividers: [SplitDividerLayout] = []
    func lay(_ node: AppModel.SplitNode, in rect: CGRect, path: [Int]) {
        switch node {
        case .leaf(.agent):
            leaves[.agent] = rect
        case .leaf(.terminal(let pane)):
            leaves[.pane(deviceID: pane.device.id, paneID: pane.paneID)] = rect
        case .split(let axis, let ratio, let first, let second):
            let firstLength = (axis == .vertical ? rect.width : rect.height)
                * SplitContainerRatioBounds.clamp(ratio)
            if axis == .vertical {
                lay(first, in: CGRect(x: rect.minX, y: rect.minY, width: firstLength, height: rect.height), path: path + [0])
                dividers.append(SplitDividerLayout(path: path, axis: axis, ratio: ratio, rect: CGRect(x: rect.minX + firstLength, y: rect.minY, width: 1, height: rect.height)))
                lay(second, in: CGRect(x: rect.minX + firstLength + 1, y: rect.minY, width: max(0, rect.width - firstLength - 1), height: rect.height), path: path + [1])
            } else {
                lay(first, in: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: firstLength), path: path + [0])
                dividers.append(SplitDividerLayout(path: path, axis: axis, ratio: ratio, rect: CGRect(x: rect.minX, y: rect.minY + firstLength, width: rect.width, height: 1)))
                lay(second, in: CGRect(x: rect.minX, y: rect.minY + firstLength + 1, width: rect.width, height: max(0, rect.height - firstLength - 1)), path: path + [1])
            }
        }
    }
    lay(tree, in: rect, path: [])
    return (leaves, dividers)
}
