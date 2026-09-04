# Code Review — 31 Aug 2026

Read directly from the repository, not from the manifest. Findings ordered by severity.

---

## CRITICAL 1 — Neither corner turn actually transposes

There are two divergent copies of `ctm_tiled_pingpong.v`. **Both are functionally wrong.**

### `rtl/ctm_tiled_pingpong.v` — wrong read address formula

```verilog
wire [15:0] wr_addr = wr_range_idx + (wr_chirp_idx * 512);   // row-major, CORRECT
wire [15:0] rd_addr = rd_chirp_idx + (rd_range_idx * 128);   // WRONG
```

Element (range `r`, chirp `c`) is **written** to address `r + 512c`.
To read it back, the address must also be `r + 512c`. The code computes `c + 128r`.

These agree only where `c + 128r = r + 512c`, i.e. `127r = 511c`. Within range that has
exactly **two** solutions: (0,0) and (511,127). **65,534 of 65,536 reads fetch the wrong
element.**

The loop nesting is already correct — chirp increments fastest, which is what a column read
needs. Only the arithmetic is wrong.

**One-line fix:**

```verilog
wire [15:0] rd_addr = rd_range_idx + (rd_chirp_idx * 512);
```

### `ctm_rtl/ctm_tiled_pingpong.v` — no transpose at all

```verilog
if (rd_fetch_bank == 1'b0) m_axis_data_out <= bank_A[rd_ptr];
...
rd_ptr <= rd_ptr + 1'b1;          // read pointer just increments
...
wr_ptr <= wr_ptr + 1'b1;          // so does the write pointer
```

Read order equals write order. **This is a ping-pong FIFO, not a corner turn.** The entire
purpose of the block is absent. There is no address permutation anywhere in the file.

---

## CRITICAL 2 — The 3-D testbench passes without testing the transpose

`xsim.log` reports:

```
3D PIPELINE (Range -> CTM -> Doppler -> Angle) PASSED!
3D Output Words Processed: 65536 / 65536
```

That is a **beat count**, not a data check. A plain FIFO passes it. A block that returns
garbage passes it. It confirms nothing except that 65,536 words came out.

This is the most dangerous class of result: a green light that measures the wrong thing.
Given Critical 1, the pipeline it declared PASSED is transposing incorrectly or not at all.

**The fix:** the testbench must write a known pattern — e.g. `data = {range_idx, chirp_idx}`
— and assert on read that element *n* carries the expected `(range, chirp)` pair for a
**column-major** traversal. `scripts/golden_model_3d_fft.py` exists and should be the
reference; compare values, not counts.

---

## CRITICAL 3 — Synthesis report is for the wrong chip

`build_synth.tcl`:

```tcl
# Define the exact Kintex-7 silicon part (KC705 board)
set part_name "xc7a200tfbg676-2"
```

The comment says Kintex-7. The value is **Artix-7 200T**. `synth_utilization.txt` confirms
`Device : xc7a200tfbg676-2`, with totals of 134,600 LUT / 740 DSP / 365 BRAM36 — Artix
numbers, not the KC705's 203,800 / 840 / 445.

**Every number in `synth_utilization.txt` and `synth_timing.txt` is for a board you do not
have.** Fix:

```tcl
set part_name "xc7k325tffg900-2"
```

The real KC705 figures, measured 26 Aug, are:

```
LUT 3,908 | FF 6,815 | DSP 24 | RAMB18 18 | WNS +3.844 ns | Fmax 162.4 MHz
```

---

## CRITICAL 4 — The corner turn will not fit

### `ctm_rtl` version, at 1024 x 256 x 4

```
WORDS_PER_BANK = 1024 * 256 / 4  = 65 536 words
word width     = 4 lanes * 32b   = 128 bits
per bank       = 8.39 Mbit
two banks      = 16.78 Mbit
XC7K325T BRAM  = 16.40 Mbit
                 ---------------
                 does not fit, before any FFT engine, MIG or FIFO
```

There is also a counting error: `/ LANES` is applied even though each word **already packs
4 lanes**. 65,536 words × 4 lanes = 262,144 samples, but the cube is 1,048,576 samples.
**The bank holds a quarter of what it claims to.**

### `rtl` version, at 512 x 128

```
512 * 128 * 4 B = 262 144 B = 0.26 MB per lane-channel
two banks, 4 lanes = 2.1 MB  vs  2.0 MB available
```

Also over — single-buffered it fits at ~52 % of BRAM, ping-pong does not.

**This is the 4.2 MB problem, unchanged.** No on-chip arrangement holds the cube. The MIG
DDR3 core has been generated (`ctm_test/`), which is the right direction — the corner turn
must be DDR-backed with a small on-chip working buffer.

---

## SERIOUS — `rtl/radar_dsp_top.v` is a stub with four defects

```verilog
assign doppler_out_tdata  = s_axis_data_tdata;    // "Stage 1 & 2"
assign doppler_out_tvalid = s_axis_data_tvalid;
assign s_axis_data_tready = doppler_out_tready;
```

Range and Doppler are three wires. No FFT, no CTM, no window. Only the angle FFT is
instantiated. Beyond being incomplete:

| # | defect | consequence |
|---|---|---|
| 1 | `s_axis_config_tvalid` tied to `1'b1` | Config re-issued forever; the core never leaves configuration cleanly |
| 2 | `aresetn` **not connected** | The IP has no reset. `rst_n` is an unused port |
| 3 | `m_axis_data_tuser` not connected | `BLK_EXP` discarded — output scale unrecoverable |
| 4 | Status channel not drained | The frame-2 internal assertion returns (previously fixed as defect #3) |

`ctm_rtl/radar_dsp_top.v` (6.7 kB) is the fuller version. **Two divergent tops with the same
name is itself a hazard** — `build_synth.tcl` reads `rtl/`, `run_ooc_synth.tcl` reads
`ctm_rtl/`. They will silently synthesise different designs.

---

## Stale or incorrect claims in the manifest

| claim | reality |
|---|---|
| "CURRENT ROADBLOCK: licensing failure… project constrained to behavioral simulation only" | **False since 26 Aug.** The floating licence works; the engine synthesised *and* implemented on `xc7k325t`. The earlier failure was network reachability to `2100@14.139.1.126`, not a missing feature |
| "Target clock 250 MHz (4 ns)" | Measured Fmax is **162.4 MHz** (critical path 6.16 ns) on the −2 part. 250 MHz is not reachable with this architecture |
| "Radix-4 butterfly architecture" for the Range FFT | Pipelined Streaming is internally **radix-2²**. Radix-4 is a *Burst I/O* option with **lower** throughput |
| "RTL codebase is 100% complete" | The transpose is wrong, the top level is a stub, the cube does not fit |
| Dimensions 512 × 128 × 4 | Contradicts the frozen 1024 × 256 × 4. Pick one and record it |

---

## What is genuinely good

- **MIG DDR3 generated** (`ctm_test/`) — the right move, and the hard part of the Kintex migration
- **The missing blocks now exist**: `window_lane.sv`, `complex_mag2.sv`, `ca_cfar.sv`,
  `doppler_lane.sv`, `angle_fft_lane.sv`, `hanning_1024.mem`
- **`scripts/golden_model_3d_fft.py`** — a reference model, which is exactly what Critical 2 needs
- **KC705 licence working**, engine implemented, 162 MHz, 3 % of the device
- Correct instinct on the angle stage: xfft's 8-point minimum is real, which is why a
  hardwired 4-point butterfly (`angle_fft_lane.sv`) is the right answer

---

## Recommended order of work

1. **Fix the read address** in `rtl/ctm_tiled_pingpong.v` — one line.
2. **Rewrite the CTM testbench to check data, not counts.** Write `{range_idx, chirp_idx}`,
   assert column-major order on read. Until this passes, nothing downstream is trustworthy.
3. **Delete one of each duplicate.** Keep a single `radar_dsp_top.v` and a single
   `ctm_tiled_pingpong.v`. Decide which directory is authoritative.
4. **Fix the part in `build_synth.tcl`** to `xc7k325tffg900-2` and re-run for real numbers.
5. **Decide the dimensions** — 1024 × 256 × 4 or 512 × 128 × 4 — and make every file agree.
6. **Measure DDR bandwidth** with the MIG core that is already generated. That number sizes
   the working buffer and is the last unmeasured quantity in the project.
7. Only then wire the real top level: window → range FFT → CTM → Doppler → angle → CFAR.
