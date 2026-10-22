import SwiftUI
import UIKit

// iPhone Duo support shared by every Hearth app. Canonical copy: ~/Developer/hearthkit
// (copied into each app by sync.sh; never edit an app's copy).
//
// Design: the "Hearth on iPhone Duo" canvas. Rules, from it and Apple's HIG:
// - One layout that grows with the space: compact on the outer display, regular inside. A pose
//   gets its own mode only where the way people hold the device changes the job.
// - Rails, not bars: use standard toolbars and tab views so the system moves them to the trailing
//   edge; give every toolbar item a title and a symbol (Label), Back/Close first, then the
//   prominent action.
// - Nothing in the fold: two related views go in `HearthFoldSplit` (equal panes when folded) or
//   `HearthFoldOverlay` (content above the fold, controls on the flat half); grids use an even
//   number of columns (`HearthEvenColumns`).
// - Same functions in every pose, and state follows the hand (keep state in models, not in a
//   pose-specific view).
//
// The Duo APIs (ArrangementView, ReservedRegion, toolbarVerticalEdge) arrive in iOS 27.1. Every
// use here is behind `#available`, so on iOS 26 and on other iPhones the views fall back to plain
// stacks and `hearthDuoPose` stays `.standard`.

// MARK: - Pose

/// How the device is being used right now, as far as layout is concerned.
///
/// There's no system API for the pose itself. Hearth reads it from what the layout can see:
/// an active fold (a division reserved region) running vertically is Book, horizontally is
/// Laptop; vertical system bars with a compact width is the outer display (Closed or Tent);
/// vertical bars with a regular width is the inner display in landscape (Open wide). Everything
/// else, including the inner display in portrait (Open tall), iPad and other iPhones, is
/// `.standard`. Tent can't be told apart from Closed, so standing "board" modes are opened by
/// the person (`HearthGlanceBoard`), not switched on automatically.
nonisolated enum HearthDuoPose: String, Sendable, Equatable {
    case standard
    /// Outer display: device closed (or standing as a tent). Compact width, bars on the trailing edge.
    case outer
    /// Inner display, fully open, landscape. Regular width, bars on the trailing edge.
    case openWide
    /// Inner display, partly folded and held: the fold runs top to bottom.
    case book
    /// Inner display, partly folded and set down: the fold runs side to side.
    case laptop

    /// Partly folded (Book or Laptop): content must stay out of the fold.
    var isFolded: Bool { self == .book || self == .laptop }

    static func resolve(division: CGRect?, verticalBars: Bool, compactWidth: Bool) -> HearthDuoPose {
        if let division {
            return division.height > division.width ? .book : .laptop
        }
        if verticalBars { return compactWidth ? .outer : .openWide }
        return .standard
    }
}

private struct HearthDuoPoseKey: EnvironmentKey {
    static let defaultValue: HearthDuoPose = .standard
}

extension EnvironmentValues {
    /// The current iPhone Duo pose, set by `.hearthDuoPose()` at the root of each scene.
    var hearthDuoPose: HearthDuoPose {
        get { self[HearthDuoPoseKey.self] }
        set { self[HearthDuoPoseKey.self] = newValue }
    }
}

extension View {
    /// Reads the iPhone Duo pose and passes it down as `\.hearthDuoPose`. Put it once on each
    /// scene's root view (outside the tab view), so it measures the whole window. Also put it on
    /// the root of any `.fullScreenCover` whose content reads the pose: a full-screen cover takes
    /// the presenting screen out of the window, so the scene root's reading can go stale.
    func hearthDuoPose() -> some View { modifier(HearthDuoPoseReader()) }
}

private struct HearthDuoPoseReader: ViewModifier {
    @State private var pose: HearthDuoPose = .standard

    func body(content: Content) -> some View {
        content
            .environment(\.hearthDuoPose, pose)
            .background {
                if #available(iOS 27.1, *) {
                    HearthDuoProbe { new in
                        if new != pose { pose = new }
                    }
                }
            }
    }
}

@available(iOS 27.1, *)
private struct HearthDuoProbe: View {
    @Environment(\.toolbarVerticalEdge) private var verticalEdge
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let report: (HearthDuoPose) -> Void

    var body: some View {
        GeometryReader { proxy in
            let division = proxy.reservedRegions(kind: .division).first?.frame
            let pose = HearthDuoPose.resolve(
                division: division,
                verticalBars: verticalEdge != nil,
                compactWidth: horizontalSizeClass == .compact
            )
            Color.clear
                .onAppear { report(pose) }
                .onChange(of: pose) { _, new in report(new) }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

// MARK: - Two related views, kept out of the fold

/// Two related views side by side in landscape and stacked in portrait, with equal panes and
/// nothing in the fold when the device is partly folded. On the outer display in landscape only
/// the primary shows (Apple's split arrangement), so put the view people need first there.
///
/// `axes` limits when it splits: `.horizontal` shows only the primary in portrait.
/// Don't put it inside a List, ScrollView or NavigationSplitView; put scrolling inside each pane.
struct HearthFoldSplit<Primary: View, Secondary: View>: View {
    let axes: Axis.Set
    let primary: Primary
    let secondary: Secondary

    init(axes: Axis.Set = [.horizontal, .vertical], @ViewBuilder primary: () -> Primary, @ViewBuilder secondary: () -> Secondary) {
        self.axes = axes
        self.primary = primary()
        self.secondary = secondary()
    }

    var body: some View {
        if #available(iOS 27.1, *) {
            ArrangementView {
                primary
            } secondary: {
                secondary
            }
            .arrangementViewStyle(.split.axes(axes))
        } else {
            HearthFallbackSplit(axes: axes, primary: primary, secondary: secondary)
        }
    }
}

private struct HearthFallbackSplit<Primary: View, Secondary: View>: View {
    let axes: Axis.Set
    let primary: Primary
    let secondary: Secondary

    var body: some View {
        GeometryReader { proxy in
            let wide = proxy.size.width > proxy.size.height
            if wide && axes.contains(.horizontal) {
                HStack(spacing: 0) {
                    primary.frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    secondary.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if !wide && axes.contains(.vertical) {
                VStack(spacing: 0) {
                    primary.frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    secondary.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                primary.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// Content with controls for it: on a flat display the controls float over the bottom of the
/// content; when partly folded they move to their own half (the flat half in Laptop, the trailing
/// page in Book) and the content gets the other half, clear of the fold.
///
/// Use it for Cook Mode, quizzes and other "read up top, tap below" screens.
struct HearthFoldOverlay<Controls: View, Content: View>: View {
    let controls: Controls
    let content: Content

    init(@ViewBuilder controls: () -> Controls, @ViewBuilder content: () -> Content) {
        self.controls = controls()
        self.content = content()
    }

    var body: some View {
        if #available(iOS 27.1, *) {
            // Apple's overlay arrangement: the primary (controls) sits over the secondary on a flat
            // display, and goes to the trailing or bottom side of the fold when folded.
            ArrangementView {
                controls
            } secondary: {
                content
            }
            .arrangementViewStyle(.overlay)
        } else {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .safeAreaInset(edge: .bottom, spacing: 0) { controls }
        }
    }
}

// MARK: - Even grids

enum HearthEvenColumns {
    /// Grid columns for the width available, always an even number (2, 4, 6…) so a fold divides
    /// the grid between columns rather than through a cell. Small widths get 2.
    static func count(for width: CGFloat, minimumCellWidth: CGFloat, maximum: Int = 6) -> Int {
        guard width > 0, minimumCellWidth > 0 else { return 2 }
        let fit = Int(width / minimumCellWidth)
        let even = max(2, fit - fit % 2)
        return min(even, max(2, maximum - maximum % 2))
    }

    static func flexible(_ count: Int, spacing: CGFloat = 12) -> [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: spacing), count: max(1, count))
    }
}

// MARK: - Glance boards (Tent)

/// A full-screen board meant to be read from across a room: the device standing as a tent on a
/// counter or desk, or simply propped up. Big type on the app's color, no scrolling, the screen
/// kept awake while it shows. People open it from a toolbar button (`HearthGlanceBoardButton`)
/// and close it with Close (the X); the system can't tell Tent from Closed, so it never opens by itself.
///
/// Put up to two or three numbers or lines in it. Actions go in `actions` as toolbar items (give each
/// a Label with a title and symbol), which the outer display shows on its trailing rail.
struct HearthGlanceBoard<Content: View, Actions: ToolbarContent>: View {
    let title: String
    let color: Color
    let content: Content
    let actions: Actions

    @Environment(\.dismiss) private var dismiss

    init(_ title: String, color: Color, @ViewBuilder content: () -> Content, @ToolbarContentBuilder actions: () -> Actions) {
        self.title = title
        self.color = color
        self.content = content()
        self.actions = actions()
    }

    var body: some View {
        NavigationStack {
            content
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
                .background(color.gradient, ignoresSafeAreaEdges: .all)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbarColorScheme(.dark, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { dismiss() } label: { Label("Close", systemImage: "xmark") }
                    }
                    actions
                }
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }
}

/// The toolbar button that opens a glance board. Give it a title and symbol, so it shows on the
/// Duo's rail and in the overflow menu.
struct HearthGlanceBoardButton: View {
    let title: String
    var systemImage: String = "rectangle.inset.filled"
    let action: () -> Void

    var body: some View {
        Button(action: action) { Label(title, systemImage: systemImage) }
    }
}

/// A big figure for a glance board: a number readable from across the room with a label under it.
struct HearthGlanceFigure: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 120, weight: .bold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.3)
                .lineLimit(1)
            Text(label)
                .font(.title2.weight(.semibold))
                .opacity(0.85)
                .multilineTextAlignment(.center)
        }
        .accessibilityElement(children: .combine)
    }
}
