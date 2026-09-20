//
//  sizeMatters.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 05/08/24.
//

import Defaults
import Foundation
import SwiftUI

let downloadSneakSize: CGSize = .init(width: 65, height: 1)
let batterySneakSize: CGSize = .init(width: 160, height: 1)

let shadowPadding: CGFloat = 20
// Expanded panel metrics, tuned to Alcove's compact player: artwork and title on
// one row, a scrubber flanked by timestamps, then a centered control row.
// `openNotchSize` is the music-only panel; optional columns widen it (see
// `openNotchWidth`), up to `maxOpenNotchWidth`, which is what the window is sized to.
//
// The width is not arbitrary: in the compact player the artwork rises into the
// band beside the physical notch, so each side column must fit
// `horizontalInset + albumArtOpenSize` next to a ~189pt notch. Narrower than this
// and the artwork disappears behind the notch cutout.
let openNotchSize: CGSize = .init(width: 420, height: 176)
/// Extra height for layouts that need a header row above the content (shelf, or
/// home when the shelf tabs are showing) instead of the raised artwork.
let stackedHeaderExtraHeight: CGFloat = 30
let maxOpenNotchWidth: CGFloat = 640
let windowSize: CGSize = .init(width: maxOpenNotchWidth, height: openNotchSize.height + shadowPadding)

let homeColumnSpacing: CGFloat = 15
let calendarColumnWidth: CGFloat = 175
let compactCalendarColumnWidth: CGFloat = 145  // when the camera shares the row
let cameraColumnWidth: CGFloat = 160
let albumArtOpenSize: CGFloat = 80

/// Horizontal padding between the panel edge and its content, as applied in
/// `ContentView.NotchLayout` (corner-radius inset + content padding).
let panelHorizontalInset: CGFloat = cornerRadiusInsets.opened.top + 12

/// Free width between the panel's content edge and the physical notch, per side.
/// Zero on a display without a notch, where the whole band is usable.
@MainActor func notchSideColumnWidth(panelWidth: CGFloat, screenUUID: String? = nil) -> CGFloat {
    let notchWidth = getClosedNotchSize(screenUUID: screenUUID).width
    return max(0, (panelWidth - notchWidth) / 2 - panelHorizontalInset)
}

/// Base width of the compact player: wide enough that the raised artwork still
/// clears the notch. Scaled display modes change how many points the (physically
/// fixed) notch spans — "More Space" makes it wider in points — so this is derived
/// from the live notch width rather than assuming the default resolution.
@MainActor func compactPlayerWidth(screenUUID: String? = nil) -> CGFloat {
    let notchWidth = getClosedNotchSize(screenUUID: screenUUID).width
    let needed = notchWidth + 2 * (panelHorizontalInset + albumArtOpenSize + 4)
    return min(max(openNotchSize.width, needed), maxOpenNotchWidth)
}

/// Width of the expanded panel for the columns currently enabled.
@MainActor func openNotchWidth(showingCamera: Bool, screenUUID: String? = nil) -> CGFloat {
    var width = compactPlayerWidth(screenUUID: screenUUID)

    if Defaults[.showCalendar] {
        width += (showingCamera ? compactCalendarColumnWidth : calendarColumnWidth) + homeColumnSpacing
    }
    if showingCamera {
        width += cameraColumnWidth + homeColumnSpacing
    }

    return min(width, maxOpenNotchWidth)
}
let cornerRadiusInsets: (opened: (top: CGFloat, bottom: CGFloat), closed: (top: CGFloat, bottom: CGFloat)) = (opened: (top: 19, bottom: 24), closed: (top: 6, bottom: 14))

enum MusicPlayerImageSizes {
    static let cornerRadiusInset: (opened: CGFloat, closed: CGFloat) = (opened: 13.0, closed: 4.0)
    static let size = (opened: CGSize(width: 90, height: 90), closed: CGSize(width: 20, height: 20))
}

@MainActor func getScreenFrame(_ screenUUID: String? = nil) -> CGRect? {
    var selectedScreen = NSScreen.main

    if let uuid = screenUUID {
        selectedScreen = NSScreen.screen(withUUID: uuid)
    }
    
    if let screen = selectedScreen {
        return screen.frame
    }
    
    return nil
}

@MainActor func getClosedNotchSize(screenUUID: String? = nil) -> CGSize {
    // Default notch size, to avoid using optionals
    var notchHeight: CGFloat = Defaults[.nonNotchHeight]
    var notchWidth: CGFloat = 185

    var selectedScreen = NSScreen.main

    if let uuid = screenUUID {
        selectedScreen = NSScreen.screen(withUUID: uuid)
    }

    // Check if the screen is available
    if let screen = selectedScreen {
        // Calculate and set the exact width of the notch
        if let topLeftNotchpadding: CGFloat = screen.auxiliaryTopLeftArea?.width,
           let topRightNotchpadding: CGFloat = screen.auxiliaryTopRightArea?.width
        {
            notchWidth = screen.frame.width - topLeftNotchpadding - topRightNotchpadding + 4
        }

        // Check if the Mac has a notch
        if screen.safeAreaInsets.top > 0 {
            // This is a display WITH a notch - use notch height settings
            notchHeight = Defaults[.notchHeight]
            if Defaults[.notchHeightMode] == .matchRealNotchSize {
                notchHeight = screen.safeAreaInsets.top
            } else if Defaults[.notchHeightMode] == .matchMenuBar {
                notchHeight = screen.frame.maxY - screen.visibleFrame.maxY
            }
        } else {
            // This is a display WITHOUT a notch - use non-notch height settings
            notchHeight = Defaults[.nonNotchHeight]
            if Defaults[.nonNotchHeightMode] == .matchMenuBar {
                notchHeight = screen.frame.maxY - screen.visibleFrame.maxY
            }
        }
    }

    return .init(width: notchWidth, height: notchHeight)
}
