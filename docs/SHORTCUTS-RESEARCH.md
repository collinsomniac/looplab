# LoopLab × Shortcuts: Research Brief (Oct 2026, iOS 26–27)

Labels: **[V]** = verified, with a source. **[I]** = my inference or general App Intents knowledge that I did not re-check against a page.

## 1. Apple's built-in AI actions

| Action | Inputs | Outputs | Limits / notes |
|---|---|---|---|
| **Use Model** | Prompt text with variables. Inputs can be variables, calendar events, reminders, photos, etc. [V¹]. On iOS 27 it also takes text, audio, documents and images [V⁴]. App entities are passed as JSON built from their exposed properties, type name, title and subtitle [V²]. | **Output** menu. "Automatic" infers the type from the next action, e.g. Boolean when it feeds an If [V²]. Explicit types include Text (rich text and AttributedString), Dictionary, and **the entity type you passed in**, e.g. a filtered list of events [V²]. The output has a **Transcript** property for debugging [V³]. Number, Date and List are explicit types too [I]. | Models: **On-Device, Cloud (PCC), Cloud Pro (PCC, extended context), Extension Model = ChatGPT** [V¹]. Cloud and Cloud Pro have a "Use Broad World Knowledge" toggle (web) [V¹]. A **Follow Up** checkbox shows the response and lets you refine it before passing it on [V¹][V²]. The action is "designed to be deterministic" [V³]. Cloud has daily usage limits [V¹]. On-device context was ~4,096 tokens in iOS 26 [V⁵, third party]. PCC model has 32K context and reasoning [V⁶]. No temperature, seed or model-choice controls are exposed [I]. |
| **Writing Tools**: Summarize Text, Rewrite Text, Proofread Text, Adjust Tone of Text, Make List from Text, Make Table from Text | Text (plus tone/style where relevant) | Text / rich text | Added in iOS 26 [V⁷]. No prompt, schema or length control [I]. |
| **Image Playground: Create Image** | Prompt (plus style) | Image | iOS 26 [V⁷]. Image generation runs on PCC [V⁸]. |
| **Open Visual Intelligence** | none | Opens the UI | iOS 26 [V⁷]. It only launches the UI and returns no data to the shortcut [I]. |
| Translate Text / Detect Language, Transcribe Audio, Extract Text from Image | Text, audio or image | Text | Older non-generative actions. Transcribe was improved in iOS 26 [V⁷]. |
| iOS 26/27 **Storage** actions (Get/Set, global values synced via iCloud) | Any value, including entities | Value | Apple suggests them as "memory" for Use Model [V³]. |

**Can a third-party app plug its model into "Use Model"? Not as far as public docs show.** No document I found says so.
- Apple's iOS 27 support page lists exactly four choices: On-Device, Cloud, Cloud Pro, and "Extension Model: Uses ChatGPT" [V¹].
- The iOS 27 `LanguageModel` / `LanguageModelExecutor` protocols do let any provider (MLX, Core AI, Claude, Gemini) back a `LanguageModelSession`. They ship as Swift packages that **your own app** links [V⁹][V¹⁰][V¹¹]. Session 339 shows `MLXLanguageModel(modelID:)` as a drop-in model [V¹⁰].
- Press reports (Bloomberg, via secondary sites) describe an iOS 27 "Extensions" system that lets ChatGPT, Gemini and Claude power **Siri, Writing Tools and Image Playground**. Those reports are about big-provider App Store apps [V¹², secondary/rumor]. The official developer pages I checked have no matching extension-point documentation [V⁸].
- **Inference:** LoopLab, a sideloaded app, cannot become a "Use Model" backend. It has to win as a parallel set of actions. It should still adopt `LanguageModel` internally (MLX-backed) so it shares the FoundationModels API: `Generable`/`DynamicGenerationSchema`, tools, transcripts. That also positions it for any future extension point.

## 2. Third-party Shortcuts packs: the patterns that work

**Actions (Sindre Sorhus)** offers 180+ free actions [V¹³]. They are small, typed, single-purpose utilities:
- Lists and dictionaries: filter, sort, merge, JSONPath get/set, Parse CSV/JSON5
- Text transforms: case, slugify, transliterate, trim, "Calculate String Distance" for fuzzy matching
- Dialogs: "Ask for Input with Dialog" returns both the text and the button tapped, with a timeout
- Device state: "Is …" Boolean checks
- Extended HTTP: status codes, headers, timeout
- Utilities: Keychain, Counter, Global Variable, Manage Shortcut Lock

Its FAQ says some actions must open the app, which users complain about [V¹³].

**Similar packs** (my summary, not re-verified) [I]:
- **Toolbox Pro**: 130 actions incl. OCR, NFC, global variables [V¹⁴]
- **Data Jar**: a key-path store
- **Jayson**: JSON viewing and editing
- **Scriptable** / **a-Shell**: run JS or shell, return any value
- **Pushcut**: notifications with action buttons and server triggers
- **Charty**: chart images from lists

**Patterns that make actions feel native:**

| Pattern | Mechanism |
|---|---|
| Model and conversation pickers | `AppEntity` + `EntityQuery` (`suggestedEntities`, `EntityStringQuery`). Use `EntityPropertyQuery` to get an auto-generated "Find …" action [V²]. |
| Fixed choices | `AppEnum` with `caseDisplayRepresentations`. Use a `DynamicOptionsProvider` for runtime lists. |
| Hide advanced params | `ParameterSummary` with `When(\.$x, .equalTo, …)` / `Switch`. Put temperature, seed, etc. below the fold. |
| Defaults / optional | `@Parameter(default:)`, `inclusiveRange` for numbers, `requestValueDialog`. |
| Richer types (iOS 27) | `Duration` and `PersonNameComponents` params. `@UnionValue` lets one param accept several types, e.g. text or file [V¹⁵]. |
| Files | `IntentFile` with `supportedContentTypes`. Return `IntentFile` for images, CSV, JSON. |
| Typed results | `ReturnsValue<String / Double / Bool / [T] / IntentFile / Entity>`. Shortcuts has no generic Dictionary return type. The workaround is JSON text plus "Get Dictionary from Input", or an `AppEntity` with `@Property` fields [I]. |
| UI | `ProvidesDialog`, `ShowsSnippetView`. Interactive snippets via `SnippetIntent` (iOS 26) [V¹⁶]. |
| Run mode | `supportedModes` (iOS 26): `.background`, `.foreground(.immediate/.dynamic/.deferred)`. It replaces the deprecated `ForegroundContinuableIntent` [V¹⁷]. Mid-run promotion uses `continueInForeground` [I]. |
| Long work | **`LongRunningIntent` (iOS 27)**: `performBackgroundTask(options: .requiresGPU)`. It shows progress as a **Live Activity** and has `onCancel`. Progress must be reported regularly or the extension is cancelled [V¹⁵][V¹⁸]. |
| Process choice | iOS 27 **`ExecutionTargets`** chooses main app, AppIntentsExtension, or widget [V¹⁵]. |
| Errors | `CustomLocalizedStringResourceConvertible` errors. Throw them instead of returning sentinel text [I]. |
| Discovery | `AppShortcutsProvider` phrases, `IndexedEntity` for Spotlight [V¹⁹]. |

**Limits:**
- The default background budget is **30 s** on iOS. `LongRunningIntent` extends it [V¹⁸].
- App Intents extensions are separate lightweight processes [V¹⁵]. Their memory cap is undocumented. In practice it is far too small for a multi-GB MLX model [I]. So model intents must run in the **main app process** (`ExecutionTargets` main app), not in an extension.

## 3. Prioritized recommendations for LoopLab

| # | Action / change | Mechanism |
|---|---|---|
| 1 | **Make every generation intent a `LongRunningIntent`** using `performBackgroundTask(options: [.requiresGPU])`. Report progress in phases: load (bytes mapped), prefill (tokens), then decode (tokens / max tokens) in `localizedAdditionalDescription`. That gives a free Live Activity. Use `onCancel` to stop decoding and free the KV cache. Pin to the main app with `ExecutionTargets`. Set `supportedModes = [.background, .foreground(.dynamic)]` and replace the "Open LoopLab" toggle with `continueInForeground` when memory or thermal state requires it. | `LongRunningIntent`, `ProgressReportingIntent`, `supportedModes` [V¹⁵][V¹⁷][V¹⁸] |
| 2 | **Extract (Schema → Dictionary)**. Params: input (text/file), schema, instructions, model. Schema can be a JSON-Schema text, a field list (`name:type:description`), or an "Example JSON" mode. Build a `DynamicGenerationSchema` and use constrained decoding (grammar/JSON mode in MLX). Return valid JSON text; it becomes a Dictionary via "Get Dictionary from Input" or Automatic coercion. Add an **Extracted Record** AppEntity with common `@Property` fields for tap-through. | FoundationModels `DynamicGenerationSchema` [V⁹]; `ReturnsValue<String>` |
| 3 | **Typed answer actions**: "Ask Yes/No" → `Bool`, "Extract Number" → `Double`, "Extract Date" → `Date`, "Extract List" → `[String]`. These match Use Model's Automatic typing, which Apple shows feeding If [V²]. | `ReturnsValue<Bool/Double/Date/[String]>`; constrained decoding |
| 4 | **Classify / Route** (extends Decide). Labels come from a list or an `AppEnum`-like dynamic list, with multi-label, threshold and fallback. Return a **Classification** entity (label, confidence, all scores) plus the plain label. Keep Score Options; also return a list of label entities sorted by probability. | `AppEntity` result; `DynamicOptionsProvider` |
| 5 | **Writing Tools parity, but better**: Summarize, Rewrite, Proofread, Adjust Tone, Make List, Make Table. Each gets length/format `AppEnum`s, a language option, and a model picker. Return rich text via `AttributedString` (Apple recommends it for model output [V²]). Make Table should also return a CSV `IntentFile`. | `AppEnum`, `ReturnsValue<AttributedString>`, `IntentFile` |
| 6 | **Chat with history**. A `Conversation` AppEntity with an `IndexedEntity` query, holding a persisted transcript and a KV-cache snapshot. Actions: New Conversation, Send Message (returns reply + conversation), Get Transcript, Delete. This replaces Follow Up and survives runs, unlike Apple's in-run Follow Up. Use stable IDs; consider `SyncableEntity` [V¹⁵]. Add an optional `.foreground(.dynamic)` chat snippet. | `AppEntity`, `EntityQuery`, `SnippetIntent` [V¹⁶] |
| 7 | **File and image inputs** on Generate, Extract and Summarize. Accept PDF, text and images via `IntentFile`, or `@UnionValue` for text-or-file [V¹⁵]. Use a VLM for images when the chosen model supports it, otherwise Vision OCR. Chunk long PDFs with map-reduce summaries. | `IntentFile`, `@UnionValue` |
| 8 | **Embeddings / Similarity**: Embed Text (JSON vector or file), Similarity(a, b) → `Double`, Rank Items by Relevance (query, list) → sorted list, Find Duplicates. Use a small embedding model kept resident for speed. A semantic **Index** entity (add/search) enables local RAG. | `ReturnsValue<Double / [String]>` |
| 9 | **Model UX**: add `@Property` fields to the model entity (size, context length, quantization, vision support, loaded state). Add `Find Models` via `EntityPropertyQuery`. "Fast/Balanced/Thorough" should map to models as well as effort. Hide temperature, seed and max tokens behind `ParameterSummary When`. | `EntityPropertyQuery`, `ParameterSummary` |
| 10 | **Load-time strategy**: (a) Load Model gets "Keep Warm for N min" (`Duration` param [V¹⁵]), but the OS may still evict it. (b) Pick a default small model for background use; Auto falls back to it when the large model isn't resident. (c) Throw typed errors (`modelNotLoaded`, `insufficientMemory`, `thermalThrottled`) with recovery text. (d) Add a Get Model Status action returning Bool/Number. | `Duration` param, custom errors |
| 11 | **Debuggability**: return a Generation Result entity (text, tokens in/out, tokens/sec, model, seed, transcript), mirroring Apple's Transcript property [V³]. | `AppEntity` result |
| 12 | **Discovery**: `AppShortcutsProvider` phrases ("Summarize with LoopLab"), Spotlight-indexed conversations and prompts, and a saved "Prompt Template" entity with `{{vars}}`. Third-party packs sell templates as a feature [V⁵]. | `AppShortcutsProvider`, `IndexedEntity` |

**Where LoopLab can be clearly better than Apple** [I]:
- Model choice, seed and temperature, which Apple's action doesn't expose
- Larger local context
- Schema-guaranteed JSON
- Confidence scores
- Persistent conversations
- Embeddings
- Fully offline, with no daily caps

## Sources
1. Apple, Use Apple Intelligence in Shortcuts (iOS 27): https://support.apple.com/guide/shortcuts/use-apple-intelligence-in-shortcuts-tpg3vrvwmclv/ios
2. WWDC25 "Develop for Shortcuts and Spotlight with App Intents": https://developer.apple.com/videos/play/wwdc2025/260/
3. WWDC26 "What's new in Shortcuts": https://developer.apple.com/videos/play/wwdc2026/310/
4. GeeksModo, iOS 27 intelligent actions: https://geeksmodo.com/shortcuts-apple-intelligence/
5. ShortcutActions blog: https://www.shortcutactions.com/blog/how-to-use-apple-intelligence-in-your-shortcuts
6. WWDC26 "What's new in the Foundation Models framework": https://developer.apple.com/videos/play/wwdc2026/241/
7. Apple, What's new in Shortcuts 26: https://support.apple.com/en-us/125148
8. Apple Intelligence developer page: https://developer.apple.com/apple-intelligence/
9. FoundationModels docs: https://developer.apple.com/documentation/foundationmodels (LanguageModel, LanguageModelExecutor are iOS 27)
10. WWDC26 "Bring an LLM provider to the Foundation Models framework": https://developer.apple.com/videos/play/wwdc2026/339/
11. What's new in iOS 27: https://developer.apple.com/ios/whats-new/
12. AI2Work, citing Bloomberg, on iOS 27 Extensions: https://ai2.work/blog/apple-opens-ios-27-to-third-party-ai-models-with-extensions-framework
13. Actions by Sindre Sorhus: https://sindresorhus.com/actions
14. Toolbox Pro: https://toolboxpro.app
15. WWDC26 "Discover new capabilities in the App Intents framework": https://developer.apple.com/videos/play/wwdc2026/345/
16. SnippetIntent: https://developer.apple.com/documentation/appintents/snippetintent
17. supportedModes / ForegroundContinuableIntent (deprecated): https://developer.apple.com/documentation/appintents/foregroundcontinuableintent
18. LongRunningIntent: https://developer.apple.com/documentation/appintents/longrunningintent
19. WWDC26 "Explore advanced App Intents features for Siri and Apple Intelligence": https://developer.apple.com/videos/play/wwdc2026/343/
