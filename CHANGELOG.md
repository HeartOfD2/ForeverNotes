# Changelog — ForeverNotes

## 0.1.0 (beta)

First release for the World of Warcraft Forever beta (Interface 16001).

### Windows
- The ForeverNotes window (`/forevernotes`, `/fnotes`, or the addon compartment) has every page: Notebook, Players
  and Settings. It can be moved and resized, remembers its size and page, closes with Esc and opens in combat too.
- A button in its title bar switches to the mini window for playing on the side; the mini window has a button back.
- Minimap button: left-click opens ForeverNotes, right-click the mini window, drag to move; can be hidden. The
  addon list entry (addon compartment) behaves the same way; with the EllesmereUI section active, left-click opens it.
- EllesmereUI is optional. With it installed, the same pages can also appear in the EllesmereUI options window,
  section **Notes** (Settings › General › Integrate into EllesmereUI; takes effect after `/reload`).
- Language: automatic (EllesmereUI, else the game), or English / German in the settings.

### Looks
- Themes: Standard (neutral dark, fresh blue), EllesmereUI (while it is installed), Classic, Parchment, Midnight,
  Frost, Light.
- Accent colour for every theme: theme default, EllesmereUI accent, class colour or an own colour (12 quick colours
  or any colour from the colour picker). Buttons, switches, tabs, the popup glow and sticky notes follow it live.
- Font for all texts: EllesmereUI's font (while it is installed), the game's font, Arial Narrow, or the bundled
  Barlow, Fira Sans, Inter and Source Code Pro in regular, semibold and bold. The list shows every name in its font,
  hovering shows a large sample beside it, and the settings page shows a sample sentence in the chosen font.
- Sharp icons at every UI scale (drawn on the screen's pixel grid).
- A blinking cursor in every text field and in the note editor.
- Select text with the mouse: drag over a note's formatted text to start writing with that part selected; the
  selection is drawn in the accent colour in the editor and in every text field.

### Notes, players, drawings
- Notebook with coloured groups, checklists, bullet and numbered lists.
- Player notes with a target popup that can be collapsed and glows when notes exist; last seen time.
- Drawings with pen, eraser, line, rectangle, ellipse, colours, line widths, undo and redo.
- Ignore list with warning sound, chat line, red popup mark and optional sync with the game's ignore list.
- Sticky notes for notes and drawings: fold, lock, resize, dock.
- Export and import as a text code: everything at once, or ticked notes, drawings or player notes (grouped by group
  or player; a group or player ticks all of its notes), optionally with the ignore list.
