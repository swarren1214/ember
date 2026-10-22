# Ember

The voice of the Hearth apps: a voice-first assistant for iPhone and Apple Watch that answers
from BigTable, Suffice, Caloma and Hearken. Design: the "Ember · Hearth AI" canvas. Plan: the
"Ember: Implementation Plan" doc (routing, privacy, Watch modes, phases).

## Status: Phase 1 foundation (October 22, 2026)

Builds in Xcode (iPhone app, Watch app and tests), and the redactor tests pass in the iPhone 17
Simulator. Not yet run on a real iPhone or Apple Watch: the voice, the on-device model and Kokoro
need hardware.

| Area | State |
| --- | --- |
| iPhone voice loop | SpeechAnalyzer listening, the orb, idle/listening/thinking/answer screens, Kokoro or system voice sentence by sentence, barge-in |
| On-device model | Foundation Models session with Ember's tools (Services/Brain/EmberTools.swift) |
| Cloud (Claude) | `POST /v1/ember/turn` in hearth-api, streamed; tools run on the device; de-identified |
| Private Cloud Compute | Not wired: needs the iOS 27 PCC entitlement and API. The router has the tier (`EmberTier.privateCloud`) |
| Writes | Hand-offs only (open the owning app, draft a text). HearthRecords writes are Phase 2 |
| Apple Watch, tethered | Dictation → iPhone runs the turn → Watch speaks it |
| Apple Watch, standalone | Its own Sign in with Apple session → hearth-api directly, redactor on the Watch, the day's facts the iPhone last shared as its one tool. Live iCloud reads are Phase 4 |
| Paradee on Watch | Not yet: system voice until the Phase 0 benchmark passes |
| Siri / Action button | `TalkToEmberIntent`, `AskEmberIntent`, App Shortcuts; `ember://listen`, `ember://ask?q=` |

## Project layout

```
Ember/                 iPhone app
  App/                 Entry point, AppConfig, App Intents, links
  DesignSystem/        Theme, sheet buttons, menu icons
  Features/Home/       The one screen and its cards
  Features/Profile/    HearthKit Profile with What Ember Knows, first-run Cloud Help choice
  Services/Brain/      Context (Hearth app group), toolbox, on-device tools, the router (EmberBrain), settings
  Services/Voice/      Audio engine, conversation (SpeechAnalyzer), speaker, Kokoro
  Services/Account/    EmberAPI: the shared Hearth sign-in (adapted from Sated)
  Services/Watch/      WatchConnectivity relay
  Services/Hearth/     HearthKit copies (sync.sh) — don't edit
  Resources/Kokoro/    kokoro-voices.bin (from Sated)
Shared/                Both apps: the orb, the redactor, the hearth-api client, wire types
EmberWatch/            Watch app: model, standalone brain, account, speaker, screens
Packages/              KokoroSwift and MisakiSwift (Hearken's vendored copies, via Sated)
```

## What Ember reads

Today, what the Hearth apps already publish to `group.com.stephenwarren.hearth`:

| File | From | Ember uses it for |
| --- | --- | --- |
| `bigtable.meal-plan.json` | BigTable | Meals by day, who isn't eating, ingredients for the allergy check |
| `bigtable.groceries.json` | BigTable | Items left and the estimate (counts only, not the items) |
| `suffice.grocery-budget.json` | Suffice | Grocery budget left, spent, limit |
| `caloma.allowance.json` | Caloma | Allowance paid per kid |
| `hearken.reading.json` | Hearken | Today's reading and whether it's done |
| `*.household.json` | Every app | Who's who (HearthHouseholdStore, started as `.ember`) |

To answer the prototype's other questions, these apps need to publish more (new
`HearthPublication`s in HearthKit):

- Caloma: today's chores per kid, and the family calendar's next 48 hours.
- Suffice: safe-to-spend and the categories nearest their limit (not only groceries).
- BigTable: grocery item names (so "is milk on the list?" works).

## HearthKit

Ember is `HearthApp.ember` (added October 22, 2026). It's in `sync.sh`'s list but not in
`HearthAppInfo.order`, like Trove, so the other apps' Hearth Apps page doesn't list it yet.
The other apps pick up the new case the next time `sync.sh` runs for them; nothing in their
own code switches over `HearthApp`. Update only Ember with `bash sync.sh ember/Ember`.

## Before the first TestFlight

1. Developer portal: App IDs `com.stephenwarren.ember` and `.watchkitapp`, with App Groups
   (`group.com.stephenwarren.hearth`, `group.com.stephenwarren.voice`), iCloud
   (`iCloud.com.stephenwarren.hearth`), Sign in with Apple, Push.
2. A real app icon (the current one is a generated placeholder) and the Ember color (coal
   `#2B1D17` in HearthKit is a placeholder too).
3. hearth-api: set `ANTHROPIC_API_KEY` (already set for BigTable) and deploy; apply for zero
   data retention on its Anthropic organization.
4. Privacy Policy and App Privacy labels: de-identified cloud processing, opt-in.
