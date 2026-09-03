# FFT Engine — Block Definition and RTL Plan

Scope: **the FFT engine block only.** Neighbouring blocks are owned by others.
Target: `xc7z020clg400-1`, 100 MHz, N = 1024 / 2048 runtime-switchable, xfft v9.1,
Pipelined Streaming, radix-2, natural order, BFP, Q1.15. Per `SPEC_FROZEN.md`.

---

## 1. Block boundary

```
   input buffer /            +=========================+          output
   corner-turn read          |     FFT ENGINE          |          processing
   (someone else)            |                         |          (someone else)
                             |                         |
  complex Q1.15  ---------->  s_axis_data    m_axis_data  ---------->  magnitude,
  {Q[15:0],I[15:0]}          |                + tuser   |            packing, header,
                             |                          |            DMA, DDR
        AXI-Lite ---------->  s_axi_ctrl      status    ---------->  status/CSR
                             +==========================+
```

**In scope:** xfft instantiation and configuration, runtime N switching, BFP exponent
capture, status-channel handling, backpressure and skid buffering, lane replication.

**Out of scope — do not build these here:** window function (input block),
magnitude / magnitude-squared (output processing), frame header and 256-bit packing
(output processing), width conversion and AXI DMA (system integration), corner turn
(Stage 2), DDR (system).

### Why the boundary is here

The engine emits what the transform natively produces: complex bins plus a block exponent.
That keeps it usable by **both** consumers — a range-profile path that squares the output,
and the Doppler path that needs phase. Putting magnitude inside this block would make it
unusable for Doppler and would hard-code a decision that belongs to the block downstream.

---

## 2. Interface contract — agree this with your senior before writing RTL

This is the part that decides whether integration works. Everything else is internal.

### `s_axis_data` — sample input, one per lane

| signal | width | notes |
|---|---|---|
| `tdata` | 32 | `{Q[15:0], I[15:0]}`, Q1.15, imaginary in the upper half |
| `tvalid` / `tready` | 1 | full backpressure, must not be tied high |
| `tlast` | 1 | asserted on sample N−1 of a frame |

### `m_axis_data` — bin output, one per lane

| signal | width | notes |
|---|---|---|
| `tdata` | 32 | `{Im[15:0], Re[15:0]}`, Q1.15 + `BLK_EXP` scale |
| `tuser` | 8 | **`BLK_EXP` for the frame**, held constant for all N beats |
| `tvalid` / `tready` | 1 | full backpressure |
| `tlast` | 1 | asserted on bin N−1 |

**Key decision:** carry `BLK_EXP` on `tuser` of the data stream rather than as a side
channel. It arrives frame-aligned and needs no separate synchronisation, so the output
block cannot mis-pair an exponent with the wrong frame. Raise this with your senior — it is
the single interface choice most likely to cause an integration bug if left implicit.

### `s_axi_ctrl` — AXI-Lite control

| reg | field | meaning |
|---|---|---|
| 0x00 | `NFFT_SEL` | 0 = 1024, 1 = 2048. Latched at frame boundary only. |
| 0x00 | `EN` | engine enable |
| 0x04 | `STATUS` | `BUSY`, `CFG_PENDING`, `OVFLO` |
| 0x08 | `FRAME_COUNT` | free-running, for the output block's header |

---

## 3. Module hierarchy

```
fft_engine_top                  parameters: NUM_LANES, NFFT_MAX
├── fft_engine_ctrl             AXI-Lite CSR, runtime N, frame fencing
└── genvar lane [NUM_LANES]
    └── fft_lane
        ├── axis_skid_in        register slice, input boundary
        ├── fft_config_fsm      config channel driver  <-- REWRITE, see §5
        ├── xfft_0              Xilinx FFT IP v9.1
        ├── fft_status_capture  drains status channel, latches BLK_EXP
        └── axis_skid_out       register slice + tuser insertion
```

Six modules, one of them vendor IP. No arbiter and no output router — with one stream per
lane, routing is the output block's decision, not this block's.

| module | purpose | latency | resources |
|---|---|---|---|
| `fft_engine_top` | structural, parameter fan-out | 0 | — |
| `fft_engine_ctrl` | CSR decode, `NFFT_SEL` fencing, frame counter | 1 | ~200 LUT/FF |
| `axis_skid_in/out` | break combinational `tready` at block edges | 1 each | ~70 FF each |
| `fft_config_fsm` | issue config word, re-issue on N change | 1 | ~50 LUT |
| `xfft_0` | the transform | ~2N `ESTIMATE` | measure |
| `fft_status_capture` | drain status, latch `BLK_EXP`, flag `OVFLO` | 1 | ~40 LUT/FF |

---

## 4. Skid buffers are not optional here

`magnitude_engine.v` in the current tree does this:

```verilog
assign s_axis_tready = m_axis_tready;    // combinational straight through
```

Legal AXI-Stream, and fine in one module. But when five separately-owned blocks each do it,
`tready` becomes one combinational path from DDR back to the ADC and timing closure becomes
impossible to debug — and impossible to attribute to any one owner.

**Register both boundaries of your block.** Costs 2 cycles of latency and ~140 FF per lane.
It also means your block's timing is yours alone, which matters when the integration
problems start.

---

## 5. Two real bugs to fix, both inside this block

**`fft_config_fsm.v` cannot switch transform size.** It latches `config_sent` high after the
first handshake and never re-asserts:

```verilog
end else if (m_axis_config_tvalid && m_axis_config_tready) begin
    config_sent <= 1'b1;          // never cleared
```

Frozen §3 requires runtime 1024/2048 switching. Rewrite: re-arm on `NFFT_SEL` change,
issue the new config word **only between frames**, and hold the input stream off until the
core has accepted it. A mid-frame config write corrupts the transform in progress.

Also confirm the IP is actually built with **Run Time Configurable Transform Length**.
The current 8-bit `config_tdata` suggests it is not — with runtime length enabled the config
word carries `NFFT` bits and the port is wider. If the IP is fixed-length, §3 cannot be met
regardless of what the FSM does.

**Status channel must be drained.** This is your own bring-up bug #4 — an unconnected
`m_axis_status_tready` fills the status FIFO and trips an internal xfft assertion on the
*second* frame. `fft_status_capture` exists specifically to own this. Drive `tready` high
and latch `BLK_EXP` on every status beat.

---

## 6. Optimizations that live inside this block

Only these. Everything else in `ARCH_REVIEW_STAGE1.md` belongs to other blocks or changes
the external contract and stays withdrawn.

| id | change | effect | interface impact |
|---|---|---|---|
| G1 | xfft **3-multiplier structure** | `ESTIMATE` −25 % DSP per lane | none |
| G3 | delay lines / twiddle in **Block RAM** | trades scarce DSP-adjacent LUT for spare BRAM | none |
| — | skid buffers at both boundaries | timing isolation | +2 cycles latency |
| — | `NUM_LANES` generate | scales with RX count | none at NUM_LANES=1 |

G1 changes rounding slightly, so freeze it once and use the same setting everywhere in the
project. If your block and someone else's reference model build the IP differently, you get
an unexplained tolerance mismatch much later with no obvious cause.

---

## 7. Order of work

1. Run synthesis on the xfft IP alone, both 3-mult and 4-mult. Record DSP/BRAM/LUT and the
   IP's reported latency. **Everything else is guesswork until this exists.**
2. Agree the §2 interface contract with your senior. Write it down.
3. Rewrite `fft_config_fsm` for runtime N (§5).
4. Add `fft_status_capture` (§5).
5. Add skid buffers, wrap as `fft_lane`, parameterise `fft_engine_top`.
6. Testbench: drive `s_axis_data`, check `m_axis_data` + `tuser` against a Python
   reference. Reuse the two-tier split — bit-exact on beat count, `tlast`, ordering and
   `tuser` stability; tolerance on bin values and `BLK_EXP`.
7. Backpressure matrix: source gaps {0, 20, 60 %} × sink stalls {0, 35, 80 %}, three
   back-to-back frames, both transform sizes, **including a size switch between frames** —
   which the current FSM would fail.
