# LiangliangGBC

Delphi-based Game Boy Color emulator framework.

## Structure
- `GBCEmu.dpr`: GUI entry point.
- `src/`: Core emulator units.

## Getting Started
Open `GBCEmu.dpr` in Delphi, build, then run:
Delphi-based Game Boy Color emulator skeleton.

## Structure
- `GBCEmu.dpr`: Console entry point.
- `src/`: Core emulator units.

## Getting Started
Open `GBCEmu.dpr` in Delphi/Lazarus-compatible IDE, build, then run:

```
GBCEmu <path_to_rom>
```

The application opens a window, runs the emulator loop, and renders the PPU frame buffer.
This is an initial framework with placeholders for CPU/PPU/APU and memory mapping.
