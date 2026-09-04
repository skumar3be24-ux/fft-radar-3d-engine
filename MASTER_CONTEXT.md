# Master Context — Radar FFT Engine Project

Complete record of the design, the constraints found, the solutions evaluated, and the
proposed migration to Kintex-7. Written so the whole project can be picked up from this
document alone.

**Status at time of writing:** 1-D FFT engine complete, synthesised, implemented, verified.
3-D scaling blocked on a memory constraint. Kintex-7 KC705 proposed as the resolution.

---

# PART 1 — What we are building

## 1.1 The system

A hardware accelerator for **3-D FMCW MIMO radar**. "3-D" means three *measurement*
dimensions, not a 3-D transform:

| dimension | measured by transforming along | gives us |
|---|---|---|
| Range | samples within one chirp | how far away |
| Doppler | across chirps | how fast it is moving |
| Angle (AoA) | across RX antennas | which direction |

## 1.2 Why an FFT gives range

An FMCW radar transmits a tone whose frequency ramps linearly — a *chirp*. The echo returns
after a round-trip delay, by which time the transmitter has moved to a higher frequency.
Mixing the two produces a low-frequency *beat*:

```
f_beat = (2 * R * S) / c        R = range, S = chirp slope, c = 3e8 m/s
```

Further target → longer delay → higher beat frequency. An FFT of the beat signal therefore
sorts targets by distance: **bin index = range**. That is the Range FFT.

## 1.3 The processing chain

```
ADC -> input buffer -> RANGE FFT -> corner turn -> DOPPLER FFT -> corner turn
    -> ANGLE FFT -> magnitude -> CFAR detection -> DDR
```

**Critical property: a multidimensional DFT is separable.** There is no such thing as a
"3-D butterfly." Every 3-D FFT ever built is three sets of 1-D FFTs along orthogonal axes
with transposes between them. The transposes are the corner turns. This is why the
architecture looks the way it does.

## 1.4 Block ownership

| block | owner |
|---|---|
| Input interface, ping-pong buffer | team |
| Window function | **unassigned** |
| **FFT engine** | **us — complete** |
| Corner turn memory | teammate |
| Magnitude, CFAR | **unassigned** |
| DMA / DDR / PS | team |

---

# PART 2 — The FFT engine as built

**Complete, synthesised, implemented with timing met, verified in simulation.**

## 2.1 Frozen specification

Every value traced to the project specification. None chosen for convenience.

| Parameter | Value | Why |
|---|---|---|
| Device | xc7z020clg400-1 | 220 DSP / 140 BRAM36 / 53,200 LUT |
| Clock | 100 MHz, PS `FCLK_CLK0` | PS-derived: no extra MMCM, no CDC to AXI-HP |
| Transform size | 1024 / 2048, runtime switchable | Range resolution vs frame rate, selectable live |
| FFT core | Xilinx FFT IP v9.1 | Verified IP; custom RTL saves nothing (§2.7) |
| Architecture | Pipelined Streaming I/O | Only xfft mode sustaining 1 sample/clock |
| Radix | Radix-2 (internally 2²) | Determined by the architecture choice |
| Input | complex {Q,I}, 16-bit Q1.15 | IQ baseband; real-only folds negative frequencies |
| Twiddle | 16-bit Q1.15 | Matches data width, sets phase-noise floor |
| Scaling | Block Floating Point | Preserves dynamic range on weak returns |
| Rounding | Convergent (half-to-even) | Truncation biases toward −∞, builds a DC term |
| Output order | Natural | Consumers index bins directly |
| Throughput | 1 sample/clock = 100 MSPS | Streaming, no gaps between frames |
| Backpressure | Full, Non-Realtime throttle | Core stalls rather than dropping samples |
| Lanes | `NUM_LANES` parameter | One lane per RX antenna |

**Q1.15** — a 16-bit signed integer *v* represents *v*/32768, range −1.0 to +0.99997.
A sample at 0.4 full scale is `round(0.4 × 32767) = 13107`.

**Block Floating Point** — output stays 16-bit; a shared exponent `BLK_EXP` is reported per
frame. True bin value = 16-bit value × 2^`BLK_EXP`. Per-frame automatic gain: a weak chirp
is scaled up rather than lost in the low bits.

> **Consumer warning:** `BLK_EXP` applies to the *complex* output. If a downstream block
> squares the data for power, the scale becomes 2^(2×`BLK_EXP`). Missing this gives a
> factor-of-two error in dB.

## 2.2 Architecture

```
   upstream                +======================================+          downstream
   (input buffer)          |          FFT ENGINE                  |          (output proc)
                           |                                      |
 {Q,I} Q1.15 32b  ------>  | skid -> [xfft v9.1] -> skid          | ------>  {Im,Re} 32b
                           |   ^         |                        |          + TUSER=BLK_EXP
 nfft_sel        ------>   | config    status                     |
                           |  FSM      drain                      |
                           +======================================+
```

```
fft_engine_top                  NUM_LANES replication, flattened buses
 └── fft_lane  [generate]
      ├── axis_skid   (in)      register slice, breaks tready path
      ├── fft_config_fsm        config channel, runtime N, frame fencing
      ├── xfft_0                Xilinx FFT IP v9.1
      ├── fft_status_capture    status drain, owns m_axis_status_tready
      └── axis_skid   (out)     register slice + TUSER carry
```

| module | function | latency | cost |
|---|---|---|---|
| `fft_engine_top` | Structural, parameter fan-out | 0 | — |
| `fft_lane` | One lane; owns frame-active tracker | — | — |
| `axis_skid` | AXI-Stream register slice, full throughput | 1 each | ~70 FF |
| `fft_config_fsm` | Builds/issues config word, re-arms on N change | 1 | ~50 LUT |
| `xfft_0` | The transform | ~2N | 24 DSP, 18 RAMB18 |
| `fft_status_capture` | Drains status, latches BLK_EXP | 1 | ~40 LUT/FF |

## 2.3 Interface contract

**This is the part that determines whether the block integrates. Everything else is internal.**

| signal | width | meaning |
|---|---|---|
| `s_axis_tdata` | 32 | `{Q[15:0], I[15:0]}` Q1.15, imaginary upper half |
| `s_axis_tvalid/tready` | 1 | Full backpressure; tready must not be tied high |
| `s_axis_tlast` | 1 | Asserted on sample N−1 |
| `m_axis_tdata` | 32 | `{Im[15:0], Re[15:0]}` Q1.15, scaled by 2^BLK_EXP |
| `m_axis_tuser` | 8 | **BLK_EXP**, constant across all N beats |
| `m_axis_tlast` | 1 | Asserted on bin N−1 |
| `nfft_sel_i` | 1 | 0 = 1024, 1 = 2048. Latched at frame boundary only |
| `nfft_applied_o` | 5 | log2(N) currently loaded: 10 or 11 |
| `busy_o`, `blk_exp_dbg_o` | 1, 8 | Status / CSR readback, **not** the datapath |

## 2.4 Measured results — implementation, routed

Vivado 2025.1, `xc7z020clg400-1`, out-of-context, `NUM_LANES = 1`.

| resource | post-route | synthesis | available | % |
|---|---:|---:|---:|---:|
| LUT | **3,909** | 4,036 | 53,200 | 7.3 % |
| FF | **6,816** | 6,871 | 106,400 | 6.4 % |
| DSP48E1 | **24** | 24 | 220 | 10.9 % |
| RAMB18 | **18** | 18 | 280 | 6.4 % |
| RAMB36 | 0 | 0 | 140 | 0 % |

```
WNS = +2.735 ns   setup, post-route  ->  critical path 7.265 ns, Fmax ~138 MHz
WHS = +0.013 ns   hold,  post-route  ->  MET
```

38 % setup margin at 100 MHz. Wrapper logic is only ~163 FF / ~90 LUT of the total; the rest
is the IP.

**On the hold figure.** +0.013 ns looks alarming and is not. The worst hold paths are
internal `FDRE → RAMB18E1` data-input paths inside the IP, zero logic levels. `route_design`
fixes hold by adding routing detour and stops the moment slack is positive, because hold
padding costs setup margin — small positive WHS is the signature of a route that succeeded.
BRAM data pins also have large hold requirements (0.296 ns here, vs ~0.03 ns for a slice FF),
so FF→BRAM paths are the tightest hold paths in almost any BRAM-using design. Reported at
the Fast Process Corner, already pessimistic for hold.
*Caveat that survives:* `HD.CLK_SRC` is unset in OOC, so clock skew (0.022 ns) is estimated
rather than modelled on a real BUFG tree. **Re-confirm WHS after integration.**

## 2.5 Verification results

Self-checking testbench, no external dependencies — stimulus generated with SystemVerilog
real math, so no data files and no Python needed to reproduce.

Stimulus: complex tone at bin *k*, `x[n] = A·exp(j2πkn/N)`, **A = 0.4 full scale**.
Deliberately not 0.5: at 0.5 a full-scale tone sits exactly on the BFP overflow boundary,
where the ideal peak lands one LSB above Q1.15 full scale and *correct* hardware fails.
(This is recorded spec error #2 — do not raise it.)

| ID | check | catches |
|---|---|---|
| C1 | Beat count equals N | Wrong transform size, dropped/duplicated beats |
| C2 | TLAST once, on final beat | Frame boundary errors |
| C3 | TUSER constant across N beats | BLK_EXP mis-pairing or mid-frame change |
| C4 | No X/Z on any output beat | Uninitialised logic, reset problems |
| C5 | **Peak bin equals injected tone bin** | **Config word layout, direction, size** |

| case | N | gaps | stalls | tone bin | peak bin | BLK_EXP | beats | result |
|---|---:|---:|---:|---:|---:|---:|---:|---|
| Clean | 1024 | 0 % | 0 % | 40 | 40 | 9 | 1024 | pass |
| Source gaps | 1024 | 30 % | 0 % | 137 | 137 | 9 | 1024 | pass |
| Sink stalls | 1024 | 0 % | 40 % | 300 | 300 | 9 | 1024 | pass |
| Both | 1024 | 25 % | 50 % | 511 | 511 | 9 | 1024 | pass |
| After size switch | 2048 | 0 % | 0 % | 80 | 80 | 10 | 2048 | pass |
| Both | 2048 | 25 % | 50 % | 777 | 777 | 10 | 2048 | pass |
| Switched back | 1024 | 0 % | 0 % | 40 | 40 | 9 | 1024 | pass |

```
frames: 7    checks: 28    errors: 0    RESULT: PASS
```

**BLK_EXP verified numerically, not just for constancy.** BFP selects the smallest shift
avoiding 16-bit overflow:

```
input amplitude = 0.4 x 32767 = 13 107

N=1024:  13107 x 1024 / 2^9  = 26 214    (2^8 would give 52 428 -> overflow)
N=2048:  13107 x 2048 / 2^10 = 26 214    (2^9 would give 52 428 -> overflow)
```

BLK_EXP came out 9 and 10 — in both cases the minimum non-overflowing shift — and both give
the same peak, exactly 0.4 × 2^16. This confirms the BFP path and the TUSER plumbing together.

**What is NOT verified.** Structural checks plus peak-bin position on a single complex tone.
No bin-by-bin golden-model comparison, no impulse, DC, two-tone, off-bin leakage, noise or
low-amplitude cases. **This is not a two-tier regression and must not be described as one.**

## 2.6 Design decisions and why

**The engine outputs complex bins, not magnitude.**
The original spec had this stage emit 32-bit magnitude-squared. That is incompatible with
the rest of the chain: Doppler and AoA are coherent transforms operating on the *phase* of
each range bin. |X|² is real and non-negative — phase is destroyed and unrecoverable. Cost
of the fix is zero:

| | magnitude-squared | complex passthrough |
|---|---:|---:|
| Bits per bin | 32 | 32 |
| Bytes per frame (N=1024) | 4,128 | 4,128 |
| DDR rate | 403.125 MB/s | 403.125 MB/s |
| DSP cost | 2 | **0** |
| Usable by Doppler/AoA | **no** | **yes** |

**BLK_EXP travels on TUSER, not a side channel.**
The generated core reports `C_M_AXIS_DATA_TUSER_WIDTH = 8` with both optional output fields
disabled (`C_HAS_XK_INDEX = 0`, `C_HAS_OVFLO = 0`). The only field that can occupy those bits
is BLK_EXP, present because scaling is BFP. The core already presents it beat-aligned with
its own data. An earlier revision paired it by hand with a FIFO, relying on an unverified
assumption about channel timing. Taking it from TUSER removes that assumption — alignment is
guaranteed by the IP.

**Both boundaries are registered.**
A block writing `assign s_tready = m_tready;` forwards downstream ready combinationally.
Legal AXI-Stream, harmless in one module. Chain five separately-owned blocks and tready
becomes one combinational path from DDR back to the ADC that no single owner can debug.
Cost: 2 cycles latency, ~140 FF. Return: this block's timing is provable in isolation, which
is exactly what the +2.735 ns measures.

**Runtime size switching is fenced to frame boundaries.**
The config FSM re-arms when `nfft_sel` changes but issues only when no frame is in flight,
holding the sample stream off until the core accepts it. A mid-frame config write corrupts
the transform in progress.

## 2.7 Why not custom FFT RTL

Synthesis instantiates **six** `cmpy_4_dsp48` complex multipliers (24 DSP / 4 each) and
elaboration shows `r22_memory`, `r22_pe`, `r22_bf`.

```
plain radix-2 SDF, N=2048 : log2(2048) - 1     = 9 non-trivial multipliers
radix-2^2 SDF,     N=2048 : ceil(log4(2048))   = 6 non-trivial multipliers
measured                  : 24 DSP / 4 per cmpy = 6
```

**Xilinx's "Radix-2, Pipelined Streaming I/O" is internally radix-2².** The `−j` twiddles
reduce to a real/imaginary swap and negate — free in hardware — so only every second stage
needs a real multiplier.

Consequence: a hand-written radix-2² SDF would save **no** DSPs over this IP, at identical
1 sample/clock throughput, while requiring a from-scratch BFP implementation (3–6 months).
Multi-path MDC architectures (Garrido et al., *Pipelined Radix-2ᵏ Feedforward FFT
Architectures*, IEEE TVLSI 2013) do exceed 1 sample/clock — but only help when a **single**
stream must go faster. MIMO radar gives one independent stream per antenna, so P antennas
are served equally well by P independent 1-sample/clock engines. **Custom RTL is rejected.**

## 2.8 Defects found and corrected

| # | defect | consequence | resolution |
|---|---|---|---|
| 1 | Output specified as magnitude-squared | Destroys phase; Doppler/AoA impossible | Emit complex; squaring moved downstream |
| 2 | Config FSM latched off after first handshake | Size fixed after reset; runtime switching impossible | Re-arms on change, fenced to frame boundaries |
| 3 | Status channel `tready` undriven | Status FIFO fills; internal assertion on the **second** frame | `fft_status_capture` owns the port, ties it high |
| 4 | BLK_EXP paired by hand | Relied on unverified channel-timing assumption | Taken from `m_axis_data_tuser` |
| 5 | Combinational `tready` through the block | One long tready path across the accelerator | Both boundaries registered |
| 6 | `transform_length` = 1024 with runtime sizing | 2048 mode physically unbuildable, would fail silently and late | Set to 2048 (the maximum) |

**Defect 6 is worth dwelling on.** Vivado validated the property and accepted the value — it
was legal, and wrong. Tooling catches malformed input; it does not catch well-formed input
that means the wrong thing.

## 2.9 Corrections made to this analysis

Recorded because an analysis that never revises itself is not being checked.

| earlier claim | correction | evidence |
|---|---|---|
| Custom radix-2² SDF saves ~44 % DSP vs the IP | **Withdrawn.** The IP is already radix-2² | 6 × `cmpy_4_dsp48`, `r22_memory` in log |
| Per-lane DSP 27–44 | Measured **24**. Estimate assumed plain radix-2 | Post-route utilisation |
| DSP and bandwidth both cap at ~4 lanes | DSP allows **9**; bandwidth allows ~4. Bandwidth is the sole limit | 24 DSP measured vs 220 |
| WHS +0.013 ns is not a pass | **It is.** Router fixes hold to just-positive by design | `report_timing -delay_type min` |

---

# PART 3 — Scaling to 3-D: the target

## 3.1 Fixed dimensions — not negotiable

```
1024 range bins  x  256 chirps  x  4 RX antennas  =  1 048 576 cells
each cell = 16-bit real + 16-bit imaginary        =  4 bytes
                                                     -----------
                                                     4.2 MB
```

```
frame time  = 256 chirps x 40 us    = 10.24 ms
frame rate  = 1 / 10.24 ms          = 97.7 frames/s
input rate  = 1 048 576 / 10.24 ms  = 102.4 MSPS
```

**Note: 102.4 MSPS is above one lane's 100 MSPS.** The range stage needs either two lanes or
a modestly faster clock. This falls straight out of the fixed dimensions.

## 3.2 Axis assignment

| axis | transform along | yields | N |
|---|---|---|---:|
| 1 | samples within a chirp | range | 1024 |
| 2 | chirps | Doppler / velocity | 256 |
| 3 | RX antennas | angle of arrival | 4 |

The same engine block serves axes 1 and 2 with different IP builds. **Axis 3 should not use
this block** — a 4-point FFT has twiddles 1, −j, −1, +j, so it is eight adders and **zero
DSPs**. A parallel hardwired butterfly is correct at that size; a streaming engine is not.

---

# PART 4 — The constraint

## 4.1 The arithmetic

```
need to store   4.2 MB   between range FFT and Doppler FFT
xc7z020 BRAM    0.6 MB   (140 tiles x 36 Kbit = 4.9 Mbit)
                -------
                7x short  (14x if double-buffered for streaming)
```

**This is a hardware constraint, not a design choice.** The block RAM is etched into the
silicon and cannot be increased.

## 4.2 Why the whole cube must be held

The order data is **produced** does not match the order it is **needed**.

- The **range FFT** works chirp by chirp: finishes chirp 1 (all 1024 bins), then chirp 2…
- The **Doppler FFT** needs one range bin across **all 256 chirps** — a whole column.

Doppler cannot start until every chirp has been through the range FFT. All 1,048,576 values
must sit somewhere in the meantime. **That storage is the corner turn. It is not optional and
cannot be shrunk without changing the specification.**

**Alternative examined and rejected:** processing 32 range bins at a time shrinks the buffer,
but each range FFT produces all 1024 bins of which you keep 32 — requiring ~32 re-runs per
frame. 32× the compute to save memory. Dead end.

## 4.3 Why changing to PYNQ-Z2 does not help

```
Zybo Z7-20 : ZYNQ XC7Z020-1CLG400C
PYNQ-Z2    : ZYNQ XC7Z020-1CLG400C     <- identical
```

Block RAM lives **inside** the FPGA, not on the board. Same chip → same 0.6 MB, to the bit.

The boards differ only in the separate DDR chip:

| | Zybo Z7-20 | PYNQ-Z2 |
|---|---|---|
| On-chip BRAM | 0.6 MB | **0.6 MB (same)** |
| DDR capacity | 1 GB | 512 MB |
| **DDR bus width** | **32-bit** | **16-bit** |
| DDR peak bandwidth | 4.26 GB/s | **2.10 GB/s** |

PYNQ-Z2 is **worse** — half the DDR bandwidth. Its genuine advantage is the PYNQ framework
(Jupyter, Python overlays), which makes *demonstration* far easier than bare-metal C, and
handles the cache-coherency trap automatically.

## 4.4 The bandwidth problem

Cube in DDR. Capacity trivial (4.2 MB into 512 MB / 1 GB). **Bandwidth is the constraint.**

Conventional pipeline with two corner turns:

```
1. range FFT out   -> DDR write    4.2 MB
2. Doppler read    <- DDR read     4.2 MB   STRIDED
3. Doppler out     -> DDR write    4.2 MB
4. angle read      <- DDR read     4.2 MB   STRIDED
5. result out      -> DDR write    4.2 MB
                                   --------
                                   21 MB/frame x 97.7 = 2.05 GB/s
```

Zybo peak 4.26 GB/s; realistically 2.1–2.5 GB/s with strided access and PS traffic sharing.
**2.05 of 2.5 is a coin flip, not a design.** On PYNQ-Z2 it is impossible.

Reading a *column* from DRAM is close to the worst case for page hits — peak figures are not
achievable there.

---

# PART 5 — The solution on Zynq

## 5.1 Three moves, one DDR round trip

```
ADC 4ch ──> RANGE FFT ──> DDR (cube, 4.2 MB) ──> read blocks ──┐
            2 lanes                                            │
                                                               v
        ┌──────────────────────────────────────────────────────┐
        │  4x DOPPLER FFT  (one per antenna, N=256, parallel)   │
        │            │                                         │
        │            v  all 4 antennas of a cell arrive together│
        │  4-point ANGLE butterfly   (no multipliers)           │
        │            │                                         │
        │            v                                         │
        │  magnitude ──> CFAR detection                         │
        └────────────────────────┬─────────────────────────────┘
                                 v
                       DDR: target list only (~KB)
```

### Move 1 — Parallelise the antenna axis, delete corner turn #2

Four Doppler engines side by side, one per antenna. All four antenna values for a given
(range, Doppler) cell emerge on the **same clock cycle** and feed the 4-point angle FFT
directly. Steps 3 and 4 vanish.

```
21 MB -> 12.6 MB per frame     (-40 %)
```

**Does this slow it down? No.** A buffer is only needed where rates or ordering mismatch.
After parallelisation neither does: the engines run in lockstep, and the angle FFT consumes
4 values and produces 4 values combinationally. Comparing like for like, both fully parallel:

| | 2 corner turns | 1 corner turn (fused) |
|---|---:|---:|
| Range, 2 lanes | 5.24 ms | 5.24 ms |
| Doppler, 4 engines | 2.62 ms | 2.62 ms |
| Angle | 2.62 ms (4 engines) | **0 — inline** |
| Pipelined frame time | **5.24 ms** | **5.24 ms** |
| DDR traffic/frame | 21 MB | **8.4 MB** |
| Angle engines | 4 | 0 (8 adders) |
| Cube buffer B | needed | **deleted** |

**Same throughput, 60 % less DDR traffic, fewer resources.** Both are range-limited; the
fusion removes work that was never on the critical path.

**Two requirements it imposes:**
1. **The 4 Doppler engines must stall together.** AND their `tready` into one common stall.
   If they desynchronise, antenna values from different cells get combined and the angle
   result is garbage.
2. **DDR layout must put the 4 antennas contiguous:**
   `addr = ((chirp × 1024) + range) × 4 + antenna`.
   Then 16 range bins × 4 antennas for one chirp = 64 consecutive words = **256-byte bursts**.
   Antenna-major layout instead gives 16-byte scattered reads and the saving evaporates.

### Move 2 — CFAR inside the pipeline, before writeback

The useful output is a target list, not a cube. Detecting on-chip collapses step 5 from
4.2 MB to a few kB.

```
12.6 MB -> 8.4 MB per frame  ->  0.82 GB/s     (-60 % from baseline)
```

**0.82 GB/s against ~2.5 GB/s available. 3× margin.** That is a design.

### Move 3 — Block-based DDR reads with a small on-chip working buffer

DDR holds the cube; BRAM holds only the slice in use.

```
working buffer = 16 range bins x 256 chirps x 4 RX x 4 B x 2 (ping-pong)
               = 131 072 B = 1.05 Mbit = 58 RAMB18 = 21 % of BRAM
```

## 5.2 Whole-chip budget on xc7z020

**Every block, not just the FFT blocks.**

| block | DSP | RAMB18 | LUT | FF | basis |
|---|---:|---:|---:|---:|---|
| Range FFT — 2 lanes, N=2048 | 48 | 36 | 7,818 | 13,632 | **MEASURED** |
| Doppler FFT — 4 lanes, N=256 | 64 | 8 | 9,200 | 16,000 | estimate |
| Working buffer + address gen | 0 | 58 | 500 | 400 | calculated |
| Input ping-pong buffer | 0 | 15 | 300 | 300 | calculated |
| AXI DMA + SmartConnect + CSR | 0 | 16 | 6,000 | 7,500 | estimate |
| CFAR + magnitude | 6 | 2 | 1,600 | 1,200 | estimate |
| Window function — 2 lanes | 4 | 2 | 200 | 200 | calculated |
| Angle FFT + FIFOs + glue | 0 | 0 | 800 | 700 | estimate |
| **Total** | **122** | **137** | **26,418** | **39,932** | |
| **Available** | 220 | 280 | 53,200 | 106,400 | |
| **Utilisation** | **55 %** | **49 %** | **50 %** | **38 %** | fits |

Above ~80 % on a Zynq-7 the router starts fighting and timing closure gets painful. At 50 %
it will place and route without drama.

## 5.3 Throughput achieved

```
required        97.7 frames/s
compute limit   ~195 frames/s   (range: 200 MSPS capability vs 102.4 needed)
DDR limit       ~297 frames/s   (2.5 GB/s / 8.4 MB per frame)
                --------------
achieved        2x margin over real time, compute-limited
```

End-to-end latency ≈ 10.24 ms (range, concurrent with acquisition) + ~2.6 ms (Doppler, angle,
CFAR) ≈ **13 ms**.

## 5.4 What must change from the current spec — needs sign-off

1. **Two range lanes, not one.** Input is 102.4 MSPS, a lane is 100. Costs 24 extra DSPs.
   *Alternative:* one lane at 110 MHz (Fmax measured 138) — saves DSPs, breaks the 100 MHz spec.
2. **FFT engine outputs complex, not magnitude.** Magnitude moves after Doppler/angle.
3. **Only one corner turn.** This is what makes DDR bandwidth work. **Changes the memory
   block's scope — the teammate owning it must be part of this decision.**
4. **CFAR runs on-chip, before writeback.** If it was planned for ARM software, it moves to PL.

## 5.5 The teammate's existing corner turn — assessment

```verilog
reg [31:0] ram0 [0:4095];  reg [31:0] ram1 [0:4095];        // ping-pong
wire [11:0] transposed_rd_addr = {rd_ptr[5:0], rd_ptr[11:6]};  // 64x64 bit-swap
```

Fixed **64 × 64** transpose, 4096 words, one word per clock, ping-pong. The bit-swap trick is
neat and correct — for a *square power-of-two* transpose, swapping row and column address
fields costs no logic.

**Three reasons it doesn't cover the 3-D case:**

| | current block | needed |
|---|---|---|
| Shape | 64 × 64 hardcoded | 1024 × 256 (non-square) |
| Capacity | 4,096 words | 1,048,576 words (256×) |
| Backpressure | **none** | full AXI-Stream |

**The backpressure gap is a live bug today, independent of everything above.** There is no
`ready` in either direction; when the FFT engine stalls, data is silently lost. This will
bite in the plain 1-D chain too.

Also: `skewed_agu.v` and `skewed_memory_array.v` exist but are not instantiated by this top
level — a separate experiment. Note that at 1 sample/clock, conflict-free skewed addressing
is **unnecessary** — a single BRAM port suffices regardless of stride. It becomes necessary
only for the antenna-parallel design, which needs 4 words per cycle.

---

# PART 6 — Migration to Kintex-7 KC705

## 6.1 Board specification — verified from UG810

```
FPGA        : Kintex-7 XC7K325T-2FFG900C
Memory      : 1 GB DDR3 SODIMM, 64-bit (DQS0-DQS7, DM0-DM7 confirmed)
System clock: 200 MHz fixed LVDS differential oscillator
Also        : PCIe x8, tri-mode Ethernet, FMC HPC + LPC, BPI/QSPI flash, HDMI
```

## 6.2 Device comparison

| | Zynq XC7Z020-1 | Kintex XC7K325T-2 | ratio |
|---|---:|---:|---:|
| Block RAM | 4.9 Mb (**0.6 MB**) | 16.0 Mb (**2.0 MB**) | **3.3×** |
| DSP48E1 | 220 | **840** | **3.8×** |
| LUT | 53,200 | **203,800** | **3.8×** |
| FF | 106,400 | 407,600 | 3.8× |
| Speed grade | −1 | **−2** | faster |
| DDR bus | 32-bit @ 1066 Mbps | **64-bit @ 1600 Mbps** | — |
| **DDR peak bandwidth** | 4.26 GB/s | **12.8 GB/s** | **3×** |
| ARM processor | **yes (dual A9)** | **no** | — |

## 6.3 What it solves — and what it does not

**Capacity: NOT solved.** Cube is 4.2 MB; KC705 has 2.0 MB of BRAM. Still 2× short.
**The cube still lives in DDR.** More BRAM does not change this.

**Bandwidth: completely solved.** Even the naive two-corner-turn design at 2.05 GB/s sits at
~16 % of 12.8 GB/s peak, roughly 25 % of realistic sustained. The constraint that was nearly
killing the design evaporates.

**Much larger working buffer becomes possible:**

```
128 range bins x 256 chirps x 4 RX x 4 B x 2 (ping-pong)
   = 1 048 576 B = 8.4 Mbit = 466 RAMB18 = 52 % of 890
   -> bursts of 128 x 4 = 512 words = 2 kB
```

2 kB bursts is where DDR3 actually performs well, versus 256 bytes on the Zynq.

**Speed grade helps too.** Our engine measured Fmax ≈ 138 MHz on −1. On −2, expect
meaningfully higher. At 150 MHz **one** range lane covers the 102.4 MSPS input, removing the
two-lane requirement entirely.

## 6.4 What it costs — Kintex-7 has no ARM

Everything Zynq-specific stops working:

| lost | replacement |
|---|---|
| PS7, `FCLK_CLK0` | MMCM from the 200 MHz board oscillator |
| AXI-HP ports, PS DDR controller | **MIG** DDR3 controller in fabric — you build and constrain it |
| `ps7_init`, FSBL, Vitis platform | MicroBlaze soft processor, or pure-RTL sequencer |
| ARM software for control/readout | MicroBlaze C, or PCIe/UART host link |
| The team's existing `vitis_workspace` | dead |

**The FFT engine itself ports cleanly** — plain RTL plus a vendor IP. Rebuild `xfft_0` for
the new part and re-run; expect better timing than +2.735 ns.

**The system infrastructure does not port.** MIG is meaningfully harder than the Zynq PS DDR
controller, which simply exists. This is the real cost of the move.

## 6.5 Revised budget on XC7K325T

Same design, plus MIG replacing the PS DDR path:

| resource | used | available | % |
|---|---:|---:|---:|
| DSP48E1 | ~122 | 840 | **15 %** |
| RAMB18 | ~137 (or ~545 with the big working buffer) | 890 | **15 % / 61 %** |
| LUT | ~33,000 (incl. MIG) | 203,800 | **16 %** |
| FF | ~52,000 (incl. MIG) | 407,600 | **13 %** |

**~15 % utilisation.** Enormous headroom — you could run far more parallelism than the plan
assumes, or hold a much larger working set.

## 6.6 The decision

**Take the KC705 if** the goal is to build the full-size 1024 × 256 × 4 design and
demonstrate it. It removes the hardest constraint, gives 4× the fabric, and turns a marginal
design into a comfortable one.

**Stay on Zynq if** the team split and existing PS work matter more than headroom. The design
still works — 0.82 GB/s of ~2.5 available — but only *with* the antenna-parallel fusion and
on-chip CFAR. There is no comfortable Zynq design without them.

**Hybrid worth considering:** develop and verify on KC705 where there is room to be
inefficient, then port back to Zynq once the architecture is proven. The FFT engine is
already portable; only the memory and control infrastructure would need reworking twice.

## 6.7 Migration steps, in order

1. **Benchmark MIG DDR3 with a strided access pattern first.** Everything rests on the
   achievable-bandwidth assumption, and it is the one number that has always been estimated
   rather than measured. Do this before designing anything around it.
2. Rebuild `xfft_0` for `xc7k325t-2ffg900c`; re-run `build_engine.tcl`. Record the new
   Fmax — it determines whether one range lane suffices.
3. Generate the MIG DDR3 controller (64-bit, from the 200 MHz oscillator) and bring up a
   simple write/read loopback.
4. Decide control: MicroBlaze soft processor vs pure-RTL sequencer. MicroBlaze is easier for
   configuration and results readout; pure RTL avoids a whole toolchain.
5. Re-run the resource budget at 840 DSP / 890 RAMB18 and decide how much extra parallelism
   is worth taking.
6. Port the working-buffer and block-read logic, sized for 2 kB bursts.

---

# PART 7 — Open questions

| # | question | why it matters | who decides |
|---|---|---|---|
| 1 | Are the radar parameters really 40 µs chirp / 97.7 fps? | Every throughput number derives from this | senior |
| 2 | Achievable DDR bandwidth with strided access? | The one estimated number the whole design rests on | measure it |
| 3 | Zynq or Kintex? | Decides whether the fusion is mandatory or merely good | senior |
| 4 | Does the corner turn stay with the teammate? | The fusion changes that block's scope | team |
| 5 | Who owns CFAR, and is it in PL or software? | On-chip CFAR is 30 % of the bandwidth saving | team |
| 6 | Complex multiplier structure — frozen at 4-mult? | Affects rounding, must match project-wide | senior |
| 7 | Who owns the window function? | Without it, −13.3 dBc sidelobes make radar results invalid | unassigned |
| 8 | Exponent accumulation across stages — who? | 2^(E1+E2); getting it wrong gives plausible but very wrong magnitudes | unassigned |

---

# PART 8 — Things that must not be forgotten

- **The window function does not exist.** A rectangular window has −13.3 dBc peak sidelobes.
  Weak targets near strong ones will be masked. Hann gives −31.5 dBc, Blackman-Harris-4
  gives −92 dBc. Cost: 2 DSP + 1 BRAM per lane. **The radar is not valid without it.**
- **BLK_EXP must accumulate across stages.** Range gives E₁, Doppler gives E₂; a
  range-Doppler cell's true scale is 2^(E₁+E₂). Wrong handling produces a plausible-looking
  number, not an obvious failure — the worst kind of bug.
- **The corner turn's missing backpressure is a live bug today**, in the 1-D chain, before
  any of the 3-D work.
- **Stimulus amplitude stays at 0.4, never 0.5.** 0.5 sits on the BFP overflow boundary where
  correct hardware fails.
- **`transform_length` must be the maximum** when runtime-configurable. Setting it to the
  minimum is legal and silently unbuildable at the larger size.
- **Do not square at the range stage.** It is the single change most likely to be made by
  someone downstream who "just needs magnitude here," and it breaks the entire chain.
- **Verification claim must stay honest.** Structural + peak-bin on one tone. Not a two-tier
  regression.
- **`HD.CLK_SRC` is unset in OOC**, so hold margin must be re-confirmed after integration.

---

# PART 9 — File index

| file | contents |
|---|---|
| `README.md` | FFT engine front page: interface, measured numbers, limits |
| `SPEC_FROZEN.md` | Integration contract, every value traced to source |
| `FFT_ENGINE_BLOCK.md` | Block boundary, module plan, interface contract |
| `RESULTS_SYNTH.md` | Measured synthesis results and the radix-2² finding |
| `ARCH_REVIEW_STAGE1.md` | Original architecture review (parts superseded — see §2.9) |
| `SOLUTION.md` | The three-move solution and its arithmetic |
| `FIT_BUDGET.md` | Whole-chip resource budget |
| `MEMORY_PROBLEM_BRIEF.md` | Plain-language brief for the team |
| `Memory_Problem.pdf` | Same, as a shareable PDF with figures |
| `FFT_Engine_Report.pdf` | Full 14-page design/verification report |
| `FFT3D_PLAN.md` | Scaled-down on-chip 3-D plan (superseded by Part 6) |
| `rtl/` | 5 SystemVerilog modules |
| `tb/tb_fft_engine.sv` | Self-checking testbench |
| `scripts/` | IP generation, build, simulation TCL |
| `fft_engine_flow.mermaid` | Detailed engine dataflow |
| `fft_engine_simple.mermaid` | Plain-language version |
| `fft_chain_flow.mermaid` | Full chain with block ownership |
