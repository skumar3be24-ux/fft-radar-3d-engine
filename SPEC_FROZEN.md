# Stage-1 Range-FFT Engine — Frozen Specification (Integration Contract)

**Purpose:** single source of truth for integrating this engine into the main FFT
accelerator. Every value below is taken from the specification you supplied, with the
source section cited. **No value here was chosen by me for convenience.**

**Precedence:** this document overrides the optimization proposals in
`ARCH_REVIEW_STAGE1.md`. Those are recorded as *future work only* and must not be applied
without an explicit spec change.

---

## 1. Frozen interface contract — do not change

| # | Parameter | Frozen value | Source |
|---|---|---|---|
| 1 | Device | `xc7z020clg400-1` (Z7-20 primary; Z7-10 via TCL flag) | §1 |
| 2 | Clock | 100 MHz, PS `FCLK_CLK0`, 10 ns period | §2 |
| 3 | Transform size | 1024 and 2048, **runtime switchable** | §3 |
| 4 | FFT core | Xilinx FFT IP v9.1 | §4 |
| 5 | Architecture | Pipelined Streaming I/O | §4 |
| 6 | Radix | Radix-2 | §4 |
| 7 | Output ordering | **Natural order** | §4 |
| 8 | Arithmetic | Block Floating Point | §4, §8 |
| 9 | Input data | 16-bit Q1.15 complex, `{Q, I}` | §4, §6 |
| 10 | Twiddle / phase factors | 16-bit Q1.15 | §4, §25 |
| 11 | Rounding | Convergent (round-half-to-even) | §4, §9 |
| 12 | Throughput | 1 sample/clock = 100 MSPS per lane | §4, §21 |
| 13 | Output data | **32-bit unsigned magnitude-squared** | §7 |
| 14 | Internal bus | 256-bit AXI-Stream, 8 × 32-bit per beat | §11 |
| 15 | DDR bus | 64-bit (Zynq-7000 HP port limit) | §11 |
| 16 | Throttle scheme | Non-Realtime | §10 |
| 17 | Stream signals | `TVALID`, `TREADY`, `TLAST`, full backpressure | §10 |
| 18 | Multi-channel | `NUM_LANES` parameter, one lane per RX / chirp | §1 |

### Header layout (§8, §12) — bit-exact, do not modify

```
[7:0]     BLK_EXP        block-floating-point exponent for this frame
[15:8]    LANE_ID        RX channel that produced the frame
[20:16]   NFFT code      10 = 1024-point, 11 = 2048-point   (= log2 N)
[31:21]   reserved       zero
[63:32]   FRAME_COUNT    increments per frame; a gap = a dropped frame
[255:64]  reserved       zero
```

### Frame format (§12) — bit-exact, do not modify

```
beat 0            32-byte header beat
beat 1 .. N/8     32-byte data beats, 8 x 32-bit values each
                  bin 0 in the low bits
TLAST             asserted on the final data beat

frame bytes = 32 x (1 + N/8)      N=1024 -> 4128      N=2048 -> 8224
both 32-byte aligned -> no DMA padding between consecutive frames
```

### Derived rates (§21) — arithmetic, not choices

| | N = 1024 | N = 2048 |
|---|---:|---:|
| frames/s | 97,656.25 | 48,828.125 |
| DDR write rate | 403.125 MB/s | 401.5625 MB/s |
| 64-bit bus utilisation | 50.4 % | 50.2 % |

---

## 2. Withdrawn — proposals that would break integration

Every item below was raised in `ARCH_REVIEW_STAGE1.md`. All are **withdrawn** because they
alter the frozen contract. Retained here only so they are not silently reintroduced.

| id | proposal | why it is withdrawn |
|---|---|---|
| O3 | Bit-reversed output, permute in corner turn | Violates frozen §4 "Natural order" and changes packing order (Tier-A). Breaks the frame contract. |
| O5 | Run DMA/HP path at 150 MHz | Introduces a clock domain not in §2. Adds a CDC at the integration boundary. |
| O7 | 16-bit log-magnitude output | Violates §7 (32-bit magsq) and halves bytes/bin, changing frame size and alignment. |
| — | Drop `FCLK_CLK0` to 50 MHz on timing failure | **My error.** Violates §2. If timing fails, fix the path — never the spec. Removed from `WEEK_PLAN.md`. |
| O2 | Hann/Blackman window before FFT | Radar-correct, but changes the numerical result and the golden model. Belongs in the accelerator's input stage, applied uniformly, not bolted onto Stage 1 alone. **Future work.** |
| O6 | Input-side channel time-multiplex | Restructures how lanes are shared. §1 freezes `NUM_LANES` with one lane per RX. Do not change unilaterally. **Future work.** |
| O8 | Additional physical lanes | Governed by `NUM_LANES`; a system-level decision, not a Stage-1 one. |

**Unchanged conclusion (§20):** keep the Xilinx FFT IP. Custom RTL is still rejected — it is
1 sample/clock either way, so it delivers no throughput gain and would break numerical
reproducibility against the integrated system.

---

## 3. Specification gaps — silent in your document, must be frozen before integration

These are xfft v9.1 options your specification does **not** pin down. I am not choosing them
for you. Each one must be frozen and recorded, because if Stage 1 and the main accelerator
build the IP with different settings, results will differ and integration debugging becomes
very hard.

| # | Option | Affects | Recommendation + reason | Status |
|---|---|---|---|---|
| G1 | Complex Multiplier Structure (4-mult / 3-mult / CLB) | **DSP count and rounding** | Freeze **one** value across the whole project. 3-mult saves ~25 % DSP at no timing cost at 100 MHz, but rounds differently from 4-mult. | **needs your decision** |
| G2 | Butterfly arithmetic (XtremeDSP vs CLB logic) | DSP vs LUT trade | XtremeDSP, consistent with a DSP-based datapath | needs sign-off |
| G3 | Data / Phase Factor memory type | BRAM vs LUTRAM. No numerical effect. | Block RAM — BRAM is the resource you have spare (140 vs 220 DSP) | needs sign-off |
| G4 | Optional output fields | Interface width | Currently unstated. If `XK_INDEX` / `OVFLO` are enabled, the output bus widens and the packer changes. | **needs your decision** |
| G5 | Cyclic prefix insertion | Frame content | Must be **disabled** — not in the spec, and it would corrupt the frame format | needs sign-off |
| G6 | Output width under BFP | Datapath | With BFP, output width = input width = **16 bits** per component, scale carried in `BLK_EXP`. Confirm this matches your build. | verify |
| G7 | `ARESETn` assertion length | Bring-up | xfft requires a minimum active-low reset duration. Confirm from the datasheet, not from assumption. | verify |
| G8 | `BLK_EXP` semantics after magsq | Software | The exponent applies to the **complex** output. After squaring, true scale is `2^(2·BLK_EXP)`. Undocumented in `README.md`. | **document** |
| G9 | `NFFT` config write timing | Correctness | Runtime size changes must be fenced at a frame boundary. Confirm the RTL enforces this. | verify |

**G1 is the important one.** It is the only gap that changes numbers rather than just
resources, and a mismatch between this engine and the main accelerator would show up as an
unexplained Tier-B tolerance failure much later.

---

## 4. Does this contract survive integration? — checked against §18

Future system dimensions from §18, **clearly labelled future**, checked against the frozen
frame format:

| future stage | N | `NFFT` code = log2 N | fits 5-bit field `[20:16]`? | N mod 8 = 0? | frame bytes | 32-byte aligned? |
|---|---:|---:|---|---|---:|---|
| Range FFT | 4096 | 12 | yes (max 31) | yes | 16,416 | yes |
| Doppler FFT | 256 | 8 | yes | yes | 1,056 | yes |
| Spatial FFT | 16 | 4 | yes | yes | 96 | yes |
| Spatial FFT | 8 | 3 | yes | yes | 64 | yes |
| Spatial FFT | 4 | 2 | yes | **no** | — | — |

**Good news:** the header and frame format scale cleanly to 4096-point Range, 256-point
Doppler and 8/16-point Spatial with no change. The 5-bit `NFFT` field and the 32-byte
alignment rule were well chosen and are already integration-ready.

**One future incompatibility, flagged now so it is designed for rather than discovered:**
the packing rule is 8 bins per 256-bit beat, so it requires `N mod 8 == 0`. A **4-point
spatial FFT produces 4 bins = 16 bytes = half a beat.** The current format cannot express a
partial beat. Options when you reach that stage: zero-pad to 8 bins, use `TKEEP`, or define a
narrower bus for the spatial stage. No action needed now — but do not assume the format
covers it.

---

## 5. The one open item that is genuinely an integration problem

Not an optimization, and not a preference — a contract mismatch between two of your own
sections.

- §7 / §11 / §12 freeze Stage-1 output as **32-bit magnitude-squared**.
- §18 specifies the chain **Range FFT → Corner Turn → Doppler FFT → Spatial FFT**.

Doppler and Spatial/AoA are coherent transforms: they recover target velocity and angle
entirely from the **phase** of each range bin across chirps and across the virtual array.
`|X|²` is real and non-negative, so phase is discarded and cannot be reconstructed.

The consequence is specifically an integration consequence: **Stage 2 cannot consume
Stage 1's output as currently frozen.** Freezing the interface does not avoid this — it
locks it in.

**Maximally integration-safe resolution** (preserves every frozen value above):

```
mode = 0  ->  32-bit unsigned magnitude-squared    DEFAULT, bit-identical to today
mode = 1  ->  32-bit complex {Im[15:0], Re[15:0]}  for Stage 2
```

Same 32 bits per bin. Same 4128 / 8224-byte frames. Same header, alignment, `TLAST`,
beat count, frames/s and 403 MB/s. `mode` is carried in reserved header bit `[21]`, so
existing readers that ignore reserved bits are unaffected, and `mode = 0` must be proven
bit-identical to the current build by regression.

This is a decision for you, not for me. Recorded here as **spec error #6** pending your
ruling; nothing will be implemented against it without your sign-off.
