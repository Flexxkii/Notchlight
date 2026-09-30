# Monthly square widget

Created 18 September 2026 with the built-in image-generation tool.

The user selected the dual-ring design and requested a square companion displaying a single monthly allowance. This mockup uses illustrative values and the user's requested monthly label; it is not a statement of current subscription entitlements.

- [Square monthly widget](04-monthly-square.png)
- [Approved dual widget](02-dual-limits.png)

The new image was visually inspected for matching styling, legible text, one monthly progress ring, and the absence of five-hour or weekly data. These remain visual concepts; no application code changed.

## Prompt

```text
Use case: ui-mockup.
Create a new SMALL SQUARE version of the supplied Notchlight DUAL LIMITS macOS widget design.
Input image 1 is the approved visual design reference. Preserve its design language closely: dark charcoal native macOS widget surface, fine gray border, continuous rounded corners, native SF Pro-style typography, warm red U-shaped Notchlight icon, bright blue circular usage ring, charcoal unused portion, and grayscale lunar desktop wallpaper. This is a visual adaptation of that approved design, not a new art direction.
Output one high-fidelity image at landscape 1536 x 1024. Place ONE single square widget, approximately 650 x 650 pixels, centered on the same dark moon desktop. Entire card must be exactly square, with the same understated materials and proportions as a native macOS small widget. Show it straight-on, crisp and readable.
The requested variation displays ONLY a MONTHLY allowance. Never include a five-hour allowance, weekly allowance, a second ring, or an empty placeholder.
Layout:
- Header: small original red U app icon at upper-left, then exact text "Notchlight". Keep the branding restrained and native.
- Small centered gray subheading "Remaining".
- One centered blue circular progress ring, approximately 350px diameter, with a 22px stroke at this enlarged mockup scale. It starts at 12 o'clock and runs clockwise for exactly 76 percent of the circumference, leaving the remaining 24 percent muted charcoal. Rounded stroke endpoints.
- Within this ring: large white exact text "76%" and below it smaller soft-gray exact text "Monthly".
- Centered below the ring: exact text "Resets in 12d 8h" in legible gray.
- Bottom status line: a small green dot and exact text "Working".
Make this feel like the small member of the SAME widget family as the approved medium dual-ring widget. Clean spacing, compact hierarchy, no cramped rows, consistent left/right padding. All values are illustrative mockup content.
Avoid: U-shaped meter, controls, buttons, pro badges, plan names, price claims, new branding, glossy glass refraction, giant logo, neon bloom, gradients in text, 3D perspective, devices, browser frames, captions outside the widget, other widgets, watermarks.
```
