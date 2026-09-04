# FMCW MIMO Radar 3-D FFT Accelerator — 20-Day Build Log

**Target:** Xilinx Kintex-7 KC705 (XC7K325T-2FFG900C)
**Spec:** 1024 range × 256 Doppler × 4 RX antennas, Q1.15 fixed point
**Chain:** Range FFT → corner turn → Doppler FFT → Angle FFT → |X|² → CA-CFAR

A day-by-day record of what was built, what broke, and what the evidence
actually showed. Failed hypotheses are kept in, not edited out — several of
the most useful findings came from theories that turned out to be wrong.

---

## Day 1 — Specification freeze

Fixed the parameters everything downstream depends on, so they could stop
being renegotiated mid-design:

| Parameter | Value |
|---|---|
| Range bins | 1024 |
| Doppler bins (chirps) | 256 |
| RX antennas | 4 |
| Sample format | Q1.15 complex, 16-bit I / 16-bit Q |
| FFT core | Xilinx LogiCORE xfft v9.1, Pipelined Streaming I/O |
| Scaling | Block floating point (BFP) |
| Rounding | Convergent |

Chose BFP over fixed scaling deliberately: a radar scene has enormous
dynamic range between a nearby wall and a distant target, and a fixed
schedule either clips the near return or buries the far one.

**Output:** `SPEC_FROZEN.md`

---

## Day 2 — Range lane architecture

Designed the single-lane datapath and, more importantly, the interface
contract between blocks: AXI4-Stream with TVALID/TREADY/TLAST, one skid
buffer at every block boundary.

The rule written down on this day — **TVALID must never combinationally
depend on TREADY** — turned out to matter enormously on Day 19.

**Output:** `FFT_ENGINE_BLOCK.md`, `ARCH_REVIEW_STAGE1.md`

---

## Day 3 — The memory problem

Sized the data cube and hit the wall that defined the rest of the project:

```
1024 range × 256 Doppler × 4 antennas × 4 bytes = 4.19 MB per cube
Ping-pong (process frame k while frame k+1 arrives) = 8.39 MB
```

Available Block RAM: **0.6 MB** on Zynq-7020, **2.0 MB** on Kintex-7 325T.

The corner turn between Range and Doppler cannot live on chip. Not at these
dimensions, not on this device, in no arrangement. Everything after this day
is a consequence of that number.

**Output:** `MEMORY_PROBLEM_BRIEF.md`

---

## Day 4 — Fit budget

Worked the resource arithmetic properly rather than hoping. Confirmed the
cube cannot be tiled, compressed, or streamed around the BRAM limit without
either destroying throughput or changing the spec.

Conclusion: the corner turn must be **DRAM-backed**, with only a small
on-chip working slice (64–128 kB).

**Output:** `FIT_BUDGET.md`

---

## Day 5 — Board evaluation

Compared Zybo Z7-20, PYNQ-Z2 and KC705 against the requirement. Kintex-7
KC705 selected: 2.0 MB BRAM, 840 DSP48E1, and a 64-bit DDR3 interface via
MIG — versus the Zynq boards' 32-bit path.

Note the honest framing: the bigger board does not make the cube fit. It
makes the DRAM path fast enough that not fitting stops mattering.

---

## Day 6 — Bandwidth: requirement vs measurement

Derived the requirement and found it has a surprising property:

```
BW = 2 × bytes_per_sample × N_rx × f_sample
   = 2 × 4 B × 4 × 25.6 MSPS
   = 819 MB/s
```

`N_range` and `N_chirp` cancel exactly. **Bandwidth is independent of
transform size** — a bigger FFT means more data but a proportionally longer
frame. You cannot buy headroom by shrinking the transform.

Measured real DDR bandwidth on PYNQ-Z2 hardware: **1541 MB/s** — on the
*worse* of the candidate boards. Also measured the access-pattern penalty:
128-byte transfers achieved 6 MB/s where 16 MB transfers achieved 1539 MB/s.
A **252× swing from access pattern alone**, which is why the corner turn
must read range-blocks rather than single rows.

**Output:** `SOLUTION.md`

---

## Day 7 — Context consolidation

Wrote up the design state so decisions and their reasons were recoverable
rather than living in one person's head.

**Output:** `MASTER_CONTEXT.md`, `PROGRESS_REPORT.md`

---

## Day 8 — Build infrastructure

Tcl scripts for reproducible builds: IP generation, out-of-context
synthesis, reporting. The FFT IP is generated with
`run_time_configurable_transform_length=true` up to N=2048 — a decision that
paid off much later by allowing reduced-size simulation without regenerating
the core.

**Output:** `scripts/create_fft_ip.tcl`, `scripts/build_engine.tcl`

---

## Day 9 — Licensing blocker

Synthesis failed: *"A valid license was not found for feature 'Synthesis'
and/or device 'xc7k325t'."*

Initially assumed a network problem. It wasn't — the free tier does not
cover this device. Wrote a diagnostic that separates the two failure modes
(device not installed vs device not licensed) via a trivial one-flop probe
synthesis, so the distinction is testable instead of guessed.

Resolved via the institutional floating licence server.

**Output:** `scripts/check_part.tcl`

---

## Day 10 — KC705 migration

Regenerated the FFT IP for Kintex-7 and generated the MIG DDR3 controller
that the real corner turn will need.

**Output:** `vivado_ip_kc705/`, `ctm_test/` (MIG DDR3)

---

## Day 11 — Range lane RTL

First real RTL: Hanning window (DSP48-inferred, coefficient ROM), the
`fft_lane` wrapper around xfft with config FSM and status drain, and
`axis_skid` register slices at the boundaries.

One non-obvious requirement: the xfft status channel **must** be drained or
the core halts. Wired and documented rather than left dangling.

**Output:** `rtl/window_lane.sv`, `rtl/fft_lane.sv`, `rtl/axis_skid.sv`,
`rtl/fft_config_fsm.sv`, `rtl/fft_status_capture.sv`

---

## Day 12 — First multi-lane and corner-turn attempts

Built a 4-lane experiment and a first tiled ping-pong corner turn. Both were
later superseded — kept in `attic/` rather than deleted, because the reasons
they were replaced are part of the record.

---

## Day 13 — Golden model and simulation infrastructure

NumPy reference model and simulation scripts, to have something to check
against rather than eyeballing waveforms.

**Output:** `scripts/golden_model_3d_fft.py`

---

## Day 14 — Full code review: four critical bugs

Audited everything written so far instead of trusting it. Found:

1. **`angle_fft_lane.sv` was a 4-deep shift register.** No transform at all.
   It would have produced plausible-looking output forever.
2. **Corner turn had no working transpose.** One copy incremented the read
   pointer in lockstep with the write pointer (no transpose whatsoever); the
   other used mismatched address formulas — `rd_chirp + rd_range*128` against
   a write of `wr_range + wr_chirp*512`, which agree at **2 addresses out of
   65,536**.
3. **The passing testbench proved nothing.** `xsim.log` showed
   "3D PIPELINE PASSED! 65536/65536" — a *beat count*, not a data check. It
   would have passed against both broken transposes above.
4. **Synthesis targeted the wrong silicon.** `build_synth.tcl` had
   `xc7a200tfbg676-2` (Artix-7) under a comment claiming Kintex-7. Every
   utilization and timing number produced up to this point described a device
   that was not on the desk.

The lesson worth keeping: a green test result is worthless if the test does
not check the thing you care about.

**Output:** `REVIEW_AUG31.md`

---

## Day 15 — Bug fixes

- **`fft_config_fsm`**: `doppler_lane` instantiated it unmodified, so it
  requested a **1024-point Doppler transform instead of 128**. The core would
  have waited forever for input that never arrives. Parameterized `NFFT_SEL0/1`.
- **`complex_mag2`**: computed both squares twice, inferring up to 4 DSP48s
  for 2 multiplies. Restructured to a clean 3-stage pipeline.
- **`ca_cfar`**: noise average hardcoded to shift-by-3 regardless of
  `REF_CELLS`. Changing the reference cell count would have silently scaled
  the detection threshold wrongly — detections still produced, just at the
  wrong rate, which is very hard to spot. Derived from `$clog2(REF_CELLS)`
  with a compile-time power-of-two check.
- **`exp_accum`**: new. Carries the Range stage's BLK_EXP across the Doppler
  stage's latency. A single register is insufficient because frames overlap
  in the pipeline.

**Output:** `rtl/exp_accum.sv`, fixes across `rtl/`

---

## Day 16 — The 4-lane architecture decision

Chose to replicate the datapath once per antenna and pack all four into a
single 128-bit AXI-Stream beat, so every antenna of a cell arrives on the
same clock edge.

| | 1 lane, time-multiplexed | **4 lanes (built)** |
|---|---|---|
| Throughput | 102.4 MSPS, needs >103 MHz | **400 MSPS at 100 MHz** |
| Angle FFT | needs buffering + reorder | **combinational, 0 DSP, 0 BRAM** |
| Second corner turn | required | **eliminated** |
| DDR traffic | 2052 MB/s | **819 MB/s** |
| DSP cost | ~45 | ~180 of 840 (21 %) |

The packing is load-bearing, not cosmetic: four independent 32-bit streams
could drift by a beat and silently combine antennas from *different cells*
in the angle transform. One TVALID and one TREADY makes that structurally
impossible.

**Output:** `rtl/axis_pack4.sv`, `rtl/angle_fft4_par.sv`

---

## Day 17 — Integration

Wired the full chain in `radar_dsp_3d_top.sv` and wrote the corner-turn
interface contract for the collaborator building the DDR-backed block —
address formula, ping-pong requirements, backpressure, BLK_EXP passthrough,
plus `tb_ctm_transpose.sv` as its acceptance test.

Block-exponent bookkeeping documented explicitly, because it fails silently:

```
after Range FFT     value × 2^Er
after Doppler FFT   value × 2^(Er+Ed)        <- Doppler reports only Ed
after Angle FFT     value × 2^(Er+Ed+2)      <- ÷4 inside angle_fft4_par
after |X|²          value × 2^(2·(Er+Ed+2))  <- squaring doubles it
```

Elaboration check: clean, correct instance counts (4 fft_lane, 4
doppler_lane, 1 angle_fft4_par, 4 complex_mag2, 4 ca_cfar…).

**Output:** `rtl/radar_dsp_3d_top.sv`, `rtl/ctm_stub.sv`,
`tb/tb_ctm_transpose.sv`, `scripts/check_elab.tcl`

---

## Day 18 — Synthesis blocked; end-to-end test written

Synthesis failed on *"Cannot connect to a license server running the
xilinxd licensing daemon at the specified port."* Diagnosed with
`Test-NetConnection`: host pings fine (95 ms), **TCP port 2100 refused** —
the licence server is reachable only from inside the campus network. A
network problem, not a design problem.

Meanwhile wrote the first end-to-end testbench against the real xfft IP.
Nothing before this exercised the full chain; the existing testbenches
predated the 4-lane architecture and did not instantiate the current top.

**Output:** `tb/tb_radar_dsp_3d_top_smoke.sv`, `scripts/run_pipeline_smoke.tcl`

---

## Day 19 — The deadlock hunt

The end-to-end test compiled and elaborated cleanly, then produced **zero
output beats** across a 200 µs watchdog. Four runs to find why.

**Hypothesis 1 — transform size below the core's minimum.** Tested at
8-point, then 16-point. Identical zero-beat result. *Falsified.*

**Hypothesis 2 — corrupted window coefficients.** Real and confirmed:
`$readmemh` could not find `hanning_1024.mem` (path relative to the
simulator's run directory, not the project root), so all four Range lanes
ran on X. Fixed — took two attempts, because Vivado flattens exported data
files to the run directory root and drops the path prefix. *Real bug, not
the stall.*

**Hypothesis 3 — bogus config request at reset.** Also real:
`fft_config_fsm` hardcoded its reset default to NFFT=10 regardless of
parameter, issuing one wrong config before self-correcting. Fixed.
*Real bug, still not the stall.*

**Root cause, found by instrumentation rather than a fourth guess.** A
`$monitor` on the config handshake showed the input side was completely
healthy — 253 consecutive cycles streaming into the Range FFT. That
constraint made the rest provable from the code:

```
ca_cfar:     pipeline advances only `else if (m_axis_tready)`
             -> its TVALID depends on its TREADY
axis_pack4:  s_axis_tready = {4{all_valid & m_axis_tready}}
             -> its TREADY depends on TVALID

valid_pipe = 0 (reset) -> cfar tvalid = 0 -> pack all_valid = 0
                       -> pack tready = 0 -> cfar tready = 0
                       -> cfar pipeline frozen -> valid stays 0 ... forever
```

A circular combinational dependency with no escape from reset. It explains
every observation exactly: the input drains fine (upstream skids absorb it)
and the output is *exactly* zero at every transform size.

This is the same violation flagged on Day 2 and caught in `axis_unpack4`
during Day 16 — fixed there, but the pre-existing `ca_cfar` was never
audited for the same pattern. **That audit gap is the real lesson**, more
than any individual bug.

**Fix:** an `axis_skid` between each CFAR and the output join. Its ready is
high when empty regardless of downstream, and its valid is a register.
`g_range`/`g_doppler` already end in skids — which is exactly why those two
joins were never affected.

### Result: PASS — 263 checks, 0 errors

```
1. top input : 256   2. Range FFT out : 256   3. corner turn in  : 256
4. corner turn out : 256   5. Doppler FFT out : 256   6. Angle FFT out : 256
7. |X|² out : 256    8. CFAR out : 256    9. skid out : 256   10. top output : 256
```

The strongest evidence is not the pass line — it is the range profile:

```
range 0 : 2119936
range 1 :  652544    range 15 :  652544
range 2 :  153856    range 14 :  153856
range 3 :   62720    range 13 :   62720
range 4 :   28928    range 12 :   28928
range 5 :   40192    range 11 :   40192
range 6 :   24832    range 10 :   24832
range 7 :   21760    range  9 :   21760
range 8 :   20736    (Nyquist bin, self-paired)
```

Every mirror pair matches **exactly**. A real-valued input's DFT must satisfy
`X[k] = X*[N−k]`, hence `|X[k]|² = |X[N−k]|²`. Seven-for-seven exact
conjugate symmetry is a *numerical* correctness check on the Range FFT, not
merely a structural one.

Two of the seven initial "failures" were also traced to **wrong expectations
in the testbench, not defects in the design**: angle bins 1–3 reading zero is
the correct answer for a 4-point DFT of a constant, and the range leakage is
the fixed 1024-point Hanning window applied to a 16-point transform — a real
documented limitation of reduced-size runs.

---

## Day 20 — Spec enforcement and repository cleanup

**Bug #6, found by asking a simple question out loud** — *"just to confirm
our 3D is 1024×256×4, right?"*

| | Frozen spec | Was configured |
|---|---|---|
| Range | 1024 | 1024 ✓ |
| Doppler | 256 | **16 chirps, 128-point transform** ✗ |
| Antennas | 4 | 4 ✓ |

The first successful synthesis would have reported utilization and timing
for the **wrong cube** — and optimistically wrong, since a 256-point Doppler
FFT needs materially more BRAM than a 128-point one. Those numbers would
have been believed.

Root cause: `N_CHIRP=16` was a leftover from when the corner-turn stub held
the cube as a flat array and had to stay small. That constraint was removed
days earlier; nobody updated the dimensions afterward.

Fixed so the **module defaults now ARE the spec** — a reduced size must be
requested explicitly, rather than the spec quietly being whatever was
convenient last. An elaboration-time assertion enforces
`N_RANGE == 2^RANGE_NFFT` and `N_CHIRP == 2^DOPPLER_NFFT`.

Repository reorganised: docs to `docs/`, superseded work to `attic/`,
regenerable tool output removed, `.gitignore` rewritten. Verified by
re-running the full test suite after cleanup — `build/` rebuilt from
scratch, which is what actually proves nothing broke.

### Synthesis complete — the first real numbers

On the campus network the licence server became reachable
(`TcpTestSucceeded : True` on port 2100), and synthesis ran at the full
frozen spec:

| Resource | Used | Budget | % |
|---|---|---|---|
| LUT | 34,200 | 203,800 | **17 %** |
| FF | 57,132 | 407,600 | **14 %** |
| DSP48E1 | 216 | 840 | **26 %** |
| RAMB18 | 146 | 890 | **16 %** |
| **WNS @ 100 MHz** | **+4.505 ns** | | **timing met** |

Critical path 5.495 ns → Fmax ≈ 182 MHz post-synthesis, consistent with the
162 MHz measured on this part during Stage 1.

**Bug #7, caught in the same session.** The *first* synthesis run finished
with `0 errors` and printed `WNS :  ns` — blank. That reads like success
and means **timing was never analysed**. `rtl/kc705_timing.xdc` failed three
ways at once: a UTF-8 BOM made Vivado reject line 1; it constrained ports
named `sys_clk_p`/`sys_rst_n` when this module's are `aclk`/`aresetn`, so
`create_clock` never ran; and it asked for 250 MHz against a design costed
at 100. Every path was unconstrained.

Fixed with a proper out-of-context XDC, and `build_synth.tcl` now refuses to
print a blank WNS — no clock prints `*** NO CLOCK DEFINED — TIMING NOT
ANALYSED ***`. A build cannot quietly look fine again.

**Read the numbers honestly:** post-synthesis, not post-route, so routing
delay is not included and 182 MHz is an upper bound. And `u_ctm` is still
the register placeholder — the real DDR-backed corner turn plus its MIG
controller adds substantial logic and demanding constraints on top.

---

## Status

### Verified

- Full pipeline functional end-to-end against the real Xilinx FFT IP
- 263 checks, 0 errors; all ten internal boundaries at 256/256 beats
- Range FFT numerically correct (exact conjugate symmetry)
- Angle transform exact: constant across antennas → bin 0 only, bins 1–3 zero
- Doppler + corner turn correct: identical chirps → all energy at doppler bin 0
- No AXI-Stream deadlock, no protocol violation, no X-propagation
- Elaborates clean against the real KC705 part with correct instance counts

### Not yet verified — stated plainly

- **Real cube size.** Verification ran at 16×16, not 1024×256. The window ROM
  does not scale with transform size, so reduced-size runs are structurally
  meaningful but never numerically representative.
- **The real corner turn.** A behavioural placeholder was tested. The
  DDR-backed block must land and pass `tb_ctm_transpose.sv` unchanged.
- ~~**Timing and resources.**~~ **Done 3 Sep** — synthesises clean at full
  1024×256×4: 17 % LUT, 14 % FF, 26 % DSP, 16 % BRAM, WNS +4.505 ns at
  100 MHz. Post-synthesis only; implementation (place & route) not yet run,
  and the corner turn is not in the design.
- **DDR bandwidth on KC705.** 819 MB/s is extrapolated from PYNQ-Z2
  measurements, not measured on this silicon.
- **BLK_EXP across varying chirps.** A constant test cube cannot exercise the
  assumption that every chirp yields the same exponent.

### Bugs found and fixed

| # | Bug | Found by |
|---|---|---|
| 1 | Angle FFT was a shift register, no transform | code review |
| 2 | Corner turn had no working transpose (2 variants) | code review |
| 3 | "Passing" test checked beat count, not data | code review |
| 4 | Synthesis targeted Artix-7, not Kintex-7 | code review |
| 5 | Doppler requested a 1024-pt transform instead of 128 | code review |
| 6 | Duplicate multiplier inference in `complex_mag2` | code review |
| 7 | CFAR threshold shift hardcoded, ignored parameters | code review |
| 8 | `ctm_stub` array exceeded Vivado's elaboration ceiling | elaboration |
| 9 | Window coefficients file unreachable — lanes ran on X | simulation |
| 10 | `fft_config_fsm` reset default ignored its parameter | code review |
| 11 | **`ca_cfar`/`axis_pack4` combinational deadlock** | instrumentation |
| 12 | Build scripts configured the wrong cube dimensions | asking out loud |
| 13 | **Timing constraints never applied — synthesis reported a blank WNS that reads as success** | reading the output instead of the exit code |

---

## Repository layout

```
rtl/               synthesisable RTL
tb/                testbenches
scripts/           build, elaborate, simulate, cleanup
constraints/       XDC
vivado_ip_kc705/   generated xfft_0 IP — every script depends on this
ctm_test/          MIG DDR3 IP for the real corner turn
docs/              design notes, plans, figures
attic/             superseded RTL and stale results, kept for history
```

## Reproducing

```powershell
$env:Path += ";C:\Xilinx\2025.1\Vivado\bin"

.\scripts\run_unit_tests.ps1                          # seconds, no IP needed
vivado -mode batch -source scripts/run_pipeline_smoke.tcl   # end-to-end, real IP
vivado -mode batch -source scripts/check_elab.tcl      # elaboration, full size
vivado -mode batch -source build_synth.tcl             # synthesis (needs licence)
```
