---
name: Porthole
description: A cinematic, console-like iOS app for playing PC games: deep slate glass, one glowing accent, and the game's own artwork behind everything.
colors:
  slate-deep: "#1B2838"
  slate-abyss: "#0B121B"
  signal-blue: "#4CB8F5"
  soft-violet: "#7A6CFF"
  on-accent: "#06101F"
  text: "#F1F5F9"
  text-dim: "#9DB0C3"
  good: "#34D399"
  warn: "#FBBF24"
  bad: "#FB7185"
  glass-fill: "rgba(199, 213, 224, 0.075)"
  glass-fill-high: "rgba(199, 213, 224, 0.14)"
  glass-edge: "rgba(199, 213, 224, 0.14)"
  glass-shaded: "rgba(5, 8, 15, 0.5)"
  glass-shaded-high: "rgba(5, 8, 15, 0.62)"
  scrim-chip: "rgba(0, 0, 0, 0.55)"
typography:
  display:
    fontFamily: "SF Pro Rounded, system-ui, sans-serif"
    fontSize: "42px"
    fontWeight: 800
    lineHeight: 1.05
  headline:
    fontFamily: "SF Pro Rounded, system-ui, sans-serif"
    fontSize: "22px"
    fontWeight: 700
  title:
    fontFamily: "SF Pro Rounded, system-ui, sans-serif"
    fontSize: "16px"
    fontWeight: 700
  body:
    fontFamily: "SF Pro Rounded, system-ui, sans-serif"
    fontSize: "15px"
    fontWeight: 500
  label:
    fontFamily: "SF Pro Rounded, system-ui, sans-serif"
    fontSize: "12px"
    fontWeight: 800
    letterSpacing: "0.13em"
rounded:
  stepper: "9px"
  panel: "16px"
  tile: "18px"
  full: "999px"
spacing:
  chip-gap: "8px"
  row-gap: "12px"
  tile-gap: "14px"
  section-gap: "18px"
  gutter-phone: "16px"
  gutter: "24px"
  gutter-wide: "32px"
components:
  button-primary:
    backgroundColor: "{colors.signal-blue}"
    textColor: "{colors.on-accent}"
    typography: "{typography.title}"
    rounded: "{rounded.full}"
    padding: "12px 22px"
    height: "44px"
  button-glass:
    backgroundColor: "{colors.glass-fill-high}"
    textColor: "{colors.text}"
    typography: "{typography.title}"
    rounded: "{rounded.full}"
    padding: "12px 22px"
    height: "44px"
  panel-row:
    backgroundColor: "{colors.glass-fill}"
    textColor: "{colors.text}"
    rounded: "{rounded.panel}"
    padding: "10px 14px"
    height: "56px"
  game-tile:
    rounded: "{rounded.tile}"
  chip-badge:
    backgroundColor: "{colors.scrim-chip}"
    textColor: "{colors.text}"
    rounded: "{rounded.full}"
    padding: "4px 8px"
---

# Design System: Porthole

## Overview

**Creative North Star: "The Lit Porthole"**

Porthole is a round window onto a deep, calm room, and the light in that room is the game. The background is a dark slate gradient; the chosen game's own artwork runs behind the top bar and the page, softly blurred; one accent glows where the person's attention is. It should feel cinematic and console-like: big artwork, strong contrast between light and deep, everything reachable from a thumb or a D-pad.

The surfaces are tactile and confident. Controls are large capsules and rounded tiles that spring a little when pressed, a gradient on the main action (Play), and a glow ring that marks what is selected. Panels are see-through glass with hairline edges, so the picture and the glow show faintly through them. Nothing is flat, grey or utilitarian, and nothing shouts: the artwork does the talking and the interface is the calm frame around it.

The default scheme is Deep Sea. Other schemes (Aurora, Sunset, Ember, Orchid, Graphite, seasonal ones, or a colour the person picks) swap the slate and the two accent colours and nothing else, so every rule below holds for all of them.

**Key Characteristics:**
- The game's artwork sits behind the bar and the page, blurred lightly, with the text over it. (Binding.)
- Type is rounded system type: SF Pro Rounded, heavy for titles. (Binding.)
- Glass panels over a glowing deep background; the accent is the only light.
- Large, tactile controls with spring press feedback; a glow ring marks selection.
- Works by touch, controller and keyboard: the same screen, the same focus ring.
- A plain, honest voice in labels ("Not yet tested", "Runs rough"), never hype.

## Colors

A deep slate with a cool, restrained palette, and a single glowing blue-to-violet accent. Colour carries status, not decoration.

### Primary
- **Signal Blue** (#4CB8F5): the main accent. Play, the selection glow, the active tab line, links and values in rows. The person can swap it (a scheme or any colour they pick).
- **Soft Violet** (#7A6CFF): the second accent. It is only ever the far end of the accent gradient (Play, the glow ring, highlights), never used alone.

### Neutral
- **Slate Deep** (#1B2838) to **Slate Abyss** (#0B121B): the background gradient, top left to bottom right. The tint follows the chosen scheme.
- **Cold Text** (#F1F5F9): primary text and icons on the dark surfaces.
- **Mist** (#9DB0C3): secondary text, captions and inactive labels.
- **Panel Glass** (a pale blue-grey, #C7D5E0, at 7.5% opacity): the fill of cards and rows. At 14% it is the fill of secondary buttons, hairline edges and dividers.
- **Night Ink** (#06101F): text and icons that sit on top of the accent.

### Status
- **Playable Green** (#34D399): works, ready, connected.
- **Amber Warning** (#FBBF24): partial, runs rough, needs attention.
- **Coral Fault** (#FB7185): fails, errors, destructive.

### Named Rules
**The One Light Rule.** The accent is the only thing that glows. Selection, the main action and the active section use it; nothing else is lit.
**The Status Is Not Decoration Rule.** Green, amber and coral mean exactly "works", "partly" and "fails". They are never used for emphasis.
**The Shade-When-Light Rule.** Where a game's picture can be light, glass surfaces get darker (Shaded Glass: night-ink at 50 to 62% opacity), so words keep their contrast. Do not fix legibility by dimming the picture further.

Light-appearance values exist in the code for the surfaces and text, but the app is dark only today.

## Typography

**Display Font:** SF Pro Rounded (the system rounded design)
**Body Font:** SF Pro Rounded
**Label/Mono Font:** SF Pro Rounded; a monospaced digit variant for counts and speeds

**Character:** one friendly, rounded family at several weights. Weight, not a second typeface, makes the hierarchy: heavy for game names, bold for buttons, medium for descriptions.

### Hierarchy
- **Display** (heavy, 42px, 28px held sideways, line 1.05): the chosen game's name, with a soft shadow over the artwork.
- **Headline** (bold, 22px): the title of an empty state or a dialog.
- **Title** (bold, 16px): buttons, row titles, card titles.
- **Body** (medium, 15px; footnote 13px): game details, row subtitles, helper lines under groups.
- **Label** (heavy, 12px, letter-spacing 0.13em, uppercase): the small eyebrow above a title ("CONTINUE PLAYING", "YOUR LIBRARY") and section headings.

### Named Rules
**The Rounded Voice Rule.** Everything is set in the rounded family. A second typeface is never introduced.
**The Shouts-Are-Small Rule.** Uppercase is only for small spaced labels, never for titles or buttons.

Sizes are fixed points today (the app does not follow Dynamic Type); a pass for it is open work.

## Layout

A full-screen, edge-to-edge frame: a slim top bar (logo, section words, help and clock) over a page that fills the rest, with the picture behind both. Pages are sized to the screen rather than scrolling where they can (Home), or scroll one way (library lists, game pages).

Gutters are 16px on a phone, 24px by default and 32px on an iPad. Rows are at least 56px high. Tiles sit 14px apart, groups 18 to 22px apart, chips 8px apart. A phone held sideways has very little height, so the bar, chips and tiles slim down; an iPad gets larger tiles (230 to 270px wide).

Sections the person moves between are plain words in the bar with a sliding accent line under the chosen one; they never scroll sideways. On a game's page the layout splits in two when wide: the game on the left, its settings scrolling on the right.

## Elevation & Depth

Depth comes from translucent glass over a glowing background and from the picture behind it, with soft shadows used sparingly.

### Shadow Vocabulary
- **Chosen tile** (`box-shadow: 0 8px 14px rgba(0,0,0,0.45)`): lifts the selected game; unchosen tiles use `0 4px 8px rgba(0,0,0,0.25)`.
- **Accent glow** (`box-shadow: 0 2px 12px` of the accent at 45% of the glow setting): under the Play button and around the focus ring. The person can set glow to Off, Soft or Strong.
- **Title shadow** (`text-shadow: 0 2px 10px rgba(0,0,0,0.55)`): keeps a game's name legible over its picture.

### Named Rules
**The Flat-Until-Chosen Rule.** Surfaces are flat glass at rest; lift and glow appear on the chosen or focused item.
**The Picture Reaches Under Rule.** The artwork is drawn behind the top bar as well as the page, never starting at the bar's lower edge; the bar and the page read as one screen.

## Shapes

Soft, continuous corners throughout. Game tiles and the picture cards have an 18px radius, panels and rows 16px, small steppers 9px. Buttons, chips, tabs and the layout picker are full capsules. Edges are hairlines (1px) of the pale glass colour, a little brighter at the top. Icons are SF Symbols in a rounded square tile, 32px in rows.

## Components

Tactile and confident: large touch targets (44px minimum, most 56px), a spring when pressed (scale 0.97), and a glow ring when selected by touch, D-pad or keyboard.

### Buttons
- **Shape:** full capsule, 44px high, 12px by 22px padding.
- **Primary (Play):** the signal-blue to soft-violet gradient with night-ink text and an accent glow.
- **Glass (Details, Settings):** pale glass at 14% with a hairline edge and cold text. On light pictures it uses Shaded Glass.
- **Danger:** coral text on a 14% coral fill.
- **Press:** scales to 0.97 with a quick spring.

### Chips
- **Style:** capsules. Status and badge chips sit on a black 55% scrim with a coloured hairline; the store chip uses the store's mark; the controller pill uses its level's colour.
- **State:** a badge's colour is its status (green, amber, coral, or mist for "Not yet tested").

### Cards / Containers
- **Corner Style:** 16px for panels and rows, 18px for game tiles.
- **Background:** panel glass, never an opaque card.
- **Shadow Strategy:** see Elevation; panels have none.
- **Border:** hairline glass edge, brighter at the top.
- **Internal Padding:** 10 to 14px in rows, 12px in stat tiles.

### Navigation
- **Top bar:** logo mark, then the sections as plain words (selected: heavy and bright with an accent line that slides; others: mist). The bar is transparent over the picture and slims on a phone held sideways.
- **Layout picker:** three icons in a dark capsule, pinned to the right of Home's top row.
- **Game row:** a row of art tiles; the first is the chosen one and is drawn largest, with the others slightly smaller.

### Game Tile (signature)
The game's artwork at about 2.1:1, 18px corners, a bottom shade for the badges, a status badge top left, the store badge bottom right and a controller pill bottom left. The chosen tile is bright and ringed; the others are slightly dimmed.

### Home Hero (signature)
An eyebrow label, the game's name in display type with a shadow, a line of facts, a row of chips, then Play and Details. It sits over the blurred artwork.

## Do's and Don'ts

### Do:
- **Do** draw the chosen game's artwork behind the top bar and the page, lightly blurred (about 2.5px) with the shade at the very top, so the bar and the page read as one screen.
- **Do** set every piece of text in the rounded system family, heavy for game names and bold for buttons.
- **Do** make glass surfaces darker (Shaded Glass) on screens over a picture that can be light.
- **Do** use the accent for selection, the main action and the active section only.
- **Do** make everything reachable by touch and by controller, with the same glow ring on whatever is selected.
- **Do** keep labels plain and honest ("Not yet tested", "Runs rough").

### Don't:
- **Don't** introduce a second typeface or a sharp-cornered, flat utilitarian control.
- **Don't** start a picture at the bar's lower edge or draw an opaque bar over it.
- **Don't** use green, amber or coral for emphasis; they mean works, partly and fails.
- **Don't** hide the artwork under opaque cards; panels stay see-through glass.
- **Don't** fix a hard-to-read screen by dimming its picture further; shade the glass instead.
- **Don't** put uppercase on titles or buttons.
