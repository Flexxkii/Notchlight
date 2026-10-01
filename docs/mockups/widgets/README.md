# Notchlight widget concepts

Created 18 September 2026 using the built-in image-generation tool.

These are visual mockups with illustrative sample usage values, not implemented widgets or live account readings. The desktop attachment supplied by the user guided the dark surfaces and lunar setting. The existing app screenshot supplied the app identity and feature vocabulary.

| Concept | Image | Intent |
| --- | --- | --- |
| 1. Notch Gauge | [01-notch-gauge.png](01-notch-gauge.png) | Small square; a distinctive notch-shaped gauge, one allowance window, activity and reset time. |
| 2. Dual Limits | [02-dual-limits.png](02-dual-limits.png) | Medium; compare five-hour and weekly allowances with two progress rings. |
| 3. Status & Controls | [03-status-and-controls.png](03-status-and-controls.png) | Medium; two usage bars, notch preview, border visibility toggle and Settings entry. |
| 4. Monthly Square | [04-monthly-square.png](04-monthly-square.png) | Square companion to the approved Dual Limits style; one monthly allowance ring. |

The user selected the Dual Limits direction. The matching monthly square and its generation prompt are documented in [monthly-square-prompt.md](monthly-square-prompt.md).

Visual review: all three images were inspected for readable labels, app identity, and distinct information hierarchy. These are enlarged concept presentations; native-size layout, interaction, accessibility and WidgetKit behavior remain implementation work. No app code was changed.

## Generation prompts

### 1. 01-notch-gauge.png

```text
Use case: ui-mockup.
Primary request: a finished, high-fidelity macOS desktop widget concept for Notchlight, a native Mac utility that displays Codex usage around the MacBook notch.
Input images: Image 1 is the user's desktop screenshot: use it ONLY as a visual reference for dark charcoal native macOS widget materials, generous rounded corners and the grayscale lunar wallpaper. Image 2 is the existing Notchlight settings screenshot: use it ONLY for the app identity, red rounded U-shaped notch icon, thin electric-blue usage outline, and actual feature vocabulary.
Create one standalone PNG-style mockup image, landscape 1536 x 1024 composition. The backdrop is an elegant close crop of the same dark lunar desktop, mostly black at top, subtly detailed gray craters crossing the lower portion. One single native widget is the focus, shown straight-on, no perspective, no computer hardware. Large enough for every label to read easily. Treat this as a screenshot-quality interface, not an illustration or product advertisement. Near-black translucent charcoal widget fill, subtle 1px gray perimeter, soft restrained shadow, continuously rounded corners. SF Pro-like native Apple typography, white primary and readable light-gray secondary text. Blue usage accent, small warm red U app mark. Green only for the working status dot. Deliberate visual hierarchy, clean alignment, balanced spacing. No heavy glass refraction, no neon flood, no chart decoration, no gradients inside typography, no invented marketing copy, no watermarks, no browser chrome, no additional apps or other widgets, no external captions. All values are illustrative sample data, not actual live account data.
Concept 1 of 3: NOTCH GAUGE, a small square widget, approximately 600 x 600 visual pixels centered in the canvas (representing the native small widget family). Exactly square with about 64px corner radius.
Inside widget:
- Small header on top: small red U-shaped app mark, then exact text "Notchlight".
- Main centerpiece: a broad U-shaped usage gauge, an open-topped outline evoking a MacBook notch, with very rounded lower corners. Full track is muted charcoal gray. Overlay approximately 52 percent of the track in electric blue, beginning at top-left and following the path downward then around the lower-left bend and partway across the base, clearly indicating partial progress. Use crisp 8px stroke at this enlarged scale and an extremely restrained glow.
- Nestled in the open center of the U: very large clear exact text "52%"; below it exact text "5-hour remaining".
- Below the gauge, center a small green dot next to exact text "Codex is working".
- Bottom footer in light gray exact text "Resets in 2h 12m".
No additional labels or buttons. The visual identity is the U-shaped gauge, not a circular ring. Keep generous breathing space. Minimal, native, instantly readable.
```

### 2. 02-dual-limits.png

```text
Use case: ui-mockup.
Primary request: a finished, high-fidelity macOS desktop widget concept for Notchlight, a native Mac utility that displays Codex usage around the MacBook notch.
Input images: Image 1 is the user's desktop screenshot: use it ONLY as a visual reference for dark charcoal native macOS widget materials, generous rounded corners and the grayscale lunar wallpaper. Image 2 is the existing Notchlight settings screenshot: use it ONLY for the app identity, red rounded U-shaped notch icon, thin electric-blue usage outline, and actual feature vocabulary.
Create one standalone PNG-style mockup image, landscape 1536 x 1024 composition. The backdrop is an elegant close crop of the same dark lunar desktop, mostly black at top, subtly detailed gray craters crossing the lower portion. One single native widget is the focus, shown straight-on, no perspective, no computer hardware. Large enough for every label to read easily. Treat this as a screenshot-quality interface, not an illustration or product advertisement. Near-black translucent charcoal widget fill, subtle 1px gray perimeter, soft restrained shadow, continuously rounded corners. SF Pro-like native Apple typography, white primary and readable light-gray secondary text. Blue usage accent, small warm red U app mark. Green only for the working status dot. Deliberate visual hierarchy, clean alignment, balanced spacing. No heavy glass refraction, no neon flood, no chart decoration, no gradients inside typography, no invented marketing copy, no watermarks, no browser chrome, no additional apps or other widgets, no external captions. All values are illustrative sample data, not actual live account data.
Concept 2 of 3: DUAL LIMITS, one medium horizontally rectangular widget approximately 1150 x 550 visual pixels centered in the canvas (representing native medium widget family), ratio about 2.1:1, approximately 66px corner radius.
Inside widget:
- Header at upper-left small red U-shaped app mark and exact text "Notchlight". Upper-right small green dot and exact text "Working".
- Two equally weighted side-by-side usage summaries, separated by a very subtle short vertical divider. The layout is intentionally inspired by the native battery widget in Image 1, using two confident circular progress gauges.
- Left circular blue progress ring shows 52 percent with large white exact text "52%" in its center. Below the number inside or just below the ring, concise label "5-hour". Under the ring exact text "Resets in 2h 12m".
- Right circular blue progress ring shows 76 percent with large white exact text "76%" in its center. Label "Weekly". Under the ring exact text "Resets in 3d 8h".
- Exact small header or subheader text "Remaining" clearly governs both percentages.
Give each circle a charcoal unused-track portion and crisp blue used track proportional to the REMAINING value shown, so 52% and 76% arc lengths are visibly distinct. Progress begins at 12 o'clock. No extra icons in the circles. No other controls or labels. The emphasis is calm, glanceable comparison of the two allowance windows. No invented charts or forecasts.
```

### 3. 03-status-and-controls.png

```text
Use case: ui-mockup.
Primary request: a finished, high-fidelity macOS desktop widget concept for Notchlight, a native Mac utility that displays Codex usage around the MacBook notch.
Input images: Image 1 is the user's desktop screenshot: use it ONLY as a visual reference for dark charcoal native macOS widget materials, generous rounded corners and the grayscale lunar wallpaper. Image 2 is the existing Notchlight settings screenshot: use it ONLY for the app identity, red rounded U-shaped notch icon, thin electric-blue usage outline, and actual feature vocabulary.
Create one standalone PNG-style mockup image, landscape 1536 x 1024 composition. The backdrop is an elegant close crop of the same dark lunar desktop, mostly black at top, subtly detailed gray craters crossing the lower portion. One single native widget is the focus, shown straight-on, no perspective, no computer hardware. Large enough for every label to read easily. Treat this as a screenshot-quality interface, not an illustration or product advertisement. Near-black translucent charcoal widget fill, subtle 1px gray perimeter, soft restrained shadow, continuously rounded corners. SF Pro-like native Apple typography, white primary and readable light-gray secondary text. Blue usage accent, small warm red U app mark. Green only for the working status dot. Deliberate visual hierarchy, clean alignment, balanced spacing. No heavy glass refraction, no neon flood, no chart decoration, no gradients inside typography, no invented marketing copy, no watermarks, no browser chrome, no additional apps or other widgets, no external captions. All values are illustrative sample data, not actual live account data.
Concept 3 of 3: STATUS & CONTROLS, one medium horizontally rectangular widget approximately 1150 x 550 visual pixels centered in the canvas (representing native medium widget family), ratio about 2.1:1, approximately 66px corner radius.
Inside widget:
- Top-left small red U-shaped app mark and exact text "Notchlight"; top-right small green dot and exact text "Codex is working".
- Middle area has two regions: left 40 percent is a miniature black MacBook notch silhouette hanging from a thin horizontal top screen edge, with a thin electric-blue U-shaped partial outline around its lower perimeter and a very restrained blue glow; this references the app's physical notch feature. Place exact text "Border active" below the miniature notch. No camera preview or imagery inside notch.
- Right 60 percent is a precise two-row usage meter area. First row shows exact label "5-hour" left and exact value "52% remaining" right, with a thin blue horizontal progress bar filled 52% beneath, and exact smaller gray text "Resets in 2h 12m". Second row shows exact label "Weekly" left and exact value "76% remaining" right, with blue horizontal progress bar filled 76% beneath. Each bar rests on a charcoal track.
- Thin subtle separator above bottom row.
- Footer: exact label "Show border" at left paired with an ON-state native macOS blue switch immediately to its right. Right-aligned compact understated rounded native button with gear icon and exact label "Settings".
Clearly maintain large readable text and native control dimensions, ample margins, and no crowded or nested cards. This is a concept for quick border visibility control and status, using only functions that already exist in Notchlight. No animation or live-update claims.
```
