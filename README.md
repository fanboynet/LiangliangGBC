# LiangliangGBC
A GameBoy/GameBoy Color emulator written in Pascal(Delphi).

<img src="./screen/cpu_instrs.png" width="200"> <img src="./screen/mario.png" width="200"> <img src="./screen/supermario.png" width="200">

**Controls:**
- **W/A/S/D**: Up/Left/Down/Right
- **Z/X**: Select/Start
- **J/K**: Button A/B

**Compiler：**
- **Windows(Delphi)**: dcc32 -B -Q .\GBEmuSDL.dpr

**Run:**
- **Windows**: .\GBEmuSDL.exe '.\Super Mario Bros. Deluxe (Japan) (NP).gbc' --scale=3
- **Set Window Size(Default=1)**: --scale=4
- **Set Screen Linear filtering(>2x window,Default --linear)**: --linear / --nearest



