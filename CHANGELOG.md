# Changelog

All notable changes to this project will be documented in this file.

## [1.1.1] - 2026-11-04

### Changed
- Uses less memory: the game loads when you open it, not when KOReader
  starts, so it no longer takes memory or startup time while unplayed.

## [1.1.0] - 2026-11-04

### Changed
- Hard never thinks longer than about 2.5 s on an e-reader (its longest
  6×6 searches took over 3 s on a Kobo). When it has to stop early it plays
  Medium's move as before, or a better one it had already proved.

## [1.0.3] - 2026-11-03

### Changed
- Picks up game-common 1.11.0: the shared on-screen keyboard (where used)
  gives every key the same letter size, and the no-repeat history helper.

## [1.0.2] - 2026-11-02

### Changed
- Picks up game-common 1.10.0: the shared Tools → Games menu also lists
  the games' new "· multiplayer" entries under Party & quiz.

## [1.0.1] - 2026-11-02

### Changed
- Listed under **Tools → Games**, grouped by category, instead of its own
  entry in the Tools menu (game-common 1.9.1).

## [1.0.0] - 2026-10-30

### Added
- Dots and Boxes on 3×3, 4×4, 5×5 or 6×6 boxes. Claimed boxes show a black
  square (Black) or a framed white square (White); the lines of the last turn
  are drawn hollow.
- Tap anywhere near a line to draw it: every box is split into four triangles,
  one per side. A tap right on a dot is ignored rather than guessed.
- Against the computer (play Black or White) or two players on one device.
- Computer opponent with three levels. Hard searches the endgame exactly,
  including the double-cross and the hard-hearted handout.
- Undo (against the computer, takes back its reply and your line together),
  auto-save and restore of the game in progress.
