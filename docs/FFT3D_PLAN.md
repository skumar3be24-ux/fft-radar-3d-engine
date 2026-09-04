# 3-D FFT Engine — Design Plan

Target: `xc7z020clg400-1`, 100 MHz. Reuses the existing 1-D FFT engine block.

---

## 0. What is actually being built

A multidimensional DFT is **separable**. There is no 3-D butterfly — every 3-D FFT is three
sets of 1-D FFTs along orthogonal axes, with a transpose between them. So this is not a new
transform; it is a **new block boundary** that pulls the transposes inside.

```
          +----------------------------------------------------------------+
          |                     3-D FFT ENGINE                             |
          |                                                                |
 cube in  |  1-D FFT  ->  cube      ->  1-D FFT  ->  cube    ->  1-D FFT   | cube out
 -------->|  axis 1       buffer A      axis 2       buffer B    axis 3    |-------->
          |  N=256        (transpose    N=32         (transpose  N=4       |
          |               by address)                by address)           |
          |      ^             ^            ^            ^          ^      |
          |      +-------------+--- sequencer ----------+----------+       |
          +----------------------------------------------------------------+
```

| axis | transform along | yields | N |
|---|---|---|---:|
| 1 | samples within a chirp | range | 256 |
| 2 | chirps | Doppler / velocity | 32 |
| 3 | RX antennas | angle of arrival | 4 |

---

## 1. The constraint that sets every dimension

```
full radar cube  1024 x 256 x 4 x 32 bit  =  33.55 Mbit
xc7z020 BRAM                              =   4.92 Mbit
                                             ------------
                                             6.8x short
```

A full-size 3-D FFT engine **cannot hold its intermediate cube on this device**. It would
need DDR-backed transposes, which drags AXI master ports, burst logic and the whole
bandwidth problem inside the block — at which point the "3-D FFT engine" is the entire
accelerator.

**Decision: build the scaled-down, fully on-chip version first.** It proves the architecture
end to end with no DDR, no bandwidth problem, and no dependency on anyone else's block.

### Chosen dimensions

```
256 range x 32 Doppler x 4 RX = 32 768 complex words
                              x 32 bit = 1.05 Mbit per cube
two cube buffers (A and B)             = 2.10 Mbit  = 43 % of BRAM
```

Batch operation: one cube at a time, three passes in sequence. Continuous streaming would
need four buffers (write cube k+1 while reading cube k), which does not fit at these
dimensions — see section 7.

---

## 2. Key simplification: the transpose is free

If the cube lives in on-chip memory, a transpose is **purely an addressing change**. No data
moves. Only the address generator differs between passes:

```
axis 1 read:  addr = ((ant * N_dop) + chirp) * N_rng + sample     stride 1
axis 2 read:  addr = ((ant * N_rng) + bin)   * N_dop + chirp      stride N_rng
axis 3 read:  addr = ((bin * N_dop) + dop)   * N_ant + ant        stride N_rng*N_dop
```

**And at 1 sample/clock there are no bank conflicts.** Conflict-free skewed addressing (as
in the team's `skewed_agu.v`) is only needed when a design must read several words per
cycle. Our FFT consumes exactly one sample per clock, so a single BRAM port at one word per
clock is sufficient regardless of stride. This makes the transpose dramatically simpler than
a parallel corner turn.

---

## 3. Module plan

```
fft3d_engine_top
├── fft3d_sequencer          pass control, dimension registers, start/done
├── cube_buffer_a            BRAM cube store + address generator
├── cube_buffer_b            BRAM cube store + address generator
│    └── cube_agu            shared: axis-ordered address generation
├── fft_engine_top  (axis 1) N=256   <- EXISTING BLOCK, new IP build
├── fft_engine_top  (axis 2) N=32    <- EXISTING BLOCK, new IP build
├── fft_angle_parallel       N=4     <- NEW, parallel butterfly
└── exp_accumulator          sums BLK_EXP across the three passes
```

**Two of the five blocks already exist and are verified.** The 1-D engine drops into axes 1
and 2 unchanged except for the IP build and a widened `nfft_sel`.

### New modules

| module | function | notes |
|---|---|---|
| `cube_agu` | Generates read/write addresses for each axis ordering | Pure counters and a multiply-free index calculation; strides are constants per pass |
| `cube_buffer` | Dual-port BRAM array holding one cube | Write port from previous stage, read port to next |
| `fft3d_sequencer` | Runs pass 1 → 2 → 3, swaps buffers, asserts done | Small FSM; the only global control |
| `fft_angle_parallel` | 4-point FFT, fully parallel | 4-point twiddles are 1, −j, −1, +j — **no multipliers at all**, only adds and sign swaps |
| `exp_accumulator` | Sums the three `BLK_EXP` values | True cell scale is 2^(E1+E2+E3); getting this wrong gives a plausible but badly wrong magnitude |

---

## 4. Resource estimate

| item | DSP48E1 | RAMB18 |
|---|---:|---:|
| Axis-1 engine, N=256 (⌈log₄256⌉ = 4 mults) | ~16 | ~4 |
| Axis-2 engine, N=32 (⌈log₄32⌉ = 3 mults) | ~12 | ~2 |
| Axis-3 parallel butterfly, N=4 | **0** | 0 |
| Cube buffers A + B (2.10 Mbit) | 0 | ~117 |
| Sequencer, AGUs, exponent logic | 0 | 0 |
| **Total** | **~28 / 220 (13 %)** | **~123 / 280 (44 %)** |

`ESTIMATE` — only the axis-1 and axis-2 DSP figures follow the measured radix-2² rule
(24 DSP at N=2048 for 6 multipliers). Confirm by building each IP.

---

## 5. Throughput

Every pass transforms the whole cube, so all three passes process the same point count:

```
points per pass = 256 x 32 x 4 = 32 768
at 1 sample/clock, 100 MHz     = 327.68 us per pass

batch (3 passes in sequence)   = 983 us per cube  ->  1 017 cubes/s
pipelined (3 engines at once)  = 327.68 us        ->  3 052 cubes/s
```

For scale: a real radar frame of 256 chirps at 40 us each is 10.24 ms. Even batch mode is
**10x faster than the radar produces data**, which confirms that throughput is not the
problem here — memory capacity is.

---

## 6. Build order

| phase | work | proves |
|---|---|---|
| 1 | `cube_agu` + `cube_buffer`, standalone testbench | Transpose addressing is correct in isolation — the highest-risk new logic |
| 2 | Generate xfft IPs for N=256 and N=32; widen `nfft_sel` to 5 bits; add `generate` for IP selection in `fft_lane` | Existing block reused, not rewritten |
| 3 | `fft_angle_parallel` (4-point, adds only) + testbench | Cheapest block, no multipliers |
| 4 | `fft3d_sequencer` + integration | Passes run in order, buffers swap |
| 5 | Full 3-D verification against `numpy.fft.fftn` | End-to-end numerical correctness |
| 6 | Synthesis + implementation | Fits and closes 100 MHz |
| 7 | Hardware demo on Zybo | Runs on silicon |

**Phase 1 first, deliberately.** The address generator is the only genuinely new hard logic;
everything else is either reuse or trivial. If the transpose addressing is wrong, nothing
downstream can be trusted.

---

## 7. Verification

The golden model is one line, which is the main advantage of doing this properly:

```python
import numpy as np
cube_in  = (I + 1j*Q).reshape(N_ant, N_dop, N_rng)
ref      = np.fft.fftn(cube_in, axes=(2, 1, 0))     # range, Doppler, angle
```

Two-tier, matching the 1-D block's methodology:

- **Tier A, bit-exact:** cube element ordering, beat counts per pass, TLAST placement,
  buffer swap timing, accumulated exponent value.
- **Tier B, tolerance:** peak cell position must match exactly (a 3-D point target should
  land in one cell); per-cell error within tolerance for cells above −40 dBc.

Stimulus: a single simulated point target — a complex exponential in all three dimensions
simultaneously — must produce **one peak cell** at the expected (range, Doppler, angle)
coordinate. That single test exercises every axis and both transposes at once.

---

## 8. Open decisions

1. **Does absorbing the corner turn conflict with the team split?** The team already has
   `corner_turn_top.v` and `skewed_agu.v`. A 3-D FFT engine takes that function inside this
   block. Either that work is superseded, or the boundary needs redrawing. **Agree this
   before phase 1.**
2. **Batch or pipelined?** Batch needs 2 cube buffers, pipelined needs 4. At 256×32×4 only
   batch fits. Pipelined would require dropping to 128×32×4.
3. **Angle zero-padding.** 4 RX gives 4 angle bins, which is very coarse. Zero-padding to 8
   or 16 improves angular resolution for almost no cost, since the padded FFT is still
   multiplier-free at N=8. Decide before phase 3.
4. **Dimension scaling path to full size.** The architecture is unchanged going to
   1024×256×4; only the cube buffer moves from BRAM to DDR. Worth keeping the buffer
   behind a clean interface so that swap is possible later without touching anything else.
