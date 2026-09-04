# The Solution — 1024 × 256 × 4, Real-Time, on xc7z020

Dimensions are fixed and not negotiable. Everything below is derived from them.

```
cube        = 1024 range x 256 chirps x 4 RX = 1 048 576 cells x 4 B = 4.2 MB
frame time  = 256 chirps x 40 us                                     = 10.24 ms
frame rate  = 1 / 10.24 ms                                           = 97.7 fps
input rate  = 1 048 576 / 10.24 ms                                   = 102.4 MSPS
```

---

## 1. The one thing that cannot be avoided

**The cube goes to DDR.** 4.2 MB does not fit in 0.6 MB of BRAM, and no reordering of the
computation changes that, because Doppler cannot start until every chirp has been through
the range FFT.

We checked the alternative: processing 32 range bins at a time would need the range FFT
re-run ~32× per frame. 32× the compute to save memory. Dead end.

So the design problem is not "avoid DDR". It is **"touch DDR as few times as possible."**

---

## 2. Why the obvious design fails

Conventional three-stage pipeline with two corner turns:

```
1. range FFT out    -> DDR write    4.2 MB
2. Doppler read     <- DDR read     4.2 MB   strided
3. Doppler out      -> DDR write    4.2 MB
4. angle read       <- DDR read     4.2 MB   strided
5. result out       -> DDR write    4.2 MB
                                    --------
                                    21 MB/frame x 97.7 = 2.05 GB/s
```

Zybo DDR peak is 4.26 GB/s; with strided access and PS traffic, realistically 2.1–2.5 GB/s.
**2.05 of 2.5 is not a design, it is a coin flip.** And on PYNQ-Z2 (16-bit bus, 2.1 GB/s
peak) it is outright impossible.

---

## 3. The architecture — three moves, one DDR round trip

```
ADC 4ch ──> RANGE FFT ──> DDR (the cube, 4.2 MB) ──> read blocks ──┐
            2 lanes                                                │
                                                                   v
        ┌──────────────────────────────────────────────────────────┐
        │  4x DOPPLER FFT  (one per antenna, N=256, in parallel)    │
        │            │                                             │
        │            v  all 4 antennas of a cell arrive together    │
        │  4-point ANGLE butterfly   (no multipliers)               │
        │            │                                             │
        │            v                                             │
        │  magnitude ──> CFAR detection                             │
        └────────────────────────┬─────────────────────────────────┘
                                 v
                       DDR: target list only (~KB)
```

### Move 1 — Parallelise the antenna axis, delete corner turn #2

Run **four Doppler engines side by side, one per antenna**. All four antenna values for a
given (range, Doppler) cell then emerge on the same clock cycle and feed straight into the
4-point angle FFT — whose twiddles are 1, −j, −1, +j, so it is **eight adders and zero
DSPs**. Steps 3 and 4 vanish.

```
21 MB -> 12.6 MB per frame
```

### Move 2 — CFAR inside the pipeline, before writeback

The useful output is a target list, not a cube. Detect on-chip and step 5 collapses from
4.2 MB to a few kilobytes.

```
12.6 MB -> 8.4 MB per frame  ->  0.82 GB/s
```

**0.82 GB/s against ~2.5 GB/s available. 3× margin.** That is a design.

### Move 3 — Block-based DDR reads, small on-chip working buffer

DDR holds the cube; BRAM holds only the slice being worked on. Read 16 consecutive range
bins for each chirp — 64-byte bursts, efficient for DDR3.

```
working buffer = 16 range bins x 256 chirps x 4 RX x 4 B x 2 (ping-pong)
               = 131 072 B = 1.05 Mbit = 58 RAMB18 = 21 % of BRAM
```

---

## 4. Resource budget

| block | count | DSP48E1 | RAMB18 |
|---|---:|---:|---:|
| Range FFT lane (N=2048, measured) | 2 | 48 | 36 |
| Doppler FFT (N=256) | 4 | ~64 | ~16 |
| Angle FFT (4-point, adders only) | 1 | **0** | 0 |
| Magnitude + CFAR | 1 | ~4 | ~4 |
| Working buffer (ping-pong) | 1 | 0 | 58 |
| **Total** | | **~116 / 220 (53 %)** | **~114 / 280 (41 %)** |

Range needs 2 lanes because the input is 102.4 MSPS and one lane is 100 MSPS. Each lane
handles 2 antennas at 51.2 MSPS.

Doppler is only 26 % utilised (262 144 points per antenna per frame = 2.62 ms of the
10.24 ms budget). The four engines exist to kill the corner turn, not for speed.

---

## 5. Throughput achieved and what limits it

```
required        97.7 frames/s
compute limit   ~195 frames/s   (range stage: 200 MSPS capability vs 102.4 needed)
DDR limit       ~297 frames/s   (2.5 GB/s available / 8.4 MB per frame)
                --------------
achieved        2x margin over real time, compute-limited
```

End-to-end latency ≈ 10.24 ms (range, concurrent with acquisition) + ~2.6 ms (Doppler,
angle, CFAR) ≈ **13 ms**.

**To go faster still**, in order of value:

1. Raise the clock. Post-route Fmax measured at 138 MHz; at 125 MHz one range lane covers
   102.4 MSPS on its own, freeing 24 DSPs.
2. Reduce intermediate precision in the cube. Storing 8+8 bit instead of 16+16 halves the
   DDR traffic to 0.41 GB/s. Costs SNR — needs analysis before committing.
3. More range lanes. DSP allows it; DDR allows it. Only worth doing if the radar frame rate
   actually rises.

---

## 6. Literature position — stated honestly

I could not find a post-2022 paper that solves this exact problem. What the search did turn
up, and what it actually supports:

- **Streaming range-Doppler with inline peak detection on Zynq-7000** — a 2026 arXiv preprint
  on mmWave vital-sign monitoring reports a fully streaming AXI-Stream pipeline that
  integrates peak detection without intermediate memory storage, ~1.1 ms end-to-end latency,
  ~35 % LUT / 42 % BRAM / 6 DSP on Zynq-7000. Different application (phase extraction, not a
  full range-Doppler-angle cube), but it is direct evidence that **inline detection instead
  of buffering works on this exact device family**.
- **OS-CFAR used explicitly for data reduction** in an FPGA MIMO radar processing unit
  (16 channels, 250 MSPS, 56 Gbit/s). Supports Move 2 — detection as a bandwidth-reduction
  step, not just a final classifier. Older work (2015), so cite as background, not novelty.

**What is genuinely ours:** the antenna-parallel fusion that removes an entire corner turn
(Move 1). I have not found this specific structure published for a 3-axis radar cube on a
bandwidth-limited SoC. It is defensible as a contribution because the saving is
quantifiable — 40 % of DDR traffic — and it exploits a property specific to MIMO radar:
the angle axis is short enough to make parallel, and making it parallel is what removes the
transpose.

If you want a publishable claim, that is the one to build the paper around, with the
measured before/after DDR bandwidth as the result.

---

## 7. What to do next, in order

1. **Confirm the radar parameters.** 40 µs chirp and 97.7 fps drive every number here. If
   your chirp is different, the arithmetic changes.
2. **Measure real DDR bandwidth on the Zybo** with a strided access pattern before
   committing. Everything hinges on the ~2.5 GB/s assumption, and it is the one number I
   have estimated rather than measured.
3. Build the working-buffer + block-read logic first. It is the highest-risk new block.
4. Instantiate 2 range lanes and 4 Doppler lanes from the existing verified engine.
5. Add the 4-point angle butterfly (adders only) and CFAR.
