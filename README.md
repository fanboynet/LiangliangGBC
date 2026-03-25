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

**模拟器流程**
```mermaid
flowchart TD
    A["启动前端程序<br/>GBEmuSDL.exe"] --> B["创建核心对象<br/>TCartridge + TGBMMU + TCpu (+ TGBAPU + TGBPPU + TGBTimer + TGBJoypad)"]
    B --> C["LoadROM<br/>读取 ROM 文件到 Cartridge"]
    C --> D["解析 Cartridge Header<br/>MBC 类型 / ROM-RAM banks / CGB 标志"]
    D --> E["MMU.Reset + CPU.Reset<br/>按 DMG/CGB 初始化寄存器与内存映射"]
    E --> F["绑定回调<br/>CPU<->MMU 读写, MMU->PPU/APU/Timer/Joypad, 串口输出"]

    F --> G["主循环开始"]

    G --> H["处理输入事件<br/>键盘 -> Joypad P1 状态"]
    H --> I["运行一帧或若干 CPU cycles"]

    I --> J["CPU.Step 取指/译码/执行"]
    J --> K["指令访存通过 MMU.Read8/Write8<br/>映射 ROM/VRAM/WRAM/OAM/IO"]
    K --> L["MBC Bank切换/外部 RAM 访问<br/>(在 Cartridge 内处理)"]

    J --> M["OnTick 推进外设时钟"]
    M --> N["Timer.Update<br/>DIV/TIMA/TMA/TAC + Timer IRQ"]
    M --> O["PPU.Update<br/>mode2/3/0/1, 扫描线渲染, VBlank/STAT IRQ"]
    M --> P["APU.Update<br/>4 声道 + frame sequencer + 混音采样"]
    M --> Q["Serial/Joypad/ DMA/HDMA/KEY1 双速 等 MMU 逻辑"]

    O --> R["PPU 生成 framebuffer<br/>DMG 调色或 CGB palette"]
    P --> S["APU 生成 PCM 样本<br/>左右声道"]

    R --> T["前端渲染输出<br/>SDL Texture+Present"]
    S --> U["音频输出<br/>SDL_QueueAudio（或对应宿主音频设备）"]

    T --> V["用户看到画面"]
    U --> W["用户听到声音"]

    V --> G
    W --> G

```

**代码流程**
```mermaid
flowchart LR
    A["前端入口<br/> GBEmuSDL.dpr"] --> B["gb_core.TGBCore<br/>统一编排层"]

    B --> C["gb_cart.TCartridge<br/>ROM加载/头解析/MBC映射"]
    B --> D["gb_cpu.TCpu<br/>取指译码执行"]
    B --> E["gb_mmu.TGBMMU<br/>总线与地址映射中心"]

    E --> C
    E --> F["gb_ppu.TGBPPU<br/>LCD时序与像素生成"]
    E --> G["gb_apu.TGBAPU<br/>4声道与混音"]
    E --> H["gb_timer.TGBTimer<br/>DIV/TIMA/IRQ"]
    E --> I["gb_joypad.TGBJoypad<br/>P1输入与IRQ"]

    D -- "OnRead8/OnWrite8" --> E
    D -- "OnTick/OnBusAccess/OnIDUOp" --> E
    E -- "IRQ置位(IF)" --> D

    C -- "ReadROM/ReadRAM/WriteROM/WriteRAM" --> E
    E -- "VRAM/OAM/IO回调" --> F
    E -- "音频寄存器读写+Update" --> G
    E -- "FF04-FF07访问+Update" --> H
    E -- "FF00访问" --> I

    J["ROM文件"] --> C
    K["键盘事件"] --> I

    F --> L["Framebuffer(160x144)"]
    G --> M["PCM样本(L/R)"]

    L --> N["SDL: BuildFrame+Present"]
    M --> O["SDL音频队列/宿主音频设备"]

    N --> P["显示画面"]
    O --> Q["播放音乐/音效"]

```

