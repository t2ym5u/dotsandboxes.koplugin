# Changelog

All notable changes to this project will be documented in this file.

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
