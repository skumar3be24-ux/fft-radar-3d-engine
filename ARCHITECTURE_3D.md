# 3-D Radar DSP — Built Architecture

Everything except the corner turn. Written 31 Aug. Housekeeping and the
angle-FFT unit-test gap closed 2 Sep. Ready for verification — not yet run.

---

## The pipeline

```
 128b in                                                            128b out
 (4 ant) ─►unpack─► 4x [window + Range FFT] ─►pack─► [ CORNER TURN ] ─┐
                                                     (bhaiya's block)  │
        ┌──────────────────────────────────────────────────────────────┘
        ▼
     unpack ─► 4x [Doppler FFT] ─►pack─► [Angle FFT] ─►unpack─► 4x |X|² ─► 4x CFAR ─►pack
                                        combinational
```

One 128-bit beat carries **all four antennas of one cell**: lane L = antenna L,
`{Im[15:0], Re[15:0]}` Q1.15 each.

---

## Why 4 lanes, not 1

| | 1 lane, time-multiplexed | **4 lanes (built)** |
|---|---|---|
| Throughput | 102.4 MSPS, needs >103 MHz | **400 MSPS at 100 MHz** |
| Angle FFT | needs buffering + reorder | **combinational, 1 cycle** |
| Second corner turn | required | **deleted** |
| DDR traffic | 2,052 MB/s | **819 MB/s** |
| DSP cost | ~45 | ~180 of 840 (21 %) |

The device is nowhere near the limit, so spending DSPs to delete a corner turn
and a whole transpose stage is the right trade. Measured Fmax on this part is
162 MHz, giving ~6x headroom over the 102.4 MSPS the radar actually produces.

**The packing is load-bearing, not cosmetic.** Four independent 32-bit streams
could drift by a beat, silently combining antennas from different cells in the
angle transform. One TVALID and one TREADY makes that structurally impossible.
It is also the DDR layout the corner turn needs — antennas contiguous, so one
burst fetches a whole cell.

---

## Modules

| file | role | cost |
|---|---|---|
| `axis_pack4.sv` | 4x32b ⇄ 128b, lockstep join / fork | logic only |
| `window_lane.sv` | Hanning, Q1.15 | 2 DSP, 1 BRAM |
| `fft_lane.sv` | window + Range FFT + skids + status drain | 26 DSP, 19 RAMB18 |
| `ctm_stub.sv` | **corner turn contract + behavioural model** | placeholder |
| `doppler_lane.sv` | Doppler FFT + skids + status drain | ~16 DSP |
| `exp_accum.sv` | carries Er across Doppler latency | logic only |
| `angle_fft4_par.sv` | **4-point DFT, combinational** | **0 DSP, 0 BRAM** |
| `complex_mag2.sv` | Re²+Im², 32-bit unsigned | 2 DSP |
| `ca_cfar.sv` | CA-CFAR detection | ~1 DSP |
| `radar_dsp_3d_top.sv` | integration | — |

Estimated total: **~180 DSP (21 %)**, **~92 RAMB18 (10 %)**. To be confirmed by
synthesis.

---

## Block exponent — the silent-failure path

```
after Range FFT     value * 2^Er
after Doppler FFT   value * 2^(Er+Ed)          <- Doppler reports only Ed
after Angle FFT     value * 2^(Er+Ed+2)        <- /4 inside angle_fft4_par
after |X|^2         value * 2^(2*(Er+Ed+2))    <- squaring doubles it
```

`exp_accum` holds Er across the Doppler stage's latency (a plain register would
hand out the wrong frame's exponent, since frames overlap). `m_axis_tuser`
carries `Er+Ed+2`; **the consumer must double it**, because the output is
magnitude-squared. Not doubled internally on purpose — TUSER then means the same
thing at every interface.

---

## What the corner turn must provide

Full spec in the header of `ctm_stub.sv`. The short version:

```
in / out : 128-bit AXI-Stream, full backpressure both ports
write    : range fastest    read : chirp fastest
address  : addr(c,r) = c * N_RANGE + r      -- SAME formula both sides
ping-pong: separate read and write bank selects
tuser    : BLK_EXP, constant across a frame
tlast    : final beat of each output frame
```

**It cannot live on chip.** 1024 x 256 x 16 B = 4.19 MB per cube, 8.39 MB
ping-pong, against 2.00 MB of BRAM. DDR-backed with a 64–128 kB working slice,
antennas contiguous, read in range-blocks not single rows.

Required bandwidth is `2 x 4 B x 4 ant x 25.6 MSPS = 819 MB/s`, and it is
**independent of transform size** — N_range and N_chirp cancel.

`tb/tb_ctm_transpose.sv` is the acceptance test. Point its DUT line at the real
block; it must pass unchanged.

---

## Bugs found and fixed while building

| # | where | what |
|---|---|---|
| 1 | `angle_fft_lane.sv` | Was a 4-deep shift register, no transform at all. Replaced. |
| 2 | `doppler_lane.sv` | Instantiated `fft_config_fsm` unchanged, so it requested a **1024-point Doppler FFT** instead of 128. Would have stalled forever. |
| 3 | `complex_mag2.sv` | Computed both squares twice, inferring up to 4 multipliers for 2 multiplies. |
| 4 | `ca_cfar.sv` | Noise divide hardcoded to shift-by-3 regardless of `REF_CELLS`; also a 33-bit slice into a 32-bit wire. |
| 5 | `build_synth.tcl` | Synthesised for **xc7a200t (Artix)** under a comment claiming Kintex. |
| 6 | my own `axis_unpack4` | First draft made TVALID depend on TREADY — an AXI-Stream violation and a combinational loop. Fixed to the standard fork pattern. |

---

## Verification log

**2 Sep, step 1 (`run_unit_tests.ps1`): PASS.** `angle_fft4_par` (live module)
and `ctm_transpose` both passed on real hardware-target simulation (xsim),
not just by reading the code. The superseded `angle_fft4` reference also
passed (non-blocking).

**2 Sep, step 2 (`check_elab.tcl`): FAILED, diagnosed, fixed, not yet
re-run.** `synth_design` errored inside `ctm_stub.sv`:

```
ERROR: [Synth 8-4556] size of variable 'mem' is too large to handle;
       the size of the variable is 1048576, the limit is 1000000
```

Root cause: `ctm_stub.sv`'s behavioural model allocates `mem[2][N_RANGE x
N_CHIRP]` of 128-bit words. Even at the deliberately reduced elaboration
cube (256 range x 16 chirp), that's `2 x 4096 x 128 = 1,048,576` bits --
over Vivado's internal ~1,000,000-bit ceiling for one flattened array
variable during RTL elaboration. This is a synth_design front-end parser
limit, unrelated to real BRAM budget (445 RAMB36 =~ 16 Mb, far more than
this). `build_synth.tcl`'s real cube (1024x16 = 4.19 Mbit) was always going
to hit the same wall, worse.

Fix: `ctm_stub.sv` now has two bodies gated by `` `ifdef SYNTHESIS ``. The
real transpose model (what `tb_ctm_transpose.sv` checks) is unchanged and
still what simulation sees. A new trivial 1-deep register placeholder --
zero array, full backpressure, tuser/tlast passthrough, same ports, but NOT
a transpose -- is what `synth_design` sees, selected deterministically via
`-verilog_define SYNTHESIS` added to both `check_elab.tcl` and
`build_synth.tcl` (not relying on Vivado predefining that macro). This
means neither script's `u_ctm` instance utilization/timing numbers describe
the real corner turn -- they describe a register. That was already true in
spirit (`ctm_stub.sv` was always documented as non-synthesizable at real
size); this just makes the build actually complete instead of erroring out.

**Re-run 2 Sep: PASS.** Clean elaboration, 0 errors, instance counts exactly
matched expected (4 fft_lane, 4 doppler_lane, 1 ctm_stub, 1 angle_fft4_par,
4 complex_mag2, 4 ca_cfar, 3 axis_pack4, 3 axis_unpack4, 1 exp_accum, 4
window_lane, 8 axis_skid). 26 warnings, all reviewed, all benign (over-wide
`ca_cfar` pipe arrays trimmed by synthesis; `axis_pack4`/`axis_unpack4`
clock ports and 3 of 4 TLAST inputs correctly unused for a pure-combinational
join/fork module).

**2 Sep, step 3 (`build_synth.tcl`): blocked on Vivado license/network, not
an RTL problem.** `synth_design` failed immediately with "Cannot connect to
a license server running the xilinxd licensing daemon at the specified
port" -- confirmed via `Test-NetConnection` that the license server host is
pingable but port 2100 specifically is unreachable from the current network
(campus-restricted floating license, off-campus/off-VPN right now). Nothing
to fix in the design; this needs network/VPN access, not more RTL work.

**2 Sep, found during further review (not yet caught by any existing
test): N_RANGE/N_CHIRP vs FFT transform-length mismatch risk.**
`radar_dsp_3d_top`'s `N_RANGE`/`N_CHIRP` set the corner-turn's frame length;
`RANGE_SEL`/`DOPPLER_SEL` set the xfft cores' actual configured transform
length. These were completely decoupled -- nothing wired them together, and
nothing checked they agreed. The default `N_CHIRP=16` does NOT match
`DOPPLER_SEL=0`'s 128-point transform: running the design for functional
simulation with defaults as-is would silently hand the Doppler FFT core a
16-sample frame when it's configured to expect 128, per Xilinx PG109's
requirement of exactly N valid samples before TLAST. Neither
`check_elab.tcl` nor `build_synth.tcl` would have caught this -- they only
prove structural connectivity, not that the numbers flowing through are
correct, and they deliberately use reduced dimensions that were never meant
to be functionally meaningful in the first place.

Fixed: `radar_dsp_3d_top.sv` now has a simulation-only (`` `ifndef
SYNTHESIS ``, so it doesn't affect `check_elab.tcl`/`build_synth.tcl`)
elaboration-time assertion that `$error`s loudly if `N_RANGE`/`N_CHIRP`
don't match the actual configured transform length. Also added
`RANGE_NFFT0/1` and `DOPPLER_NFFT0/1` override parameters (threaded through
to `fft_lane`/`doppler_lane`, which already had the underlying
`fft_config_fsm` override capability from the 1 Sep NFFT bug fix) so a
reduced-size functional smoke test is actually possible against the
existing generated `xfft_0` IP -- it was built with
`run_time_configurable_transform_length=true` up to N=2048, so any
power-of-two down to 8 is legal at runtime without regenerating the IP.
Defaults are unchanged (10/11 and 7/8, i.e. 1024/2048 and 128/256), so
nothing about the passing tests or the two completed builds above changed.

Also fixed in passing: `doppler_lane.sv`'s `nfft_sel_i` port comment said
"0 = 64-point, 1 = 128-point" -- contradicted both its own hardcoded
config values (128/256) and `radar_dsp_3d_top.sv`'s own comment for the
same selector. Stale, not functional, but exactly the kind of thing that
misleads the next reader.

**Written 2 Sep: `tb/tb_radar_dsp_3d_top_smoke.sv` + `scripts/run_pipeline_smoke.tcl`.**
First simulation of the actual `radar_dsp_3d_top`, through the real `xfft_0`
IP core (not a mock), not yet run by anyone. Scale is 8x8 (both Range and
Doppler as 8-point transforms via the new NFFT override parameters) --
legal against the already-generated IP without regeneration, since it was
built `run_time_configurable_transform_length=true` up to 2048 and 8 is the
architecture minimum.

Stimulus is constant DC on all 4 antennas across the whole cube. That's a
deliberate, defensible choice: a DFT of a constant input concentrates all
energy in bin 0 by Fourier linearity, for the Range, Doppler, AND Angle
transforms, since all three see the same lockstep-constant signal. Checks:
output beat count (64), TLAST cadence (once per range bin, at the right
offsets), no `exp_accum` FIFO overflow, and that cell (range=0, doppler=0)
is the one loud cell in each angle bin while every other cell is small by
comparison. This does NOT claim bit-exact correctness against the real
core's block-floating-point rounding -- it's a concentration/framing check,
which is a real, non-trivial thing for a 6-stage, 2-real-FFT-core chain to
get right, but it is not the same as validating exact numeric output.

Uses Vivado's project-based `launch_simulation` flow, not raw
xvlog/xelab/xsim -- the real IP's simulation sources and Xilinx sim
libraries need that flow to resolve reliably, and this repo's own
`vivado_proj/` shows it already worked here once before.

**First run, 2 Sep: compiled and elaborated cleanly (confirming the
license/network guess was right -- no license error at all, simulation
really is a different feature), ran for the full 200us watchdog, then
FAILED: 0 output beats ever received.** Two real, confirmed findings from
this run, not guesses:

1. **A genuine full stall**, not a data-correctness miss -- nothing came
   out at all. Leading hypothesis, explicitly NOT confirmed: the test used
   8-point Range/Doppler transforms, and 8 may be below the real minimum
   this specific generated core accepts at runtime (the "minimum transform
   length is 8" note in earlier project history was a general statement
   about the architecture, never independently verified against this
   project's actual generated `xfft_0.xci`). If the config channel never
   completes its handshake, `gate_input_o` stays high forever and no sample
   is ever accepted anywhere in the chain -- consistent with zero beats
   over 20,000+ cycles. Changed the smoke test to 16-point as a cheap,
   fast, controlled test of this hypothesis: if 16 also stalls at 0 beats,
   the hypothesis is wrong and the real cause is elsewhere; if 16 runs
   clean, that's strong evidence for it. Not yet re-run.

2. **A separate, confirmed, real bug**, independent of the stall:
   `window_lane.sv`'s `$readmemh` of `rtl/hanning_1024.mem` failed 4 times
   (once per Range lane) -- `File ... cannot be opened for reading`. The
   path is relative to xsim's run directory
   (`build/.../sim_1/behav/xsim/`), not the project root, and the file was
   never registered as a project source, so it was never staged there. This
   means all 4 Range lanes were running with X/uninitialized window
   coefficients -- silently corrupting the Range FFT input on every prior
   run that exercised `window_lane` through this flow, including this one.
   Fixed: `run_pipeline_smoke.tcl` now registers `rtl/hanning_1024.mem` as
   a project source so Vivado's simulator stages it into the run directory
   correctly. Not yet confirmed fixed -- next run's transcript needs to
   show zero `cannot be opened` warnings.

Should not hit the Synthesis-feature license/network block that stopped
`build_synth.tcl` -- confirmed true on this run, simulation really is a
separate license feature.

**Second run, 2 Sep: still FAILED, 0 beats, at 16-point too -- the 8-point
hypothesis is RETRACTED, falsified by this run.** Bumping to 16-point
(otherwise identical) produced the exact same result: 0 output beats over
the full 200us watchdog. Since a transform-size problem would be expected
to behave differently at a different size and it didn't, the "8 may be
below the core's real minimum" hypothesis from the first run is wrong, or
at least not the (sole) cause. Retracting it rather than carrying it
forward unexamined.

Two things came out of reading the second transcript closely:

1. **The `hanning_1024.mem` warnings were still there, unchanged -- the
   first fix did not work.** `add_files -norecurse rtl/hanning_1024.mem`
   did get Vivado to export the file into the run directory (confirmed:
   `Exported '.../sim_1/behav/xsim/hanning_1024.mem'`), but Vivado
   flattens exported data files to the run directory ROOT, dropping the
   `rtl/` prefix that `window_lane.sv`'s `$readmemh("rtl/hanning_1024.mem")`
   still asks for. Wrong fix, confirmed wrong by the next run's transcript
   rather than assumed fixed. Real fix (`run_pipeline_smoke.tcl`,
   2nd attempt): pre-stage the file by hand at the exact path xsim uses --
   `<proj_dir>/<proj_name>.sim/sim_1/behav/xsim/rtl/hanning_1024.mem` --
   before `launch_simulation` runs at all. That path is not a guess, it's
   the literal path both prior run transcripts printed. `window_lane.sv`
   itself was deliberately NOT changed -- that would fix this flow and
   break `check_elab.tcl`/`build_synth.tcl`, which already pass and resolve
   `rtl/hanning_1024.mem` correctly relative to their own (repo-root)
   working directory.

2. **A separate, real, independent bug in `fft_config_fsm.sv`:** its reset
   default hardcoded `nfft_applied <= 5'd10` (1024-point) regardless of
   `NFFT_SEL0`/`NFFT_SEL1`. For any lane whose actual target differs from
   1024 -- Doppler (128/256), or this smoke test's 16 -- the FSM's first
   post-reset comparison always saw a mismatch against the WRONG default
   and issued one bogus "1024-point" config request before self-correcting
   one cycle later. Whether the real core tolerates two config writes in
   quick succession at reset, or whether that is what actually caused the
   stall, is not confirmed -- but it is a genuine bug regardless of
   whether it's the root cause, so it's fixed: the reset default is now
   `5'(NFFT_SEL0)`, matching what will actually be requested.

**Third run, 2 Sep: both fixes CONFIRMED correct -- the `.mem` warnings are
completely gone -- and the pipeline STILL stalls at 0 beats.** So the
X-propagation theory is also not the (sole) cause. Two real bugs found and
fixed by this process, neither of which was the actual root cause of the
stall. Worth sitting with that plainly: three runs, three different
theories tested against real evidence, all three wrong or insufficient.
That is not a failure of the process -- each theory was falsifiable and
got falsified by an actual run rather than being carried forward on faith
-- but it means transcript-reading has reached its limit here.

**Fourth run, 2 Sep: instrumentation paid off, ROOT CAUSE FOUND AND FIXED.**
The `$monitor` showed the input side was completely healthy: config
completed (`cfg_pending=0`, `gate_input=0`), `s_tready=1`, and 253
consecutive cycles of uninterrupted streaming into the Range FFT before
the testbench ran out of data. So the blockage was downstream, and reading
the code with that constraint made it provable rather than speculative:

**`ca_cfar` + `axis_pack4` are a hard combinational deadlock.**

- `ca_cfar.sv` advances its pipeline only `else if (m_axis_tready)`, and
  drives `assign s_axis_tready = m_axis_tready`. Its **TVALID depends on
  its TREADY**.
- `axis_pack4.sv` drives `s_axis_tready = {4{all_valid & m_axis_tready}}`.
  Its **TREADY depends on TVALID**.

Wired directly together there is no escape from reset:

```
valid_pipe = 0  ->  cfar tvalid = 0  ->  pack all_valid = 0
              ->  pack tready = 0   ->  cfar tready = 0
              ->  cfar pipeline frozen  ->  valid_pipe stays 0  (forever)
```

That explains every observation exactly: input drains fine (the upstream
skids absorb all 256 beats), and output is *exactly* zero at every
transform size, at every cube size, in every run. It was never
size-related, never the `.mem` file, never the config FSM -- those were
three real bugs found and fixed along the way, but none of them was this.

Notably `axis_skid.sv`'s own header warns about precisely this idiom
("a block that does `assign s_tready = m_tready;` forwards the downstream
ready combinationally"), and this is the same violation caught in
`axis_unpack4` on 1 Sep -- fixed there, but the pre-existing `ca_cfar` was
never audited for the same pattern. That audit gap is the actual lesson
here, more than any individual bug.

**Fix:** an `axis_skid` between each `ca_cfar` and `u_pack_out`. Its
`s_axis_tready = ~skid_valid` is high when empty regardless of downstream
ready (unfreezing the CFAR), and its `m_axis_tvalid` is a register, so the
join sees a ready-independent valid. `g_range`/`g_doppler` already end in
`axis_skid`, which is exactly why those two joins were never affected.
`ca_cfar` still has the underlying property -- contained here, documented
at the instantiation, and a trap for anyone putting it behind another join.

**Anti-loop instrumentation:** the testbench now counts accepted beats
(`valid & ready`) at all ten internal boundaries and prints the table on
both pass and timeout. Any future stall is localized by reading which
stage drops to zero -- no hypothesis required.

**Fifth run, 2 Sep: THE DEADLOCK FIX WORKS. The pipeline flows end to end.**

```
1. top input : 256   2. Range FFT out : 256   3. corner turn in  : 256
4. corner turn out : 256   5. Doppler FFT out : 256   6. Angle FFT out : 256
7. |X|^2 out : 256   8. CFAR out : 256   9. skid out : 256   10. top output : 256
```

Full 256 beats through all six stages plus the corner turn, and the run
finished naturally in 7,985 ns instead of hitting the 200 us watchdog. The
`ca_cfar`/`axis_pack4` deadlock was the real root cause, and it is fixed.

The 7 remaining errors on that run were **wrong expectations in the
testbench, not defects in the design** -- both mistakes are documented in
`tb_radar_dsp_3d_top_smoke.sv` and corrected:

1. It asserted all four angle bins must carry energy. A 4-point DFT of a
   constant gives `X[0]=4A, X[1..3]=0` exactly -- bins 1-3 reading zero is
   the *correct* answer, and the testbench's own header already said so.
   The check contradicted the physics it was written from.

2. It asserted all energy lands in range bin 0. It cannot: **`window_lane`
   applies a fixed 1024-point Hanning window regardless of the configured
   transform length.** At `N_RANGE=16` the FFT sees `w[0..15]` of a
   1024-point window -- a near-zero rising ramp, not flat DC -- and ramps
   leak. The measured leakage is symmetric about DC (range +-1 both
   652544, range +-2 both 153856), which is exactly what a *correct* FFT
   of a ramp produces. Evidence the Range stage works, not that it's
   broken.

Also confirmed clean and worth noting: every nonzero output cell sat at
doppler bin 0 (cells 0, 16, 32, 224, 240, all ≡ 0 mod 16), which is a real
check on the corner turn and Doppler stage passing on the first try.

**Genuine limitation found and documented:** the Hanning ROM is not
parameterized by transform size. Correct for the real 1024-point Range
FFT; wrong for any reduced-size run. Reduced-size simulation is therefore
structurally meaningful but never numerically representative of the real
system -- do not draw signal-quality conclusions from it.

Checks rewritten to assert what is actually true of this stimulus: angle
bin 0 only (1-3 exactly zero), all energy at doppler bin 0, and range bin
0 as the peak with leakage expected.

---

## Sixth run, 2 Sep: **PASS. 263 checks, 0 errors.**

First end-to-end functional verification of `radar_dsp_3d_top` through the
real `xfft_0` IP. All ten pipeline boundaries at 256/256 beats, completing
in 8,015 ns.

**The range profile is the strongest result, stronger than the pass line:**

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

Every mirror pair matches EXACTLY. A real-valued input's DFT must satisfy
`X[k] = X*[N-k]`, hence `|X[k]|^2 = |X[N-k]|^2`. Seven-for-seven exact
conjugate symmetry is a *numerical* correctness check on the Range FFT --
not just that data flows, but that the transform is mathematically right.
Structural testing alone could never have shown this.

### What this run proves

* The 4-lane pipeline is correct end to end: Range -> corner turn ->
  Doppler -> Angle -> |X|^2 -> CFAR, with the real Xilinx FFT core.
* Framing holds: 256 in, 256 out, TLAST cadence correct at every stage.
* Angle transform is exact: constant across antennas -> bin 0 only,
  bins 1-3 exactly zero.
* Doppler + corner turn are correct: identical chirps -> all energy at
  doppler bin 0, verified over all 256 cells.
* Range FFT is numerically sound: exact conjugate symmetry.
* No AXI-Stream deadlock, no protocol violation, no X-propagation.

### What it does NOT prove

* **Real cube size.** This is 16x16, not 1024x256. The window ROM does not
  scale with transform size, so reduced-size runs are never numerically
  representative of the production system.
* **The real corner turn.** `ctm_stub.sv`'s behavioural model is what was
  tested. The DDR-backed block still has to land and pass
  `tb_ctm_transpose.sv`.
* **Timing or resources.** Synthesis has never completed -- still blocked
  on the license server's port 2100 being unreachable off-campus.
* **BLK_EXP across varying chirps.** A constant cube can't exercise the
  "exponent identical on every chirp" assumption in `ctm_stub.sv`.

### Bugs found and fixed by this verification campaign

| # | Bug | How found |
|---|---|---|
| 1 | `ctm_stub` flat array exceeded Vivado's ~1,000,000-bit elaboration ceiling | elaboration failure |
| 2 | `hanning_1024.mem` never staged where `$readmemh` looks -- all 4 Range lanes ran on X coefficients | simulation warning, took two attempts to fix correctly |
| 3 | `fft_config_fsm` reset default hardcoded to NFFT=10 regardless of parameter, issuing one bogus config request | code review during stall hunt |
| 4 | **`ca_cfar` + `axis_pack4` combinational deadlock** (VALID depends on READY, READY depends on VALID) -- the actual root cause of a total pipeline stall | `$monitor` instrumentation, then provable from code |
| 5 | `N_RANGE`/`N_CHIRP` decoupled from the configured FFT transform length, with nothing checking they agree | code review |

Three hypotheses were raised and falsified by real runs before #4 was
found. Each was cheap to test and each was discarded on evidence rather
than carried forward -- that is why the real bug surfaced instead of being
papered over.

---

## 3 Sep: spec enforcement and repo cleanup

### Bug #6 -- the build scripts were not building the frozen spec

Found by the question "just to confirm our 3D is 1024x256x4 right?", which
is exactly the kind of question worth asking out loud:

| | Frozen spec | Was configured | Now |
|---|---|---|---|
| Range | 1024 | 1024 (`RANGE_SEL=0` -> 1024-pt) | unchanged |
| Doppler | 256 | **16 chirps, `DOPPLER_SEL=0` -> 128-pt** | `N_CHIRP=256`, `DOPPLER_SEL=1` -> 256-pt |
| Antennas | 4 | 4 (structural, 128-bit bus) | unchanged |

Left as it was, the first successful synthesis run would have reported
utilization and timing for a **1024 x 16 cube with a 128-point Doppler
transform** -- and reported them optimistically, since a 256-point Doppler
FFT needs materially more BRAM for its delay lines. Those numbers would
have been believed.

Root cause: `N_CHIRP=16` was a leftover from when `ctm_stub` held the whole
cube as a flat array and had to be kept small to elaborate. Fixing bug #1
removed that constraint, but nobody updated the dimensions afterward.

Fixed in three places -- the **module defaults now ARE the spec**, so a
reduced size must be requested explicitly rather than the spec quietly
being whatever was convenient last:

* `rtl/radar_dsp_3d_top.sv`: `N_CHIRP=256`, `DOPPLER_SEL=1'b1`
* `build_synth.tcl`: `n_chirp 256`, passes `DOPPLER_SEL=1`
* `scripts/check_elab.tcl`: same, at full 1024x256

`tb_radar_dsp_3d_top_smoke.sv` overrides these explicitly to 16x16 and is
unaffected -- confirmed by re-running it (263 checks, 0 errors).

### Repo reorganisation

`scripts/cleanup_repo.ps1` (dry-run by default). Docs to `docs/`, stale
results to `attic/`, ~30 log/journal files and 1.3 MB of `.wdb` waveform
dumps and seven regenerable build directories deleted. `.gitignore`
rewritten -- the old one caught none of `.backup.log`, `.wdb`, or build
directories, which is why they accumulated.

`synth_timing.txt` / `synth_utilization.txt` / `RESULTS_SYNTH.md` were
moved to `attic/`, NOT deleted: they are from the run that targeted
xc7a200t (Artix), and leaving them in the root invites someone to quote
them as this project's numbers.

**A near-miss worth recording.** The first cleanup script passed
`"vivado_ip"` to `Get-ChildItem -Path`. PowerShell resolved it literally so
`vivado_ip_kc705` -- which holds the generated `xfft_0` core every script
depends on -- survived. Had it been treated as a prefix, the IP would have
been destroyed. Two directory names differing only by a suffix were
separated by luck, not by design. The script now uses `-LiteralPath` for
directories plus an explicit protected list (`vivado_ip_kc705`,
`ctm_test`, `rtl`, `tb`, `scripts`, `constraints`, `attic`, `docs`) that
it refuses by exact name.

Verified after cleanup: unit tests PASS, smoke test PASS (263/0), and
`build/` rebuilt from scratch -- which is what actually proves no path
broke, rather than reading the file list.

---

## 3 Sep: **SYNTHESIS COMPLETE at full 1024 x 256 x 4**

License server reachable from the campus network (`TcpTestSucceeded: True`
on port 2100 -- the whole blocker). Elaboration and synthesis both clean at
the frozen spec.

| Resource | Used | Budget | % |
|---|---|---|---|
| LUT | 34,200 | 203,800 | **17 %** |
| FF | 57,132 | 407,600 | **14 %** |
| DSP48E1 | 216 | 840 | **26 %** |
| RAMB18 | 146 | 890 | **16 %** |
| **WNS @ 100 MHz** | **+4.505 ns** | | **timing met** |

Critical path 5.495 ns -> Fmax ~182 MHz post-synthesis. Consistent with the
162 MHz measured on this part during Stage 1.

DSP breakdown checks out against the estimate: 8 xfft cores ~192, plus 24
in fabric (8 window multipliers, 8 magnitude-squared, 8 CFAR threshold) =
216.

### Bug #7 -- the first synthesis reported an EMPTY WNS, which reads as success

The run before this one completed with `0 errors` and printed
`WNS    :  ns`. That is not "timing met" -- it is **"timing was never
analysed"**. `rtl/kc705_timing.xdc` failed three ways simultaneously:

1. **UTF-8 BOM on line 1** -> `Command '<BOM>#' is not supported in the xdc
   constraint file`. Vivado could not parse the first line.
2. **Wrong port names.** It constrained `sys_clk_p` / `sys_rst_n`; this
   module's ports are `aclk` / `aresetn`. `get_ports` matched nothing, so
   `create_clock` never ran and every path was left unconstrained.
3. **Wrong frequency** -- 250 MHz, against an architecture costed at 100.

Fixed: new `constraints/ooc_radar_dsp_3d_top.xdc` constraining the ports
that exist, no BOM, no pin assignments (meaningless out-of-context, and it
was precisely that "No ports matched" noise that camouflaged the missing
clock). `rtl/kc705_timing.xdc` is left alone -- it is a board-level file
for the eventual real top, never applicable to an OOC run of this block.

`build_synth.tcl` now **refuses to print a blank WNS**: no clock prints
`*** NO CLOCK DEFINED -- TIMING NOT ANALYSED ***`, negative slack prints
`*** TIMING NOT MET ***`. It cannot quietly look fine again.

### What these numbers do and do not mean

* **Do:** the design fits comfortably -- a quarter of the device at most on
  any axis -- and closes 100 MHz with 45 % margin.
* **Do NOT:** treat 182 MHz as achievable. This is post-synthesis, not
  post-route; routing delay is not included and implementation will consume
  part of that margin.
* **Do NOT:** treat this as final utilization. `u_ctm` is the register
  placeholder. The real DDR-backed corner turn plus its MIG controller adds
  substantial logic and its own demanding timing constraints.
* `HD.CLK_SRC` is unset in OOC mode, so clock skew is not fully modelled.

### Optimisation opportunity, noted not taken

BRAM did not change when the Doppler transform went 128 -> 256 point, and
that is not luck: all eight xfft instances are the *same* core, generated
for a 2048-point maximum. Its BRAM is fixed at generation time and the
runtime NFFT select does not alter it. The four Doppler lanes are each
carrying memory for a 2048-point transform to perform a 256-point one.
Generating a separate, smaller Doppler IP would reclaim a real fraction of
the 146 RAMB18 -- worth doing once the corner turn's true budget is known.

**Flagged, not fixed -- open assumption worth knowing about:** `ctm_stub.sv`
only latches BLK_EXP from the FIRST chirp of each frame (`wr_c==0 && wr_r==0`)
and reuses it for the whole frame, per its own documented requirement
("BLK_EXP PASSTHROUGH ... constant across a frame"). That assumes every
chirp in a cube produces the same block-floating-point exponent from the
Range FFT. For a real radar scene that's a reasonable assumption (same
target amplitudes across a coherent processing interval) but it is not a
hardware guarantee -- BFP scaling is chosen adaptively per block. The DC
smoke test above can't exercise this (a constant cube trivially has the
same exponent on every chirp). Worth validating once real, non-constant
ADC-like data is available -- not urgent, since `ctm_stub.sv` is a
placeholder either way, but the real corner-turn block inherits the same
question and should answer it deliberately, not by copying this assumption
unexamined.

---

## Verification order

```powershell
$env:Path += ";C:\Xilinx\2025.1\Vivado\bin"
cd D:\FFT_ENGINE

# 1. unit tests -- seconds, no IP needed
.\scripts\run_unit_tests.ps1

# 2. elaborate the whole design -- under a minute, catches port/width errors
vivado -mode batch -source scripts/check_elab.tcl

# 3. only when 1 and 2 are clean
vivado -mode batch -source build_synth.tcl
```

Run them in that order. Step 2 exists specifically so that a port mismatch
surfaces in 40 seconds rather than 20 minutes into synthesis.

**As of 2 Sep, none of these three have been run.** Everything in this
document is a design claim, checked by reading, not by a tool. Treat it as
unverified until step 1 produces a PASS line with your own eyes.

---

## Unit test #1 now targets the live module (fixed 2 Sep)

`run_unit_tests.ps1`'s angle-FFT test used to compile `angle_fft4.sv` — the
superseded serial/ping-pong 4-beats-in variant — against `tb_angle_fft4.sv`.
That is **not** the module `radar_dsp_3d_top.sv` instantiates (that's
`angle_fft4_par.sv`, the combinational one). A clean PASS there proved
nothing about the pipeline actually being built.

Fixed: `tb/tb_angle_fft4_par.sv` is a new testbench against the live module,
128-bit packed interface, same hand-computed DFT vectors (impulse, DC,
phasor, alternating) plus boundary cases at the exact Q1.15 rails (checking
the round/saturate path doesn't clamp inside its legal range), a
back-to-back full-throughput check, and a backpressure check in the same
style as `tb_ctm_transpose.sv` (`saw_tready_low`, so a DUT with backpressure
tied off cannot pass). This is now unit test #1 and gates pass/fail.

The old `angle_fft4.sv` / `tb_angle_fft4.sv` pair still runs, but only as a
non-blocking reference check — its result no longer decides the runner's
exit code, since nothing in the current top level uses that module.

---

## Housekeeping done (2 Sep)

Moved to `attic/`, not deleted, so history is preserved:

- `rtl/radar_dsp_top.v` → `attic/rtl/` — the stub
- `rtl/ctm_tiled_pingpong.v` → `attic/rtl/` — broken transpose
- `rtl/angle_fft_lane.sv` → `attic/rtl/` — the shift-register placeholder
- `rtl/radar_multilane_top.sv` → `attic/rtl/` — earlier experiment
- `ctm_rtl/ctm_tiled_pingpong.v`, `ctm_rtl/radar_dsp_top.v` → `attic/ctm_rtl/` — duplicates of the above
- `build_sim.tcl` → `attic/` — built the old stub pipeline against the broken transpose; superseded by `build_synth.tcl`
- `scripts/run_ooc_synth.tcl` → `attic/scripts/` — same reason

Both moved `.tcl` files got a header comment pointing at their replacement,
in case anyone finds them in `attic/` and tries to run them directly.

`build_synth.tcl` and `check_elab.tcl` were already using explicit file
lists rather than a glob, so this move changed nothing about what they
compile — confirmed by re-resolving every path in the list after the move.

**Also moved (2 Sep, second pass):** `sim/tb_radar_dsp_top.v`,
`ctm_tb/tb_radar_dsp_top.v`, `ctm_tb/tb_3d_radar_dsp.v` → `attic/sim/` and
`attic/ctm_tb/`. All three instantiated the retired `radar_dsp_top` stub.
One of them is the actual source of the original misleading result —
`sim/tb_radar_dsp_top.v` is what produced "3D PIPELINE PASSED! 65536/65536"
in `xsim.log`, a beat count, not a data check; it would have passed
unchanged against the broken transpose. `README.md` and `sim/VERIFICATION.md`
were also rewritten — both still described the retired stub architecture
as current.

**Could not remove:** the empty `ctm_rtl/` directory itself — this workspace
folder doesn't allow directory deletion once written to. It's empty and no
longer contains any RTL, so it's inert, just not gone. Same restriction
applies to `sim/` and `ctm_tb/`, now holding only the files that are still
current.

**Deliberately left alone:** `vivado_proj/`, `sim_scripts/`, `xsim.dir/`,
and the root-level `vivado_*.backup.log` / `xsim_*.backup.log` files. These
are auto-generated Vivado run artifacts from old invocations against the
stub design, not source — they'll be replaced the next time synthesis or
simulation actually runs. Left in place rather than attic'd since moving
generated output isn't housekeeping, it's noise.
