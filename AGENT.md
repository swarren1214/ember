# AGENT.md — Ember

Rules for anyone (person or agent) changing Ember's code. README.md says how the app is built.
Ember follows the same conventions as every Hearth app; the ones that bite most are below.

## Privacy (never break these)

- Every cloud request goes through `EmberRedactor` (Shared/EmberRedactor.swift) on the device
  that sends it, iPhone or Watch. Household names become [P1]-style tokens; other names [N1];
  emails, phone numbers, addresses, links and card or account numbers are removed. The token
  map never leaves the device.
- Tools send conclusions, never records. Allergies are checked on the device and only "fits
  everyone: yes/no" leaves it. Budgets return the figure asked about.
- Nothing identifies the person to a model: hearth-api sends Anthropic no account id, device id,
  IP or `metadata.user_id`, and keeps nothing but token counts.
- Kids' turns never leave the device.
- Never put conversation text in logs (`privacy: .public`), analytics or crash reports.
- Never promise "nothing leaves your device" in copy; say what's true: de-identified, minimal,
  never your identity.

## Ember never writes other apps' data

Ember reads the Hearth app group (HearthShared.swift publications) and hands changes to the app
that owns the data with that app's link or App Intent, as every Hearth app does.

## Voice

The orb is the one moving part (Shared/EmberOrb.swift, compiled into both apps). Answers are
spoken: one to three short sentences, cards carry the detail. Kokoro `af_heart` on iPhone (the
model is shared with Sated and Hearken through `group.com.stephenwarren.voice`), the system voice
until it's downloaded and on Apple Watch.

## Liquid Glass menus with icons

- Every menu item's icon must be the same **color** as its text: label-colored text gets a
  label-colored icon, and a destructive item's red text gets a red icon. Menus tint icons with
  the app's accent (set at the root) while the titles stay in the text color, so don't use
  `systemImage:` in menus. Use the helpers in `DesignSystem/MenuIcon.swift` instead:
  `Button("Rename", menuIcon: "pencil") { … }`, `Menu("Sort", menuIcon: …) { … }`,
  `Toggle("…", menuIcon: …, isOn: …)`, or `Label { Text("…") } icon: { Image.menuIcon("…") }`
  (pass `role: .destructive` for red). The only exception is a color swatch in a color picker.
- When a menu item is a checkmark selection (picking one option, or toggling options on and off),
  the checkmark goes on the **right** side of the item. iOS 26's native menus draw selection
  checkmarks on the left (a `Picker` or `Toggle` inside a `Menu`, or a `checkmark` symbol in the
  item's label, which takes the icon's place), so selection menus use the app's right-checkmark
  menu component instead — this is the one place a custom control beats the native one.
  This app doesn't have one yet; don't fake it with a `checkmark` label.

## App color

The app's color (its accent, which the root `.tint` passes to everything below it) is for things
large or bold enough to stay legible in it. It's never for menus or running text.

- **The app's color is fine for:**
  - Large titles and big numbers (`.largeTitle`, `.title` and up, a hero figure or a stat).
  - Icons that stand on their own: an icon tile with a white glyph, a large feature or empty-state
    symbol, the selected tab on the iPhone tab bar.
  - Components: toggles, sliders, steppers' fills, progress bars and rings, charts, selection
    highlights, the filled `SheetDoneButton`, and filled or prominent buttons with white text.
- **Never use the app's color for:**
  - Menus: a menu's button or label, its items, their icons and their checkmarks (see the menu
    rules above).
  - A menu-style `Picker`'s value (the "Stars ⌃⌄" beside a row's title).
  - Standard text: body, callout, subheadline, footnote and caption text, links, and buttons whose
    label is text, such as an action row in a `Form` or `List`.
  - Headers: section headers, list headers and small all-caps labels.
  - Small icons: a symbol beside a row's title, inside a `Label`, inline with text, or in a
    small toolbar or row button.
  These use the text color: `.primary` (black in Light Mode, white in Dark Mode), or `.secondary`
  for supporting text and small icons that aren't part of a button (see
  the next rule). A destructive action stays red.
- **A button's icon is always the same color as its text**, unless Steve explicitly asks for an
  exception. This covers every tappable thing with a label: `Button`, `Link`, `ShareLink`,
  `PhotosPicker`, a `Menu`'s label, and a tappable row (`NavigationLink` or `Button`) in a `List`
  or `Form`. Text in the text color gets an icon in the text color, a destructive button's text
  and icon are both red, and a filled button's text and icon are both white. Never color the icon
  on its own: no `.foregroundStyle` on just the `Image`, no `LabelStyle` that tints or greys the
  icon, and no row icon left to pick up the app's color from the root `.tint` while its title
  stays in the text color (put `.tint(.primary)` on the row or its `Section`). A filled icon tile
  (a white glyph on a colored square, as in the Settings app) is a component, not the button's
  icon, and is fine.
- **Approved exceptions** (Steve asked for these; keep them): the iCloud Sync card's Sync Now
  button (`HearthSyncCard` in HearthSync.swift) is a bordered capsule with a light wash of the
  app's color and its icon and text in the app's color.
- The root `.tint` leaks the app's color into every control that doesn't set its own color. So
  put `.tint(.primary)` on a `Menu`, a menu-style `Picker`, and a text `Button` in a `Form` or
  `List` row. Never use `.foregroundStyle` with the app's color (or `.tint`/`Color.accentColor`)
  on text or small symbols.
- Even where it's allowed, use the app's color only where it stays legible against what's behind
  it in both Light and Dark Mode. A dark accent on a dark background, a light accent on white, or
  the accent on an accent-tinted fill all fail. When in doubt, use the text color.

## Sheet buttons

- A sheet with both Done and Cancel at the top (Save, Add and Create count as Done) uses
  `SheetDoneButton` and `SheetCancelButton` from `DesignSystem/SheetButtons.swift`:
  - **Done** is a circular checkmark button filled with the app's color, with a white icon.
  - **Cancel** is a circular X button with no colored background, its icon in the text color
    (black in Light Mode, white in Dark Mode).
  Put them in `.confirmationAction` and `.cancellationAction`:
  `ToolbarItem(placement: .confirmationAction) { SheetDoneButton("Save") { save() } }`.
  Keep the title (it's read by VoiceOver); only the icon shows.

## Prefer native

Prefer native iOS capabilities and components over custom ones: system controls, `List`/`Form`,
`Menu`, `Picker`, sheets, toolbars, search, `ShareLink`, SF Symbols, system colors and Dynamic
Type, and Apple frameworks over hand-built versions. Build something custom only when nothing
native does the job, and match the system's look and behavior when you do.

## Confirmations

When an action needs confirming (deleting, erasing, signing out, leaving), always use a native
alert (`.alert` with a `role: .destructive` button and a Cancel button) rather than a native
popup or popover (`.confirmationDialog`, action sheet, `.popover`, a custom card or sheet),
unless explicitly told otherwise.

- **Alert button colors:** every button in an alert uses the standard text color (black in
  Light Mode, white in Dark Mode), never the app's color. Only a destructive action's button
  is different: the standard red, from `role: .destructive`. The app sets this once at launch
  with `UIView.appearance(whenContainedInInstancesOf: [UIAlertController.self]).tintColor =
  .label`; don't tint alert buttons yourself, and don't color a destructive button any other
  way than its role.

## Shared Hearth code

`Services/Hearth/` and `Assets.xcassets/Hearth` are copies. Edit the originals in
`~/Developer/hearthkit` and run `bash sync.sh ember/Ember` there; never edit a copy.
