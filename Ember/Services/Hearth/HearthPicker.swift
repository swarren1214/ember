// HearthPicker.swift — the Icon & Color picker every Hearth app uses: one palette of thirteen
// colors plus a custom color made right in the picker, and a shared library of SF Symbols
// (HearthIconLibrary.swift) with suggestions from the item's name.
//
// Canonical copy: ~/Developer/hearthkit/HearthPicker.swift. Don't edit the copies inside the
// apps; edit this one and run ~/Developer/hearthkit/sync.sh.
//
// Using it
//   @State private var picking = false
//   Button { picking = true } label: { HearthIconColorLabel(icon: budget.icon, color: budget.color) }
//       .hearthIconColorPicker(isPresented: $picking, title: budget.name, caption: "Budget",
//                              context: .budget, icon: $budget.icon, color: $budget.color)
//
//   People (color only): .hearthColorPicker(isPresented:, title: person.name, color: $person.color)
//
//   Icon only, when the color comes from somewhere else (a reward's kind, the app's accent):
//   HearthIconColorLabel(icon: chore.icon, color: tint, title: "Icon", showsColorName: false)
//   .hearthIconPicker(isPresented:, title: chore.name, caption: "Chore", context: .chore,
//                     icon: $chore.icon, tint: tint)
//
// - Colors are stored as `HearthColorChoice.storage`: a palette id ("green") or "#RRGGBB" for a
//   custom color. `HearthColorChoice(hex:)` turns any old color into one losslessly (a palette
//   color when it matches exactly, otherwise custom).
// - Icons are SF Symbols base names ("cart"); draw them with `HearthIconTile` or
//   `Image(systemName:).symbolVariant(.fill)`.
// - It's a sheet on iPhone and a popover on iPad. Changes apply as you make them, so swiping
//   the sheet away keeps them (like Done); Cancel puts things back.

import SwiftUI
import UIKit

// MARK: - Colors

nonisolated struct HearthPaletteColor: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    /// 0xRRGGBB. Every palette color holds white icons and text in light and dark.
    let hex: UInt32
}

nonisolated enum HearthPalette {
    static let colors: [HearthPaletteColor] = [
        HearthPaletteColor(id: "red", name: "Red", hex: 0xD93A3A),
        HearthPaletteColor(id: "orange", name: "Orange", hex: 0xE8650F),
        HearthPaletteColor(id: "amber", name: "Amber", hex: 0xB7791F),
        HearthPaletteColor(id: "green", name: "Green", hex: 0x1E9E6A),
        HearthPaletteColor(id: "teal", name: "Teal", hex: 0x0E8C99),
        HearthPaletteColor(id: "blue", name: "Blue", hex: 0x0A7AFF),
        HearthPaletteColor(id: "indigo", name: "Indigo", hex: 0x5856D6),
        HearthPaletteColor(id: "purple", name: "Purple", hex: 0x8E4EC6),
        HearthPaletteColor(id: "magenta", name: "Magenta", hex: 0xB5267E),
        HearthPaletteColor(id: "pink", name: "Pink", hex: 0xE0284F),
        HearthPaletteColor(id: "brown", name: "Brown", hex: 0x9A6B45),
        HearthPaletteColor(id: "slate", name: "Slate", hex: 0x5F6B7A),
        HearthPaletteColor(id: "graphite", name: "Graphite", hex: 0x3A3A3C),
    ]

    static func color(id: String) -> HearthPaletteColor? {
        colors.first { $0.id == id }
    }

    /// The palette color closest to `hex`, for apps that want to move old colors onto the palette.
    static func nearest(to hex: UInt32) -> HearthPaletteColor {
        func parts(_ value: UInt32) -> (Double, Double, Double) {
            (Double((value >> 16) & 0xFF), Double((value >> 8) & 0xFF), Double(value & 0xFF))
        }
        let (r, g, b) = parts(hex)
        return colors.min { lhs, rhs in
            let (r1, g1, b1) = parts(lhs.hex), (r2, g2, b2) = parts(rhs.hex)
            let d1 = (r - r1) * (r - r1) + (g - g1) * (g - g1) + (b - b1) * (b - b1)
            let d2 = (r - r2) * (r - r2) + (g - g2) * (g - g2) + (b - b2) * (b - b2)
            return d1 < d2
        } ?? colors[3]
    }
}

/// A color picked in the Hearth picker: one of the palette's, or a custom one.
nonisolated enum HearthColorChoice: Hashable, Sendable {
    case palette(String)
    case custom(UInt32)

    /// From stored text: a palette id ("green") or "#RRGGBB". Anything else is Green.
    init(storage: String) {
        let text = storage.trimmingCharacters(in: .whitespacesAndNewlines)
        if HearthPalette.color(id: text) != nil {
            self = .palette(text)
        } else if text.hasPrefix("#"), text.count == 7, text.dropFirst().allSatisfy(\.isHexDigit), let value = UInt32(text.dropFirst(), radix: 16) {
            self.init(hex: value)
        } else {
            self = .palette("green")
        }
    }

    /// A palette color when `hex` is exactly one, otherwise a custom color.
    init(hex: UInt32) {
        if let match = HearthPalette.colors.first(where: { $0.hex == hex }) {
            self = .palette(match.id)
        } else {
            self = .custom(hex)
        }
    }

    /// What to store: the palette id or "#RRGGBB".
    var storage: String {
        switch self {
        case .palette(let id): id
        case .custom(let hex): String(format: "#%06X", hex)
        }
    }

    var hex: UInt32 {
        switch self {
        case .palette(let id): HearthPalette.color(id: id)?.hex ?? 0x1E9E6A
        case .custom(let hex): hex
        }
    }

    var name: String {
        switch self {
        case .palette(let id): HearthPalette.color(id: id)?.name ?? "Green"
        case .custom: "Custom"
        }
    }

    var isCustom: Bool {
        if case .custom = self { return true }
        return false
    }

    var color: Color { hearthPickerColor(hex) }
}

nonisolated func hearthPickerColor(_ hex: UInt32) -> Color {
    Color(
        red: Double((hex >> 16) & 0xFF) / 255,
        green: Double((hex >> 8) & 0xFF) / 255,
        blue: Double(hex & 0xFF) / 255
    )
}

/// Custom colors: any hue, with the shade kept between 30% and 52% lightness at 72% saturation,
/// so white icons and initials always read on them.
nonisolated enum HearthCustomColor {
    static let saturation = 0.72
    static let lightest = 0.52
    static let darkest = 0.30

    /// `hue` 0…360, `shade` 0 (lighter) … 1 (deeper).
    static func hex(hue: Double, shade: Double) -> UInt32 {
        let lightness = lightest - (lightest - darkest) * min(max(shade, 0), 1)
        return hslToHex(hue: hue, saturation: saturation, lightness: lightness)
    }

    /// The hue and shade that come closest to `hex` (for opening on an existing custom color).
    static func hueAndShade(of hex: UInt32) -> (hue: Double, shade: Double) {
        let r = Double((hex >> 16) & 0xFF) / 255, g = Double((hex >> 8) & 0xFF) / 255, b = Double(hex & 0xFF) / 255
        let maxValue = max(r, g, b), minValue = min(r, g, b), delta = maxValue - minValue
        var hue = 0.0
        if delta > 0 {
            if maxValue == r {
                hue = 60 * (((g - b) / delta).truncatingRemainder(dividingBy: 6))
            } else if maxValue == g {
                hue = 60 * ((b - r) / delta + 2)
            } else {
                hue = 60 * ((r - g) / delta + 4)
            }
        }
        if hue < 0 { hue += 360 }
        let lightness = (maxValue + minValue) / 2
        let shade = (lightest - lightness) / (lightest - darkest)
        return (hue, min(max(shade, 0), 1))
    }

    static func hslToHex(hue: Double, saturation: Double, lightness: Double) -> UInt32 {
        let a = saturation * min(lightness, 1 - lightness)
        func channel(_ n: Double) -> UInt32 {
            let k = (n + hue / 30).truncatingRemainder(dividingBy: 12)
            let value = lightness - a * max(-1, min(k - 3, min(9 - k, 1)))
            return UInt32((min(max(value, 0), 1) * 255).rounded())
        }
        return (channel(0) << 16) | (channel(8) << 8) | channel(4)
    }
}

// MARK: - Icons

nonisolated struct HearthIcon: Identifiable, Hashable, Sendable {
    /// SF Symbols base name.
    let name: String
    let category: String
    /// Lowercased search words, including the words in the name.
    let keywords: [String]
    var id: String { name }

    var accessibilityName: String {
        name.replacingOccurrences(of: ".", with: " ")
    }
}

nonisolated struct HearthIconCategory: Identifiable, Sendable {
    let title: String
    let icons: [HearthIcon]
    var id: String { title }
}

/// Which categories to lean on for suggestions when the name doesn't say much.
nonisolated enum HearthIconContext: Sendable {
    case general, budget, bill, account, room, chore, reward, homeCare, list, device, shelf, person

    var preferredCategories: [String] {
        switch self {
        case .general: []
        case .budget: ["Money", "Shopping", "Food & Drink", "Home", "Bills & Tech", "Getting Around"]
        case .bill: ["Bills & Tech", "Money", "Home", "Health & Care"]
        case .account: ["Money"]
        case .room: ["Home"]
        case .chore: ["Cleaning & Chores", "Home", "Animals & Pets", "Kids & School"]
        case .reward: ["Celebrations & Rewards", "Hobbies & Fun", "Food & Drink"]
        case .homeCare: ["Home", "Work & Tools", "Nature & Weather"]
        case .list: ["Shopping", "Food & Drink", "Travel & Places", "Celebrations & Rewards"]
        case .device: ["Home", "Bills & Tech"]
        case .shelf: ["Reading & Faith", "Kids & School"]
        case .person: ["Family & People"]
        }
    }
}

enum HearthIcons {
    /// The library, minus any symbol this iOS can't draw.
    static let categories: [HearthIconCategory] = {
        var result: [HearthIconCategory] = []
        var title: String?
        var icons: [HearthIcon] = []
        var missing: [String] = []
        func flush() {
            if let title, !icons.isEmpty { result.append(HearthIconCategory(title: title, icons: icons)) }
            icons = []
        }
        for raw in HearthIconLibraryData.table.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("# ") {
                flush()
                title = String(line.dropFirst(2))
                continue
            }
            let parts = line.split(separator: "|", maxSplits: 1).map(String.init)
            guard let name = parts.first, let title else { continue }
            guard UIImage(systemName: name) != nil else {
                missing.append(name)
                continue
            }
            let words = (parts.count > 1 ? parts[1] : "").split(separator: " ").map(String.init)
            icons.append(HearthIcon(name: name, category: title, keywords: words))
        }
        flush()
        #if DEBUG
        if !missing.isEmpty {
            print("HearthIcons: \(missing.count) symbols aren't on this iOS and are hidden: \(missing.joined(separator: ", "))")
        }
        #endif
        return result
    }()

    static let all: [HearthIcon] = categories.flatMap(\.icons)

    static func icon(named name: String) -> HearthIcon? {
        all.first { $0.name == name }
    }

    /// Icons matching every word typed (each word matches the start of a search word).
    static func search(_ query: String) -> [HearthIcon] {
        let typed = HearthIconSearch.tokens(query)
        guard !typed.isEmpty else { return all }
        return all.filter { icon in
            typed.allSatisfy { word in
                icon.keywords.contains { $0.hasPrefix(word) } || icon.category.lowercased().contains(word)
            }
        }
    }

    /// Up to `limit` icons for an item called `name`: words in the name first ("Groceries" →
    /// cart, basket, carrot), then the context's categories.
    static func suggestions(for name: String, context: HearthIconContext, limit: Int = 12) -> [HearthIcon] {
        let tokens = HearthIconSearch.tokens(name).map(HearthIconSearch.forms)
        let preferred = context.preferredCategories
        var scored: [(icon: HearthIcon, score: Int, order: Int)] = []
        for (order, icon) in all.enumerated() {
            var score = 0
            for token in tokens {
                for keyword in icon.keywords {
                    let word = HearthIconSearch.forms(keyword)
                    if !token.isDisjoint(with: word) {
                        score += 6
                    } else if token.contains(where: { t in t.count >= 4 && word.contains { $0.count >= 4 && ($0.hasPrefix(t) || t.hasPrefix($0)) } }) {
                        score += 3
                    }
                }
            }
            if score > 0, let rank = preferred.firstIndex(of: icon.category) {
                score += max(3 - rank, 1)
            }
            if score > 0 { scored.append((icon, score, order)) }
        }
        var result = scored
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }
            .map(\.icon)
        if result.count < limit {
            // Fill from the context's categories so there's always something to pick.
            let seen = Set(result.map(\.name))
            let extra = preferred
                .compactMap { title in categories.first { $0.title == title } }
                .flatMap { $0.icons.prefix(6) }
                .filter { !seen.contains($0.name) }
            result.append(contentsOf: extra)
        }
        return Array(result.prefix(limit))
    }
}

nonisolated enum HearthIconSearch {
    static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    /// The word and its likely singular forms, so "groceries" meets "grocery", "movies" meets
    /// "movie", "dishes" meets "dish" and "bikes" meets "bike". Two words match when their
    /// forms overlap.
    static func forms(_ word: String) -> Set<String> {
        var result: Set<String> = [word]
        guard word.count >= 3 else { return result }
        if word.hasSuffix("ies") {
            result.insert(String(word.dropLast(3)) + "y")
            result.insert(String(word.dropLast()))
        }
        if word.hasSuffix("es") { result.insert(String(word.dropLast(2))) }
        if word.hasSuffix("s"), !word.hasSuffix("ss") { result.insert(String(word.dropLast())) }
        if word.count > 5, word.hasSuffix("ing") { result.insert(String(word.dropLast(3))) }
        return result
    }
}

// MARK: - Showing an icon

/// An icon on its color: the rounded tile the apps use in rows and lists.
struct HearthIconTile: View {
    let icon: String
    let color: HearthColorChoice
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: icon)
            .symbolVariant(.fill)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.color, in: .rect(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// The "Icon & Color" row label: the tile, the title, and the color's name.
struct HearthIconColorLabel: View {
    let icon: String
    let color: HearthColorChoice
    var title: String = "Icon & Color"
    /// Off when the color isn't chosen here (an icon-only picker).
    var showsColorName = true

    var body: some View {
        HStack(spacing: 12) {
            HearthIconTile(icon: icon, color: color, size: 32)
            Text(title)
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            if showsColorName {
                Text(color.name)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityHint(showsColorName ? "Opens the icon and color picker" : "Opens the icon picker")
    }
}

/// The "Color" row label for people: their initial on their color.
struct HearthColorLabel: View {
    let initial: String
    let color: HearthColorChoice
    var title: String = "Color"

    var body: some View {
        HStack(spacing: 12) {
            Text(initial.prefix(1).uppercased())
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(color.color, in: .circle)
                .accessibilityHidden(true)
            Text(title)
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            Text(color.name)
                .foregroundStyle(.secondary)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the color picker")
    }
}

// MARK: - Presenting

extension View {
    /// The Icon & Color picker: a sheet on iPhone, a popover on iPad.
    func hearthIconColorPicker(
        isPresented: Binding<Bool>,
        title: String,
        caption: String? = nil,
        context: HearthIconContext = .general,
        icon: Binding<String>,
        color: Binding<HearthColorChoice>
    ) -> some View {
        popover(isPresented: isPresented, arrowEdge: .top) {
            HearthIconColorPicker(mode: .iconAndColor, title: title, caption: caption, context: context, icon: icon, color: color)
                .frame(idealWidth: 400, idealHeight: 720)
                .presentationCompactAdaptation(.sheet)
                .presentationDragIndicator(.visible)
        }
    }

    /// The icon-only picker, for things whose color is set elsewhere: the icons preview in
    /// `tint`, and there's no color section.
    func hearthIconPicker(
        isPresented: Binding<Bool>,
        title: String,
        caption: String? = nil,
        context: HearthIconContext = .general,
        icon: Binding<String>,
        tint: HearthColorChoice
    ) -> some View {
        popover(isPresented: isPresented, arrowEdge: .top) {
            HearthIconColorPicker(mode: .iconOnly, title: title, caption: caption, context: context, icon: icon, color: .constant(tint))
                .frame(idealWidth: 400, idealHeight: 640)
                .presentationCompactAdaptation(.sheet)
                .presentationDragIndicator(.visible)
        }
    }

    /// The color-only picker, for people: previews the color on their initial.
    func hearthColorPicker(
        isPresented: Binding<Bool>,
        title: String,
        caption: String? = nil,
        color: Binding<HearthColorChoice>
    ) -> some View {
        popover(isPresented: isPresented, arrowEdge: .top) {
            HearthIconColorPicker(mode: .colorOnly, title: title, caption: caption, context: .person, icon: .constant(""), color: color)
                .frame(idealWidth: 400, idealHeight: 520)
                .presentationCompactAdaptation(.sheet)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }
}

// MARK: - The picker

struct HearthIconColorPicker: View {
    enum Mode { case iconAndColor, iconOnly, colorOnly }

    let mode: Mode
    /// The item's name, shown under the preview and used for suggestions.
    let title: String
    var caption: String?
    var context: HearthIconContext
    @Binding var icon: String
    @Binding var color: HearthColorChoice

    @Environment(\.dismiss) private var dismiss
    @State private var originalIcon: String
    @State private var originalColor: HearthColorChoice
    @State private var query = ""
    @State private var category: String?
    @State private var customOpen = false
    @State private var hue: Double
    @State private var shade: Double

    init(mode: Mode, title: String, caption: String? = nil, context: HearthIconContext = .general, icon: Binding<String>, color: Binding<HearthColorChoice>) {
        self.mode = mode
        self.title = title
        self.caption = caption
        self.context = context
        _icon = icon
        _color = color
        _originalIcon = State(initialValue: icon.wrappedValue)
        _originalColor = State(initialValue: color.wrappedValue)
        let start: (hue: Double, shade: Double)
        if case .custom(let hex) = color.wrappedValue {
            start = HearthCustomColor.hueAndShade(of: hex)
        } else {
            start = (hue: 168, shade: 0.45)
        }
        _hue = State(initialValue: start.hue)
        _shade = State(initialValue: start.shade)
    }

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    private var customHex: UInt32 { HearthCustomColor.hex(hue: hue, shade: shade) }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    if !searching {
                        preview
                        if mode != .iconOnly {
                            colorSection
                        }
                    }
                    if mode != .colorOnly {
                        iconSection
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.immediately)
            .background(Color(.systemGroupedBackground))
            .navigationTitle(mode == .colorOnly ? "Color" : mode == .iconOnly ? "Icon" : "Icon & Color")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCancelButton {
                        icon = originalIcon
                        color = originalColor
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    SheetDoneButton { dismiss() }
                }
            }
            .modifier(IconSearch(enabled: mode != .colorOnly, query: $query))
        }
    }

    // MARK: Preview

    private var preview: some View {
        VStack(spacing: 8) {
            Group {
                if mode != .colorOnly {
                    Image(systemName: icon.isEmpty ? "square.dashed" : icon)
                        .symbolVariant(.fill)
                        .font(.system(size: 40, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))
                } else {
                    Text(title.prefix(1).uppercased())
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                }
            }
            .foregroundStyle(.white)
            .frame(width: 84, height: 84)
            .background(color.color, in: .rect(cornerRadius: mode == .colorOnly ? 42 : 22, style: .continuous))
            .shadow(color: color.color.opacity(0.35), radius: 12, y: 8)
            .accessibilityHidden(true)

            Text(title.isEmpty ? "Untitled" : title)
                .font(.title3.bold())
                .padding(.top, 4)
            if let caption {
                Text(caption)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.snappy, value: color)
        .accessibilityElement(children: .combine)
    }

    // MARK: Color

    private var colorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Color")
            VStack(spacing: 0) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 10) {
                    ForEach(HearthPalette.colors) { option in
                        paletteSwatch(option)
                    }
                    customSwatch
                }
                if customOpen {
                    customPanel
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 14)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22, style: .continuous))
            .clipShape(.rect(cornerRadius: 22, style: .continuous))
        }
    }

    private func paletteSwatch(_ option: HearthPaletteColor) -> some View {
        let selected = color == .palette(option.id)
        return Button {
            withAnimation(.snappy) {
                color = .palette(option.id)
                customOpen = false
            }
        } label: {
            ZStack {
                if selected {
                    Circle().strokeBorder(hearthPickerColor(option.hex), lineWidth: 2.5)
                }
                Circle()
                    .fill(hearthPickerColor(option.hex))
                    .frame(width: 34, height: 34)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private static let rainbow = AngularGradient(
        colors: ([0xD93A3A, 0xE8650F, 0xB7791F, 0x1E9E6A, 0x0E8C99, 0x0A7AFF, 0x5856D6, 0x8E4EC6, 0xE0284F, 0xD93A3A] as [UInt32]).map(hearthPickerColor),
        center: .center
    )

    private var customSwatch: some View {
        let selected = color.isCustom
        return Button {
            withAnimation(.snappy) {
                if !selected { color = HearthColorChoice(hex: customHex) }
                customOpen = true
            }
        } label: {
            ZStack {
                // The rainbow ring stays when it's selected, so it still reads as "custom".
                if selected {
                    Circle().strokeBorder(Self.rainbow, lineWidth: 2.5)
                    Circle()
                        .fill(color.color)
                        .frame(width: 34, height: 34)
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Circle()
                        .fill(Self.rainbow)
                        .frame(width: 34, height: 34)
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.primary)
                        .frame(width: 20, height: 20)
                        .background(Color(.secondarySystemGroupedBackground), in: .circle)
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Custom color")
        .accessibilityHint("Shows sliders to make your own color")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var customPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Hue").font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(String(format: "#%06X", customHex))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Capsule()
                    .fill(LinearGradient(
                        colors: stride(from: 0.0, through: 360.0, by: 60.0).map { hearthPickerColor(HearthCustomColor.hex(hue: $0, shade: 0.45)) },
                        startPoint: .leading, endPoint: .trailing
                    ))
                    .frame(height: 10)
                    .accessibilityHidden(true)
                Slider(value: $hue, in: 0...360)
                    .tint(hearthPickerColor(customHex))
                    .accessibilityLabel("Hue")
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Shade").font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("Lighter · Deeper")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Capsule()
                    .fill(LinearGradient(
                        colors: [hearthPickerColor(HearthCustomColor.hex(hue: hue, shade: 0)), hearthPickerColor(HearthCustomColor.hex(hue: hue, shade: 1))],
                        startPoint: .leading, endPoint: .trailing
                    ))
                    .frame(height: 10)
                    .accessibilityHidden(true)
                Slider(value: $shade, in: 0...1)
                    .tint(hearthPickerColor(customHex))
                    .accessibilityLabel("Shade")
            }
            HStack(alignment: .center, spacing: 12) {
                Text("Custom colors stay deep enough for white icons and names to read.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Done") {
                    withAnimation(.snappy) { customOpen = false }
                }
                .font(.subheadline.weight(.bold))
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(hearthPickerColor(customHex))
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 14)
        .onChange(of: hue) { _, _ in color = HearthColorChoice(hex: customHex) }
        .onChange(of: shade) { _, _ in color = HearthColorChoice(hex: customHex) }
    }

    // MARK: Icons

    @ViewBuilder
    private var iconSection: some View {
        if searching {
            let results = HearthIcons.search(query)
            if results.isEmpty {
                ContentUnavailableView.search(text: query)
                    .padding(.top, 40)
            } else {
                iconGrid(results)
            }
        } else {
            LazyVStack(alignment: .leading, spacing: 12) {
                sectionTitle("Icon")
                categoryChips
                if category == nil {
                    let suggested = HearthIcons.suggestions(for: title, context: context)
                    if !suggested.isEmpty {
                        Text(title.isEmpty ? "Suggested" : "Suggested for “\(title)”")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                        iconGrid(suggested)
                    }
                    ForEach(HearthIcons.categories) { section in
                        Text(section.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.top, 6)
                            .accessibilityAddTraits(.isHeader)
                        iconGrid(section.icons)
                    }
                } else if let section = HearthIcons.categories.first(where: { $0.title == category }) {
                    iconGrid(section.icons)
                }
            }
        }
    }

    private var categoryChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                chip("All", selected: category == nil) { category = nil }
                ForEach(HearthIcons.categories) { section in
                    chip(section.title, selected: category == section.title) { category = section.title }
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.hidden)
        .padding(.horizontal, -16)
    }

    private func chip(_ text: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.snappy) { action() }
        } label: {
            Text(text)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .padding(.horizontal, 14)
                .frame(minHeight: 34)
                .background(selected ? color.color : Color(.tertiarySystemFill), in: .capsule)
                .frame(minHeight: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func iconGrid(_ icons: [HearthIcon]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 48, maximum: 60), spacing: 8)], spacing: 8) {
            ForEach(icons) { option in
                iconTile(option)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22, style: .continuous))
    }

    private func iconTile(_ option: HearthIcon) -> some View {
        let selected = option.name == icon
        return Button {
            withAnimation(.snappy) { icon = option.name }
        } label: {
            Image(systemName: option.name)
                .symbolVariant(.fill)
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .frame(width: 48, height: 48)
                .background(selected ? color.color : Color(.tertiarySystemFill), in: .rect(cornerRadius: 14, style: .continuous))
                .overlay {
                    if selected {
                        RoundedRectangle(cornerRadius: 17, style: .continuous)
                            .strokeBorder(color.color, lineWidth: 2)
                            .padding(-4)
                    }
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.accessibilityName)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .textCase(.uppercase)
            .tracking(0.5)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Native search in the navigation bar, only when the picker shows icons.
private struct IconSearch: ViewModifier {
    let enabled: Bool
    @Binding var query: String

    func body(content: Content) -> some View {
        if enabled {
            content
                .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search icons, like rent or soccer")
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        } else {
            content
        }
    }
}

#Preview("Icon & Color") {
    @Previewable @State var icon = "cart"
    @Previewable @State var color = HearthColorChoice.palette("green")
    HearthIconColorPicker(mode: .iconAndColor, title: "Groceries", caption: "Budget", context: .budget, icon: $icon, color: $color)
}

#Preview("Color only") {
    @Previewable @State var color = HearthColorChoice.palette("purple")
    HearthIconColorPicker(mode: .colorOnly, title: "Ella", caption: "Family member", context: .person, icon: .constant(""), color: $color)
}
