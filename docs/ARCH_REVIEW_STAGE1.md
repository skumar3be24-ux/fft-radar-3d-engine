# Stage-1 Range-FFT Engine — Architecture Review (Parts 1–6)

**Reviewer stance:** critical. **Scope:** FFT engine only, except where an external
block provably gates FFT-engine value.
**Basis:** the frozen specification text and `README.md` as supplied. The RTL itself
was **not** inspected (workspace mount unreadable at review time). Any statement about
your module internals is inference, flagged as such.

**Evidence labels used throughout:** `FACT` (device/IP datasheet or arithmetic identity),
`CALC` (arithmetic derived here, reproducible), `ESTIMATE` (engineering judgement, error
bars given), `ASSUMPTION` (input I had to supply), `SPECULATION` (low confidence).

---

## Part 1 — Specification audit

### 1.1 Constraints understood and accepted

Target `xc7z020clg400-1`; 100 MHz `FCLK_CLK0`; N ∈ {1024, 2048} runtime-switchable;
xfft v9.1 Pipelined Streaming, radix-2, natural order, BFP, Q1.15 data and twiddle,
convergent rounding, 1 sample/clock, Non-Realtime backpressure; 32-bit unsigned
magnitude-squared; 256-bit internal AXIS → 64-bit DDR; 32-byte header beat; frames of
4128 B / 8224 B; `TLAST` on final data beat; two-tier verification with the stated
tolerances; no synthesis numbers claimed. All five prior spec errors and five bring-up
bugs noted and will not be reintroduced.

### 1.2 BLOCKING contradiction — magnitude-squared destroys phase

**This is the most serious finding in the review and it outranks every throughput question.**

§18 states the chain is `Range FFT → Corner Turn → Doppler FFT → Spatial/AoA FFT`.
§7/§11/§12 freeze the Stage-1 output as 32-bit **magnitude-squared**.

`FACT`: Doppler FFT and AoA/spatial FFT are *coherent* operations. Doppler is a DFT of the
complex range-bin value across slow time; AoA is a DFT of the complex value across the
virtual antenna array. Both extract target information **entirely from phase**. |X|² is
real and non-negative — the phase is gone and is not recoverable.

Consequence: the current Stage-1 output is usable **only** for a single-chirp range-profile
display. It cannot feed Stage 2. As frozen, Stage 1 and §18 cannot both be true.

`CALC` — the fix is close to free:

| | current | complex passthrough |
|---|---|---|
| bits/bin | 32 (unsigned magsq) | 32 (`{Im[15:0], Re[15:0]}` Q1.15) |
| bytes/frame | 4128 / 8224 | 4128 / 8224 (unchanged) |
| DDR rate | 403.1 / 401.6 MB/s | unchanged |
| header, alignment, `TLAST`, beat count | — | unchanged |
| DSP | +2 (magsq) | 0 |

Same width, same framing, same bandwidth, **two DSPs cheaper**, and Tier-A structural
checks survive verbatim. Recommendation: make `magsq` a **runtime-bypassable** block
(`MODE` bit in the config register, echoed into a spare header bit) — complex for the
radar chain, magsq for range-profile bring-up and for the existing 42-config regression.

I am **not** changing this unilaterally (Rule 1). Flagging it for your decision.

### 1.3 Missing requirement — there is no throughput target

§19 says "maximize throughput." That is unbounded and therefore unengineerable. The
required aggregate sample rate is fully determined by radar parameters you have not stated:
number of RX antennas, TX scheme (TDM vs DDM), chirp duration, samples per chirp, chirps
per frame, frame repetition rate.

Why this is decisive — `CALC` for a conventional FMCW configuration:

```
1024 range bins, 40 µs chirp  ->  ADC rate = 1024 / 40e-6 = 25.6 MSPS per RX
4 RX antennas                 ->  aggregate = 102.4 MSPS
```

One 100 MSPS lane already covers **four** RX antennas at that chirp rate. If your radar
looks anything like this, the FFT engine has ~4× margin *today* and every hour spent
raising its throughput is wasted. I cannot pick between "one lane, time-multiplexed" and
"four physical lanes" without this number. Part 6 gives a decision rule instead of a guess.

### 1.4 Secondary ambiguities and inconsistencies

1. **No window function.** `FACT`: rectangular-window peak sidelobe is −13.3 dBc. Your own
   Tier-B criterion tests bins down to −40 dBc, and your two-tone vector is 40 dB separated
   — leakage from the strong tone will sit ~27 dB *above* the weak tone's true level at
   nearby bins. The regression passes only because the golden model uses the same
   rectangular window, so both are wrong identically. This is a correctness defect for
   radar, not a feature gap. Hann gives −31.5 dBc, Blackman-Harris-4 gives −92 dBc.
2. **Data source undefined.** `FACT`: Zybo Z7-20's on-chip XADC is ~1 MSPS / 12-bit and
   there is no high-speed ADC front end on the board. 100 MSPS of live ADC input is not
   physically achievable on this platform. `ASSUMPTION`: input will come from DDR
   (pre-loaded vectors) or a PL-resident generator. This flips the bandwidth arithmetic in
   Part 3 — DDR-sourced input costs a *read* as well as a *write*.
3. **NFFT field width.** Header allocates `[20:16]` (5 bits) for an NFFT code but only two
   values are legal. Fine, but confirm the encoding is the xfft `NFFT` value (10/11) and
   not an index, and that the config-channel write is fenced at a frame boundary.
4. **`BLK_EXP` semantics after magsq.** The exponent belongs to the *complex* output. After
   squaring, the true scale is `2^(2·BLK_EXP)`. The header carries `BLK_EXP` unmodified, so
   software must know to double it. Undocumented in the README. Document it or the first
   consumer will get a 2× dB error.
5. **`BLK_EXP` field width.** 8 bits for a value that cannot exceed `log2(2048) = 11`.
   Harmless, but 4 bits would free 4 bits for `MODE`/window-ID.
6. **Multi-lane arbiter is written but unexercised.** Untested RTL in the tree is a
   liability, and Part 6 argues the arbiter may be the wrong structure anyway (the sharing
   point should be on the *input* side, not the output side).
7. **"Non-Realtime mode"** is the correct choice and is not in question; noting only that it
   means the xfft can stall internally, so any custom replacement inherits a non-trivial
   backpressure obligation (see Part 4).

---

## Part 2 — Baseline analysis (1 × xfft v9.1, Pipelined Streaming, 100 MHz)

### 2.1 Throughput — `CALC`, exact

```
f_clk = 100 MHz,  1 complex sample / clock / lane,  input word = 32 bit (Q,I)
```

| quantity | N = 1024 | N = 2048 |
|---|---:|---:|
| input samples/s | 100,000,000 | 100,000,000 |
| input bytes/s | 400.000 MB/s | 400.000 MB/s |
| cycles to ingest one frame | 1024 | 2048 |
| frame ingest time | 10.24 µs | 20.48 µs |
| FFTs/s = frames/s | 97,656.25 | 48,828.125 |
| output bins/s | 100,000,000 | 100,000,000 |
| 256-bit beats/frame | 1 + 128 = 129 | 1 + 256 = 257 |
| 64-bit beats/frame | 516 | 1028 |
| bytes/frame | 4,128 | 8,224 |
| output bytes/s | **403.125 MB/s** | **401.563 MB/s** |

Header overhead = 1/129 = 0.775 % (N=1024), 1/257 = 0.389 % (N=2048). The README's
"~403 MB/s" is confirmed correct.

**Sustained-rate check (this is where a header beat could have bitten you):** the packer
must emit `1 + N/8` beats inside `N` cycles.

```
N=1024: 129 beats in 1024 cycles -> 256-bit bus 12.6 % utilised
N=1024: 516 beats in 1024 cycles -> 64-bit bus  50.4 % utilised
N=2048: 1028 beats in 2048 cycles -> 64-bit bus 50.2 % utilised
```

`CALC`: the header costs no throughput. It is absorbed in idle beat slots. Confirmed safe —
but note the 64-bit domain is already at **50 %**, which is the number that governs Part 3.

### 2.2 Latency — distinct from throughput

Structural decomposition of a pipelined SDF-style streaming FFT with natural-order output:

```
L_total ≈ (N − 1)        SDF stage delay lines, N/2 + N/4 + ... + 1
        + N              output reorder buffer (natural-order option)
        + Σ mult/butterfly pipeline registers
        ≈ 2N + O(log2 N · 6)
```

`ESTIMATE` (±15 %, must be read from the Vivado IP GUI "Latency" field, which reports it
exactly for your configuration):

| | N = 1024 | N = 2048 |
|---|---:|---:|
| xfft latency | ~2.1 k cycles ≈ 21 µs | ~4.2 k cycles ≈ 42 µs |
| magsq + packer + downsizer | ~20 cycles ≈ 0.2 µs | ~20 cycles ≈ 0.2 µs |

The reorder buffer is roughly **half** the total latency — see optimization O3 in Part 5.

**Rule 4 restated concretely:** latency ≈ 2N *and* throughput = 1 sample/clock are
simultaneously true. Frames pipeline back to back; the 21 µs never accumulates. Do not
"optimize" latency in the belief it raises throughput. On this design latency matters only
for closed-loop tracking response, which Stage 1 does not have.

### 2.3 Is the IP configuration itself already optimal?

`FACT`: of the four xfft v9.1 architectures, only **Pipelined Streaming I/O** sustains
1 sample/clock continuously. Radix-4 Burst I/O, Radix-2 Burst I/O and Radix-2 Lite Burst I/O
are load→compute→unload; their averaged throughput is strictly below 1 sample/clock.

**So "switch the IP to radix-4" would *reduce* throughput.** Your current selection is the
correct one, and radix-4 is only meaningful in a custom design (Part 4).

---

## Part 3 — Bottleneck analysis

### 3.1 Single lane, rate-matched stage by stage — `CALC`

| stage | capability | required | utilisation |
|---|---:|---:|---:|
| input AXIS (32 b @ 100 MHz) | 400 MB/s | 400 MB/s | **100 %** |
| xfft (1 sample/clk) | 100 MSPS | 100 MSPS | **100 %** |
| magsq (feed-forward, 2 DSP) | 1 bin/clk | 1 bin/clk | **100 %** |
| packer, 256-bit bus | 3200 MB/s | 403 MB/s | 12.6 % |
| downsizer / 64-bit AXIS | 800 MB/s | 403 MB/s | 50.4 % |
| AXI DMA S2MM (64 b @ 100 MHz) | 800 MB/s theo. / ~700 real `ESTIMATE` | 403 MB/s | 50–58 % |
| AXI-HP (AFI) port, 64 b @ 100 MHz | 800 MB/s | 403 MB/s | 50.4 % |
| PS DDR3L (32-bit @ 1066 MT/s) | 4264 MB/s peak `FACT`, ~2.5–3 GB/s sustained `ESTIMATE` | 403 MB/s | ~15 % |

**At one lane nothing downstream is stressed.** The FFT and magsq are the only 100 %-utilised
blocks, and they are 100 % *by construction* — a 1 sample/clock pipe fed at 1 sample/clock
is exactly balanced, not congested. There is no throughput being lost anywhere today.

### 3.2 The wall appears at lane 2, and it is not the FFT

`CALC`:

```
2 lanes × 403.125 MB/s = 806.25 MB/s
one 64-bit AXI-HP port @ 100 MHz = 8 B × 100e6 = 800.00 MB/s

806.25 / 800.00 = 100.78 %   ->  two lanes overflow one HP port by 0.78 %
```

Two lanes miss a single HP port by under one percent — and that is the *theoretical* port
figure, before AXI address phases and DMA descriptor fetches. `ESTIMATE`: realistic
sustained per-port throughput is 85–90 % of theoretical, i.e. ~680–720 MB/s, so in practice
**one HP port carries exactly one lane at 100 MHz.**

`FACT`: Zynq-7020 has 4 AXI-HP (AFI) ports. The GP ports are 32-bit and not viable for
bulk data. Therefore:

```
HP-bandwidth ceiling @ 100 MHz PL = 4 ports × 1 lane = 4 lanes = 400 MSPS aggregate
```

and that consumes **100 %** of the PL→PS interface, leaving nothing for Stage 2's
corner-turn traffic.

### 3.3 If input also comes from DDR, halve everything

Per §1.4.2, on a Zybo Z7-20 the samples almost certainly arrive from DDR:

```
per lane: 400 MB/s read (samples) + 403 MB/s write (bins) = 803 MB/s
        = one entire HP port per lane, exactly
```

`CALC`: 4 lanes then need ~3.2 GB/s of PS-DDR traffic against a ~2.5–3 GB/s realistic
sustained budget that the ARM cores, caches and peripherals also draw on. **4 lanes is not
sustainable in a DDR-sourced configuration. 2–3 is.**

### 3.4 The real system bottleneck is Stage 2's corner turn, not Stage 1

`CALC`: a range-Doppler corner turn buffer for 1024 range × 256 Doppler × 4 channels of
32-bit complex data:

```
1024 × 256 × 4 × 32 bit = 33.55 Mbit
```

`FACT`: xc7z020 total BRAM = 140 × 36 kbit = 4.9 Mbit — and the FFT lanes need a slice of
it. The corner turn is **~7× too large for on-chip memory** and must go through DDR. Each
corner turn is a full write plus a full strided read of the frame set. Strided DDR access
with a stride of 4 kB is close to worst case for a DDR3 page-hit rate.

`ESTIMATE`: once Stage 2 exists, DDR bandwidth — not the FFT, not the HP port — is the
binding system constraint, and strided corner-turn efficiency (not peak bandwidth) is the
number that will decide the design.

### 3.5 Answer to §22 and §42

**The FFT engine is not the bottleneck and is not close to being one.** In order, the true
limiters are:

1. Stage-2 corner-turn DDR bandwidth and strided-access efficiency (system-level, unbuilt).
2. AXI-HP port bandwidth: 800 MB/s/port at 100 MHz → 1 lane per port.
3. DSP48 budget (220) → `ESTIMATE` 4–6 lanes; see Part 4.
4. The FFT compute itself — last, with zero margin lost.

Optimising the FFT engine for throughput as the primary objective is, on the evidence
available, **optimising the wrong block**.

---

## Part 4 — Architecture alternatives

### 4.1 Resource baseline — what is actually scarce

`FACT` (xc7z020-1): 53,200 LUT · 106,400 FF · 220 DSP48E1 · 140 BRAM36 (280 BRAM18) ·
0 URAM.

`ESTIMATE` per xfft lane (N=2048 max, runtime-configurable length, 16 b data, 16 b phase,
BFP, natural order, non-realtime) — **error bars are wide and this must be replaced by the
number the Vivado IP customization GUI prints, which takes five minutes to obtain:**

| resource | per lane | basis |
|---|---:|---|
| DSP48E1 | 27–44 | ~9 non-trivial twiddle stages × 3 (3-mult) or 4 (4-mult) |
| BRAM36 | 8–14 | delay lines ≈ (N−1)×32 b + reorder 2N×32 b + twiddle ROM |
| LUT | 3–5 k | control, BFP exponent tracking, AXIS wrappers |

`CALC` from the midpoints: DSP allows ~5–6 lanes, BRAM allows ~10–15. **DSP is the binding
on-chip constraint, and it lands in the same 4–6 range as the HP-port ceiling.** Two
independent limits converging on 4 is a reassuring cross-check.

### 4.2 Option comparison

Throughput is quoted per engine at 100 MHz. "Effort" is one competent engineer including
verification to your current 42-config standard.

| option | samples/clk | DSP | BRAM | runtime N | BFP | AXI backpressure | effort | verdict |
|---|---:|---:|---:|---|---|---|---:|---|
| **A** 1 × xfft IP | 1 | 27–44 | 8–14 | native | native | native | 0 (done) | baseline |
| **B** P × xfft IP lanes | P | P × 27–44 | P × 8–14 | native | native | native | 1–3 wk | **scales, linear cost** |
| **C1** custom R2SDF | 1 | ~27 | ~8 | moderate | hard | must build | 3–5 mo | **no gain — reject** |
| **C2** custom R4SDF | 1 | ~20 | ~10 | N=2048 needs mixed final stage | hard | must build | 4–6 mo | poor mult utilisation |
| **C3** custom R2²SDF | 1 | **~15** | ~8 | easy (power-of-4 + trailing R2) | hard | must build | 4–6 mo | best custom, still 1 s/clk |
| **C4** R2²MDC, P paths | **P** | ~15·P·0.7 | ~8 | moderate | very hard | must build | 6–9 mo | only wins on *one* stream |
| **C5** fully parallel | N | infeasible | — | — | — | — | — | reject on area |
| **D** hybrid (IP core + custom window/magsq/pack) | 1 per lane | as A + 2–4 | as A | native | native | native | days | **already what you have** |

### 4.3 The decisive argument against custom RTL

`CALC`, radix-2² multiplier saving: non-trivial twiddle stages are `log2(N) − 1 = 9` for
R2SDF at N=1024, versus `log4(N) = 5` for R2²SDF, because the `W^(N/4) = −j` twiddles reduce
to a real/imaginary swap and a negate. Saving = `1 − 5/9 = 44 %` of complex multipliers.
That is a real and well-established result, and R2²SDF is unambiguously the right choice
*if* you build a custom FFT.

**But it buys you no throughput.** C1/C2/C3 are all 1 sample/clock — identical to what you
have. They trade 4–6 months of engineering and the loss of a verified IP for a DSP saving
that only matters if DSP is proven to be the thing blocking your required lane count. It is
not proven; it is not even measured.

Only **C4 (multi-path MDC)** exceeds 1 sample/clock in a single engine. And here is why it
is still wrong for you:

> An MDC only helps when you must transform **one** stream faster than 1 sample/clock.
> A MIMO radar does not have one stream — it has one independent stream **per RX antenna**.
> P independent streams are served exactly as well by P independent 1-sample/clock engines,
> which you can instantiate today by copy-pasting an IP block.

The parallelism the problem hands you is *already* at the granularity the Xilinx IP works at.
This is the single strongest reason to keep the IP.

Add to that: BFP is the hard part of any custom build. A streaming SDF cannot know the block
maximum before it has seen the block, so BFP requires per-stage overflow detection with
conditional scaling and correct exponent accumulation — precisely the logic that produces
your `BLK_EXP`. Getting it wrong degrades the low-amplitude and near-full-scale vectors in
your regression, and getting it right is subtle, unglamorous work. The fixed-scaling
alternative (shift-by-1 per stage) costs SNR exactly on your low-amplitude test case.

**Verdict on §20:** Option **B** (multiple Xilinx IP lanes), in the **D** hybrid shape you
already have. Custom RTL is rejected — not because it is hard, but because it delivers
0 % throughput improvement for 4–6 months of risk. Revisit only if synthesis proves DSP
blocks a lane count you have *independently proven you need*.

---

## Part 5 — Optimization opportunities, ranked

Ranked by (impact ÷ risk). Every entry is quantified; none is intuition.

| # | optimization | throughput Δ | resource Δ | risk | effort |
|---|---|---|---|---|---|
| **O1** | **Bypass magsq → emit complex bins** (§1.2) | 0 % | **−2 DSP/lane** | low | days |
| **O2** | **Add window multiplier before FFT** | 0 % | +2 DSP, +1 BRAM36/lane | low | days |
| **O3** | **Bit-reversed output; permute in corner turn** | 0 % | **−4 BRAM36, −N cycles latency/lane** | med | 1 wk |
| **O4** | **xfft "3-multiplier structure"** | 0 % | **−25 % DSP/lane** | low | hours |
| **O5** | **Clock-domain split at the downsizer** | +50 % lanes/port | +1 async FIFO/lane | med | 1 wk |
| **O6** | **Input-side channel time-mux, 1 engine** | 0 %, 4× efficiency | **−3 lanes of DSP/BRAM** | low | 1–2 wk |
| **O7** | 16-bit log-magnitude output | 2× lanes/port | +1 BRAM (LUT), −2 DSP | high | 2 wk |
| **O8** | P physical lanes, 1 HP port each | +P× | +P× everything | med | 1–3 wk |

### O1 — magsq bypass. Do this first.
Not an optimization; a correctness fix (§1.2). Zero bandwidth change, −2 DSP, unblocks
Stage 2 entirely. **Highest value item in this document.**

### O2 — window function. Do this second.
`FACT`: rectangular −13.3 dBc → Hann −31.5 dBc → Blackman-Harris-4 −92 dBc peak sidelobe.
Cost `CALC`: complex sample × real coefficient = 2 real multiplies = **2 DSP48E1**.
Coefficients exploit even symmetry → store N/2 = 1024 × 16 b = 16 kbit = **1 BRAM36**
(holds both a 1024- and 2048-point table if you address-stride).
Numerical note: 16 b × 16 b → 32 b must be convergently rounded back to Q1.15 for the xfft
input, costing `ESTIMATE` ~0.5 bit of SNR. Acceptable; must be modelled in the golden model
or Tier-B will diverge. Make the window selectable (rect / Hann / BH4) so the existing
42-config regression can run in rect mode unchanged.

### O3 — bit-reversed output.
`CALC`: the natural-order option costs a 2N × 32 bit double-buffered reorder RAM
(N=2048 → 131 kbit ≈ 4 BRAM36) and ~N cycles of latency. The consumer is a corner-turn
memory whose address generator is a permutation unit already — absorbing bit-reversal into
its write-address mapping is free (it is a wire reordering on the address bus, zero logic).
Saves ~4 BRAM36 and ~20 µs per lane for no throughput cost.
Breaks the Tier-A packing-order check and the current DDR frame layout → **spec change,
requires your approval.** For direct-from-DDR software bring-up, a 1024-entry permute on a
Cortex-A9 is negligible.

### O4 — 3-multiplier complex multiplier. One checkbox.
This is the FPGA-specific analysis §26 asks for, and the answer is *not* the textbook one.

```
(a+jb)(c+jd) = (ac − bd) + j(ad + bc)
4-mult: 4 multiplies, 2 adds
3-mult: k1=(a+b)c,  k2=a(d−c),  k3=b(c+d)
        Re = k1 − k3,  Im = k1 + k2      -> 3 multiplies, 3 pre-adds, 2 post-adds
```

Key insight for this device: **`c` and `d` are twiddle ROM constants.** Store `(c+d)` and
`(d−c)` pre-computed in the ROM (ROM grows 2 → 3 words/entry, 1.5×, and BRAM is the
resource you have spare). Only `(a+b)` remains a runtime pre-add — and the DSP48E1's
25-bit pre-adder computes `D±A` for free ahead of the multiplier, so it costs nothing.

```
4-mult: 4 DSP, post-adds absorbed into DSP cascade via PCIN/ADDSUB  -> ~0 fabric
3-mult: 3 DSP, 1.5× twiddle ROM, 2 fabric post-adders (~35 LUT @ 18 b)
```

On a device with 220 DSP and 140 BRAM, trading 25 % of your scarcest resource for
~35 LUT and half a BRAM is clearly correct — and at 100 MHz the extra fabric adder has
enormous timing slack. Xilinx exposes this directly as **"Complex Multiplier Structure →
Use 3-multiplier structure (resource optimized)"**.
Caveat: rounding differs slightly between the two structures, so re-run the full regression;
Tier-A is unaffected, Tier-B tolerances may shift within the existing ±1 `BLK_EXP` band.

### O5 — clock-domain split.
Keep the FFT domain at 100 MHz exactly as frozen; run only the downsizer → DMA → HP path
at 150 MHz. `CALC`: 8 B × 150e6 = 1200 MB/s per port → 806 MB/s (2 lanes) = 67 %
utilisation. Converts the "1 lane per HP port" limit into "2 lanes per HP port."
Crossing point is the existing 256→64 boundary; an async FIFO there is a well-understood
structure. Does **not** violate §2 — the FFT engine still closes at 100 MHz.
`ESTIMATE`: AFI ports on a −1 part are comfortable at 150 MHz; above that, verify.
Only worth doing if O6 does not already solve your problem.

### O6 — input-side channel time-multiplex. **The structural insight.**
Your multi-lane arbiter shares hardware on the **output** side. That is the wrong end.
The xfft is inherently frame-atomic: feed it channel 0's N samples, then channel 1's N
samples, and it produces per-channel frames natively — with `LANE_ID` in the header, a field
your frame format *already has*.

```
4 × ADC ch ──> per-channel input buffers ──> N-sample round-robin mux ──> 1 × xfft ──> ...
                 4 × N × 32 b                (switch at frame boundary only)
```

`CALC` buffer cost: 4 × 1024 × 32 b = 131 kbit ≈ **4 BRAM36** (N=1024), 8 BRAM36 (N=2048).
`CALC` benefit vs. 4 physical lanes: saves 3 × (27–44) = **81–132 DSP** and
3 × (8–14) = **24–42 BRAM36**, for 4–8 BRAM36 spent. Roughly **a 20:1 return.**
Valid whenever `Σ per-channel sample rate ≤ 100 MSPS`, which per §1.3 is likely true with
margin. The output arbiter disappears — frames are already serialised.

### O7 — 16-bit log-magnitude. **Flagged, not recommended yet.**
Halves output bandwidth → doubles lanes per HP port. But it is *mutually exclusive with O1*:
you cannot do Doppler on log-magnitude either. Correct placement is after the **Doppler/AoA**
FFTs, in Stage 3, where CFAR wants log scale anyway. Recorded here so it is not lost;
do not apply it to Stage 1.

### O8 — physical lane replication.
The only thing on this list that actually raises throughput. Do it **last**, only after
O6 is shown insufficient, and only up to the measured DSP ceiling. Do not assume linear
scaling (Rule 5): each lane needs its own DMA (`ESTIMATE` +2–3 k LUT, +4–8 BRAM each) and
its own HP port, and 4 lanes exhausts the PL→PS interface entirely (§3.2).

---

## Part 6 — Recommended architecture

### 6.1 Primary recommendation

**Keep the Xilinx FFT IP. One physical engine. Parallelism on the input side, by channel,
at frame granularity. Do not build a custom FFT.**

```
   ch0 ─┐
   ch1 ─┤   ┌──────────────┐   ┌─────────┐   ┌────────────┐
   ch2 ─┼──>│ per-channel  │──>│ frame   │──>│  window    │  16b Q1.15
   ch3 ─┘   │ input buffer │   │ round-  │   │  mult      │  (rect/Hann/BH4)
            │ 4×N×32b BRAM │   │ robin   │   │  2 DSP     │
            └──────────────┘   │  mux    │   │  1 BRAM    │
                               └────┬────┘   └─────┬──────┘
                                    │ LANE_ID      │
                                    v              v
                         ┌────────────────────────────────────┐
                         │  xfft v9.1                         │
                         │  Pipelined Streaming, radix-2      │
                         │  BFP, Q1.15, convergent rounding   │
                         │  runtime N = 1024 / 2048           │
                         │  >> 3-multiplier structure  (O4)   │
                         │  >> non-realtime (backpressure)    │
                         │  natural order  (bit-rev = O3 opt) │
                         └───────────────┬────────────────────┘
                                         │ BLK_EXP + complex bins
                                         v
                              ┌──────────────────────┐
                              │  output stage        │
                              │  MODE=0 complex (O1) │   <-- default, feeds Stage 2
                              │  MODE=1 magsq 32b    │   <-- bring-up / range profile
                              └──────────┬───────────┘
                                         v
                          skid ──> packer 256b ──> downsizer 64b ──> DMA ──> HP0
                                   (+32B header: BLK_EXP, LANE_ID,
                                    NFFT, MODE, FRAME_COUNT)
```

**Why this and not something more impressive:**

1. `CALC` §1.3 — one 100 MSPS engine plausibly covers all 4 RX channels. Adding lanes before
   proving you need them buys nothing measurable.
2. `CALC` §3.2 — the HP port caps you at ~1 lane/port at 100 MHz anyway. Extra FFT throughput
   would have nowhere to go.
3. `CALC` §4.3 — custom RTL at 1 sample/clock is a 0 % throughput change for 4–6 months of
   risk and the loss of a verified IP. MDC only pays on a single stream; you have four.
4. `CALC` O6 — input-side muxing saves 81–132 DSP for 4–8 BRAM, ~20:1.
5. O1 makes the output usable by Stage 2 at all. Everything else is moot until that is fixed.

Preserved unchanged: 100 MHz, Q1.15 in/out, BFP + `BLK_EXP`, convergent rounding, runtime N,
AXIS with `TVALID`/`TREADY`/`TLAST` and full backpressure, 256→64 packing, 32-byte header,
4128/8224 B frames, 32-byte alignment.

### 6.2 Decision rule for scaling — resolve §1.3 first

```
R_agg = N_RX × (samples_per_chirp / chirp_duration)      [aggregate MSPS]

R_agg ≤  90 MSPS   -> 1 engine + O6 input mux.        STOP. Add margin, not lanes.
90 < R_agg ≤ 180   -> 2 engines, 2 HP ports, or 1 HP port + O5 clock split.
180 < R_agg ≤ 360  -> 4 engines, 4 HP ports + O5. Requires DSP ≤ 55/lane (measure!).
R_agg > 360 MSPS   -> xc7z020 is the wrong device. Move to Z7-45/ZU+, or re-scope.
```

Note the last line honestly: **the Zybo Z7-20 has a hard ceiling around 400 MSPS aggregate**,
set by 4 HP ports and 220 DSP, and DDR corner-turn traffic will pull the sustainable figure
below that once Stage 2 exists. No FFT architecture changes this.

### 6.3 Fallback architecture

**2 × xfft lanes, one AXI DMA and one HP port each, O4 enabled, O6 input mux across
2 channels per lane.** 200 MSPS aggregate, 8 channels at 25 MSPS, ~50 % of HP capacity,
`ESTIMATE` ~70–100 DSP. Chosen only if measured `R_agg` exceeds 90 MSPS. Structurally
identical to the primary — one instantiation parameter, not a redesign.

### 6.4 Rejected, with reasons

| rejected | reason |
|---|---|
| Custom R2²SDF | 0 % throughput gain; 4–6 mo; BFP re-implementation risk |
| Custom R2²MDC | Only helps a single stream; MIMO gives per-antenna parallelism free |
| Radix-4 inside xfft | Burst I/O architecture — **lower** throughput than streaming |
| >4 physical lanes | Exceeds HP-port and DSP budget of xc7z020 |
| Clock > 100 MHz on the FFT | Violates frozen §2; O5 achieves the goal without it |
| 16-bit log-mag in Stage 1 | Destroys phase, same defect as O1 fixes |

---

## Immediate actions, in order

1. **Answer §1.2** — should Stage 1 emit complex bins? (I believe yes; it is your call.)
2. **Answer §1.3** — N_RX, chirp duration, samples/chirp. Everything scales off this.
3. **Run `scripts/run_impl.tcl -synth-only`** and post `report_utilization` +
   `report_timing_summary`. Rule 14: DSP/BRAM/LUT/Fmax **cannot be determined analytically.**
   Every "4–6 lanes" figure above collapses to a single number once you do this.
4. Open the xfft IP GUI and record the **exact** latency and the resource estimate it prints
   for your configuration, for both 4-mult and 3-mult structures. Five minutes; replaces
   most of my error bars.
5. Only then: decide lanes, and only then write RTL.

---

## Review summary

**Strengths.** Verification quality is genuinely above typical for a project at this stage —
the two-tier split (bit-exact structural vs. tolerance numerical) is the correct
methodology and the 42-config matrix with source-gap and sink-stall crossing is real
backpressure coverage, not a token stall test. Using the actual xfft IP rather than a stub
is the right call and caught bug 4. The spec-error log and bug log are honest and show
`m_axis_status_tready` was diagnosed properly rather than papered over with a FIFO. The
README's explicit "what is NOT done" section is exactly the right discipline. 32-byte header
alignment and the self-describing frame are good, defensible engineering.

**Weaknesses.** Magnitude-squared output makes Stage 1 unusable by Stage 2 (§1.2) — this
should have surfaced during specification, not review. No window function, which means the
sidelobe behaviour is radar-invalid and the regression cannot detect it because the golden
model shares the defect. No stated throughput requirement, so "maximize throughput" has no
success criterion. Untested multi-lane arbiter sitting in the tree. `BLK_EXP` post-magsq
scaling semantics undocumented. No synthesis data, which makes every resource question
unanswerable.

**Biggest risks.** (1) Building Stage 2 and discovering the phase loss then, after the
corner-turn RTL is written to a magnitude-shaped interface. (2) DDR corner-turn bandwidth
and strided-access efficiency killing the system after Stage 1 is "finished" — 33.6 Mbit of
corner-turn state against 4.9 Mbit of on-chip BRAM is a 7× shortfall with no on-chip escape.
(3) Synthesis returning a DSP count that caps lanes at 2–3, invalidating any plan built on 4.
(4) Effort sunk into FFT throughput that the HP port cannot carry away.

**Blind spots.** The Zybo Z7-20 has no 100 MSPS data source — the input path is undefined and
if it is DDR-sourced, read traffic silently halves your lane budget. Sharing was placed on
the output side (arbiter) when the input side is where the leverage is. Latency and
throughput are correctly distinguished in your prompt but the natural-order reorder buffer
(~half the latency, ~4 BRAM) has not been questioned. The 3-multiplier IP option — a 25 %
DSP saving behind one checkbox — appears to be unexplored. And the whole framing assumes the
FFT is the thing to optimise; the rate table in §3.1 says it is the one block with no slack
to recover.

**Better alternatives.** Fix the output format (O1) and add a window (O2) before touching
throughput. Enable the 3-multiplier structure (O4). Move channel sharing to the input side
(O6) instead of replicating lanes. Split the clock domain at the downsizer (O5) rather than
raising the FFT clock. Consider bit-reversed output (O3) and fold the permutation into the
corner-turn address generator. Keep custom RTL on the shelf until synthesis proves DSP is
blocking a lane count you have proven you need.

**Overall verdict.** The existing engine is well built and, for its stated 1 sample/clock
target, close to optimal — the Xilinx IP with Pipelined Streaming is the correct choice and
should be kept. But the optimisation objective is aimed at the wrong block: the FFT has no
recoverable slack, while the HP port, the DSP budget and eventually DDR do. More urgently,
the frozen output format is incompatible with the stated radar chain, and that defect
outranks every throughput question in this document. Fix correctness, measure in Vivado,
then scale — in that order.

**Confidence: 78 %.** High (>95 %) on the phase/magnitude-squared contradiction, on the
throughput arithmetic in Part 2, on the 806 vs 800 MB/s HP-port calculation, and on
Pipelined Streaming being the only 1-sample/clock xfft architecture. Moderate (~70 %) on the
per-lane DSP/BRAM estimates and the resulting lane ceiling — these are the numbers most
likely to move, and only synthesis settles them. Lower (~55 %) on sustained DDR and AFI
figures for this specific board, and on my `ASSUMPTION` about the data source. **Reduced
overall because I could not read your RTL** — the mounted folder was unreadable, so this
review reflects your specification, not your implementation.
