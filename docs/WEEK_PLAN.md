# Stage-1 Range-FFT — Spec Rationale + 7-Day Plan

Scope decision: **FFT_ENGINE accelerator** (xc7z020, 100 MHz, N=1024/2048, BFP, complex
input, AXI-DMA → DDR). Graded deliverable, ~7 days.
The 256-point / Z7-10 / 50 MHz student guide is a **different project** and is not used here.

---

## Part A — Specification table and why each value was chosen

Everything here is already frozen and already verified. This table exists so you can defend
each choice in a viva or report. Nothing in it changes this week.

| # | Parameter | Value | Why this and not the alternative |
|---|---|---|---|
| 1 | Device | xc7z020clg400-1 | 220 DSP / 140 BRAM36 / 53.2 k LUT. Z7-10 has 80 DSP / 60 BRAM — too tight once DMA and a second lane appear. |
| 2 | Clock | 100 MHz, PS `FCLK_CLK0` | Derived from the PS, so no extra MMCM and no clock-domain crossing to the AXI-HP port. −1 speed grade closes 100 MHz comfortably for this logic depth. |
| 3 | FFT core | Xilinx xfft v9.1 | Verified IP. A custom radix-2² SDF would save DSPs but is still **1 sample/clock** — zero throughput gain for 4–6 months of work and a from-scratch BFP implementation. |
| 4 | Architecture | Pipelined Streaming I/O | The **only** xfft architecture that sustains 1 sample/clock. All three Burst I/O options (incl. radix-4) are load→compute→unload and average *below* 1 sample/clock. |
| 5 | Radix | Radix-2 | Not a free choice — it is what Pipelined Streaming uses. "Switch to radix-4" would mean switching to Burst I/O and **losing** throughput. |
| 6 | Transform size | 1024 / 2048, runtime | Set via `s_axis_config`. Core is built for max N, so 1024 costs the same silicon as 2048. Switch only on a frame boundary. |
| 7 | Input format | complex `{Q,I}`, 16-bit Q1.15 each | Q1.15 = integer `v` represents `v/32768`, range −1.0 … +0.99997. Complex because FMCW IQ demodulation produces complex baseband; real-only would fold negative frequencies onto positive ones. |
| 8 | Scaling | Block Floating Point | Auto-scales per frame and reports `BLK_EXP`. Preserves dynamic range on the low-amplitude test vector, where fixed scale-by-2-per-stage would lose ~8 bits of SNR. |
| 9 | Rounding | Convergent (half-to-even) | Truncation biases every value toward −∞; over 11 stages that bias accumulates into a DC term that shows up as a false peak in bin 0. Convergent rounding is unbiased. |
| 10 | Output (current) | 32-bit unsigned magnitude-squared | `\|X\|² = Re² + Im²`. Worst case `(−32768)² + (−32768)² = 2³⁰ + 2³⁰ = 2³¹` → **32 bits mandatory**, not 31. No `sqrt` — it never changes bin ordering, so it would be a wasted CORDIC. |
| 11 | Backpressure | Non-Realtime throttle | Lets the core stall instead of dropping samples when DDR or DMA back up. Requires `m_axis_status_tready` to be driven — the cause of bring-up bug #4. |
| 12 | Internal bus | 256-bit AXIS, 8 bins/beat | Gives 12.6 % bus utilisation — huge slack, so the header beat costs no throughput. |
| 13 | DDR bus | 64-bit | Hard limit of the Zynq-7000 AXI-HP (AFI) port. Not a choice. |
| 14 | Header | full 32-byte beat | A 4-byte header gives a 4100-byte frame, which is **not** 32-byte aligned and misaligns every subsequent DMA burst. 32 bytes → 4128 B / 8224 B, both aligned. |
| 15 | Header fields | `BLK_EXP`, `LANE_ID`, `NFFT`, `FRAME_COUNT` | With runtime N, software cannot tell a 4128 B frame from an 8224 B one without `NFFT`. `FRAME_COUNT` gaps reveal dropped frames. Makes each frame self-describing — no out-of-band state. |
| 16 | `TLAST` | final data beat | Terminates the AXI DMA S2MM transfer in Simple mode. |

### Throughput this specification produces

| | N = 1024 | N = 2048 |
|---|---:|---:|
| sample rate | 100 MSPS | 100 MSPS |
| frames/s | 97,656.25 | 48,828.125 |
| bytes/frame | 4,128 | 8,224 |
| DDR write rate | 403.1 MB/s | 401.6 MB/s |
| 64-bit bus utilisation | 50.4 % | 50.2 % |

Note the last row: **one lane uses half of one AXI-HP port.** Two lanes need 806.25 MB/s
against 800.00 MB/s available at 100 MHz — they do not fit on one port. That is the ceiling
to quote in your report, and it is a bandwidth limit, not an FFT limit.

---

## Part B — What is realistically achievable in 7 days

**Already done:** RTL complete, 42/42 regression passing against the real xfft IP.
**Not done:** synthesis, implementation, timing, block design, PS/DMA/HP0, driver, board.

Honest assessment: getting from "simulates" to "runs on hardware and matches the golden
model" is a full week on its own **if nothing goes wrong**. Two things reliably go wrong
(see Part D). Plan for that, and cut scope from the bottom.

### Priority order

| pri | task | why | cut if behind? |
|---|---|---|---|
| P0 | Synthesis + implementation → real numbers | Converts every "TBD" in your report into a table. 3–6 h. Highest value per hour in the project. | never |
| P1 | Block design: PS + AXI DMA + HP0 + bitstream | Without this there is no hardware demo. | never |
| P2 | Bare-metal C: trigger, wait, invalidate cache, dump DDR | The frames are useless until you can read them. | never |
| P3 | Compare hardware frames vs golden model | This is criterion "FPGA matches Python". | never |
| P4 | `MODE` bit: complex-output bypass | Architectural correctness for Stage 2. Not demoed this week. | **cut first** |
| P5 | Window function (Hann) | Radar correctness. Real, but not gradeable in 7 days. | cut second |
| P6 | 2nd lane / 3-mult DSP option | Throughput. Pointless before P0 gives DSP numbers. | already out of scope |

---

## Part C — Day by day

**Day 1 — Get real numbers.**
`vivado -mode batch -source scripts/run_impl.tcl` (full impl, not `-synth-only`, so you get
routed timing). Record from `report_utilization` and `report_timing_summary`:

| resource | used | available (xc7z020) | % |
|---|---|---:|---|
| LUT | | 53,200 | |
| FF | | 106,400 | |
| BRAM36 | | 140 | |
| DSP48E1 | | 220 | |
| WNS (ns) | | must be ≥ 0 | |

If WNS is negative: report the failing path first, do not immediately drop the clock.
Most likely candidate is the magsq multiplier or the packer's 256-bit mux. One extra
pipeline stage there is cheaper than abandoning the 100 MHz spec.
Also open the xfft IP GUI and record the **exact** latency it prints for your config.

**Day 2 — Block design.** Zynq PS with `S_AXI_HP0` enabled (64-bit), `FCLK_CLK0` = 100 MHz,
AXI DMA in **Simple mode** (not Scatter-Gather — SG is a day of extra work you do not need),
Write Channel only (S2MM), buffer-length register ≥ 14 bits (8224 B needs 14). Wire your
engine's 64-bit AXIS output to `S_AXI_S2MM`. Generate bitstream.

**Day 3 — Software.** Bare-metal C in Vitis: allocate a frame buffer, start S2MM,
trigger the engine, poll for completion, **invalidate the D-cache over the buffer**, dump
as hex over UART or read via the debugger. See Part D risk #1 — this step is where the week
usually dies.

**Day 4 — Verify on hardware.** Capture 3 back-to-back frames. Check in this order:
header layout → `FRAME_COUNT` = 0,1,2 → beat count (129 or 257) → `TLAST` position →
`BLK_EXP` → peak bin. Then run your existing comparison against the golden model.
This reuses the Tier-A / Tier-B split you already have — do not write a new checker.

**Day 5 — Buffer day.** Assume you need it. If you genuinely do not, do P4 (Part E).

**Day 6 — Second lane or second FFT size.** Only if Days 1–4 all landed. Otherwise:
re-run the full 42-config regression to confirm nothing regressed, and tidy the repo.

**Day 7 — Report.** Structure that suits your evidence:
objective → spec table (Part A) → architecture → the 5 spec errors found pre-RTL →
the 5 bugs found in bring-up → **spec error #6 (Part E)** → verification methodology
(two-tier) → simulation results → synthesis/timing/utilisation (Day 1) → hardware results
(Day 4) → bottleneck analysis (403 MB/s vs 800 MB/s per HP port) → honest limitations →
future work.

---

## Part D — The two risks that will actually cost you a day

**Risk 1 — cache coherency. This is the single most common Zynq DMA failure.**
AXI DMA writes to DDR through HP0. The Cortex-A9's L1/L2 caches do not observe those writes.
If your C code reads the buffer without invalidating, you read stale data — usually zeros or
the previous frame — and it looks exactly like a broken DMA or broken RTL. You will spend
hours in the wrong place.

```c
Xil_DCacheInvalidateRange((UINTPTR)frame_buf, FRAME_BYTES);
```

Call it **after** DMA completion, **before** the first read. Alternative: mark the buffer
non-cacheable in the MMU table. Do not skip this and do not debug the RTL until it is in.

**Risk 2 — timing closure at 100 MHz on a −1 part.** Unknown until Day 1. If WNS is
negative, in order: (a) read the failing path, (b) add one pipeline register there,
(c) only as a last resort drop `FCLK_CLK0` to 50 MHz — and if you do, say so plainly in the
report with the WNS figure. A documented, understood timing failure marks better than a
silent clock reduction.

Lesser traps: `m_axis_status_tready` must stay driven (bug #4 — an elaboration warning, not
an error, so Vivado will not stop you). `NFFT` config writes must be fenced at frame
boundaries. `BLK_EXP` applies to the *complex* output — after squaring, the true scale is
`2^(2·BLK_EXP)`; document this or your first plot will be off by a factor of two in dB.

---

## Part E — The `MODE` bit (P4) — spec now, implement only if time allows

### Spec error #6, for `SPEC_DELTA.md`

> **Stage-1 magnitude-squared output is incompatible with the stated Doppler/AoA chain.**
> §18 specifies Range FFT → Corner Turn → Doppler FFT → Spatial FFT. Doppler and AoA are
> coherent transforms: they extract target information entirely from the **phase** of the
> range-bin value across chirps and across the virtual array. `\|X\|²` is real and
> non-negative — phase is discarded and cannot be recovered. As frozen, Stage-1 output can
> only produce a single-chirp range profile and cannot feed Stage 2.
> **Fix:** emit complex `{Im[15:0], Re[15:0]}` instead. Identical 32 bits per bin, identical
> 4128 / 8224-byte frames, identical header and alignment, identical 403 MB/s — and two DSPs
> cheaper. Magnitude-squared is retained as a selectable mode for range-profile bring-up.

### RTL change

Small and contained. Do **not** delete the magsq path — make it selectable, so the existing
42-config regression and your hardware demo keep working unchanged.

| item | change |
|---|---|
| new input | `mode_i` (1 bit): `0` = magsq (default), `1` = complex passthrough |
| `magsq_unit` | add `mode_i`; output mux → `mode_i ? {im_q15, re_q15} : magsq32` |
| | `magsq32` unchanged: `Re² + Im²`, 32-bit unsigned, 2 DSP48E1 cascaded via PCIN |
| | complex path must be **latency-matched** to the magsq path (register it by the same number of stages) or the packer's beat alignment breaks |
| `frame_packer` | header bit `[21]` ← `mode_i` (currently reserved) |
| `fft_stage1_engine` | plumb `mode_i` from the config register to both blocks; sample it **only at a frame boundary** — mid-frame changes would split a frame across two formats |
| golden model | add `mode` argument; emit complex bins when `mode=1` |
| testbench Tier-A | reserved-bits check must now exclude bit 21; add a `MODE` field check |
| regression | run all 42 configs in **both** modes → 84. Tier-B for `mode=1` compares Re and Im separately against the golden model, same 5 % / −40 dBc criterion. |

Expected: −2 DSP when `mode=1`, no change to bandwidth, framing, `TLAST`, alignment or
frames/s. `mode=0` must be **bit-identical** to today's output — that is the regression's
job to prove.

Estimated effort: ~0.5 day RTL, ~0.5 day golden model + regression. **Cut it if Days 1–4
slip.** Documenting spec error #6 costs nothing and captures most of the credit.
