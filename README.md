# 3D FFT Radar DSP Engine

RTL for an FMCW MIMO radar Range → Doppler → Angle processing pipeline,
targeted at the KC705 Evaluation Board (Kintex-7 XC7K325T).

**Frozen spec: 1024 range × 256 Doppler × 4 RX antennas.** As of 3 Sep these
are the RTL *defaults*, not values you have to remember to pass. A reduced
size must be requested explicitly, and an elaboration-time assertion fails
loudly if the cube dimensions ever stop matching the configured FFT
transform lengths.

## Layout

```
rtl/               synthesisable RTL (the 13 files both build scripts compile)
tb/                testbenches
scripts/           build, elaborate, simulate, cleanup
constraints/       XDC
vivado_ip_kc705/   generated xfft_0 IP -- every script depends on this, do not delete
ctm_test/          MIG DDR3 IP for the real corner turn
docs/              design notes, plans, reports, figures
attic/             superseded RTL and stale results, kept for history
reports/           synthesis output (regenerated)
```

Root holds only the three live documents: this file, `ARCHITECTURE_3D.md`
(design + verification record), `SPEC_FROZEN.md` (the contract), plus
`MASTER_CONTEXT.md` and the two build entry points.

**This file was stale as of 2 Sep** — it described the retired single-lane
stub (`radar_dsp_top.v` + `ctm_tiled_pingpong.v`), both now in `attic/`.
Corrected to match what's actually built. Full detail, module cost table,
BLK_EXP flow, and the corner-turn contract are in **`ARCHITECTURE_3D.md`** —
read that first.

## Current top level

`rtl/radar_dsp_3d_top.sv` — 4 antenna lanes in parallel (one 128-bit AXI4-Stream
beat carries all 4 antennas of one cell):

```
128b in -> unpack -> 4x [window + Range FFT] -> pack -> [CORNER TURN, placeholder]
        -> unpack -> 4x [Doppler FFT] -> pack -> [Angle FFT, combinational]
        -> unpack -> 4x [|X|^2 -> CA-CFAR] -> pack -> 128b out
```

## Corner turn — not built here

`rtl/ctm_stub.sv` is a behavioural placeholder only, not synthesizable at
real cube size. The real DDR-backed block is being built separately; its
contract (address formula, ping-pong, backpressure, bandwidth budget) is
documented in that file's header and in `ARCHITECTURE_3D.md`.
`tb/tb_ctm_transpose.sv` is the acceptance test for it.

## Verification

Nothing below has been run as of 2 Sep — see `ARCHITECTURE_3D.md` for the
required order and current status.

```powershell
$env:Path += ";C:\Xilinx\2025.1\Vivado\bin"
.\scripts\run_unit_tests.ps1                        # 1. seconds, no IP
vivado -mode batch -source scripts/check_elab.tcl    # 2. elaborate only
vivado -mode batch -source build_synth.tcl           # 3. full synthesis
```

## Retired

`attic/` holds superseded RTL, testbenches, and build scripts (the old
single-lane stub, the broken transpose, an angle-FFT that was a shift
register, and everything that pointed at them) — kept for history, not
part of the current build.
