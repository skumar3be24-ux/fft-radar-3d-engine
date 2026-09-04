# FFT Engine — Measured Synthesis Results

Vivado 2025.1, `xc7z020clg400-1`, out-of-context synthesis of `fft_engine_top`,
`NUM_LANES = 1`, 100 MHz constraint. xfft v9.1 linked from its own OOC checkpoint.

These are **measured**, not estimated. They supersede every `ESTIMATE` in
`ARCH_REVIEW_STAGE1.md`.

## Per-lane resources

| resource | used | xc7z020 | % | lanes this allows |
|---|---:|---:|---:|---:|
| LUT | 4,036 | 53,200 | 7.6 % | 13 |
| FF | 6,871 | 106,400 | 6.5 % | 15 |
| DSP48E1 | **24** | 220 | 10.9 % | **9** |
| RAMB18 | 18 (9 RAMB36-equiv) | 280 | 6.4 % | 15 |

Wrapper logic (2 × skid, config FSM, status drain) accounts for only ~163 FF and
~90 LUT of that; the rest is the IP.

## Timing

```
WNS = +5.824 ns on a 10.000 ns period
critical path ~= 4.176 ns  ->  Fmax ~= 240 MHz
```

2.4x margin at the frozen 100 MHz. Caveat: OOC **synthesis**, not implementation, and
`HD.CLK_SRC` is unset so clock skew is not modelled. Post-route will be worse. The margin
is large enough that this is not a concern.

## Finding: the IP is radix-2 squared, not radix-2

The synthesis log shows **six** `cmpy_4_dsp48_mult` variants at 4 DSP each = 24 DSP, and
elaboration instantiates `r22_memory__parameterized5`.

```
plain radix-2 SDF, N=2048 : log2(2048) - 1 = 9  non-trivial complex multipliers
radix-2^2      , N=2048  : ceil(log4(2048)) = 6 non-trivial complex multipliers
measured                  : 24 DSP / 4 per cmpy = 6
```

Xilinx's "Radix-2, Pipelined Streaming I/O" is internally **radix-2 squared**. The `-j`
twiddles reduce to a real/imaginary swap and negate, so only every second stage needs a
real multiplier.

**Consequence for `ARCH_REVIEW_STAGE1.md` Part 4:** the claim that a hand-written radix-2^2
SDF would save ~44 % of DSPs versus the IP is **withdrawn**. The IP already uses that
structure. A custom FFT would deliver roughly the same DSP count, the same 1 sample/clock
throughput, and would additionally require reimplementing BFP. The case for custom RTL is
weaker than the review stated, and it was already rejected.

## Decision: G1 frozen at 4-multiplier structure

`CONFIG.complex_mult_type = use_mults_performance`.

3-mult would give 24 -> 18 DSP, raising the DSP-allowed lane count from 9 to 12. That is
unusable: AXI-HP bandwidth caps the design near 4 lanes (403 MB/s per lane against
800 MB/s per 64-bit port at 100 MHz, 4 ports). Trading a change in rounding behaviour for
DSPs that cannot be fed is a bad deal.

**Use this value everywhere in the project.** A mismatch between this block and any
reference model changes rounding and surfaces later as an unexplained Tier-B tolerance
failure with no obvious cause.

## Corrected bottleneck picture

| limit | lanes |
|---|---:|
| DSP48E1 | 9 |
| LUT | 13 |
| BRAM / FF | 15 |
| **AXI-HP bandwidth** | **~4** |

The review said DSP and bandwidth "converge on ~4". They do not. On-chip resources permit
roughly 2x more lanes than the PL-to-PS interface can carry. **Bandwidth is the sole
binding constraint**, which further devalues any optimisation aimed at FFT area or speed.

## Still unverified

`fft_config_fsm` field positions (`NFFT_LSB = 0`, `FWD_INV_LSB = 8`) are inferred from
PG109, not proven. The 16-bit width is confirmed by `xfft_0.veo`, and it is consistent with
two byte-padded fields, but the ordering is not. This synthesises correctly either way and
will fail in simulation as a wrong transform size or an inverse transform.

**First thing the testbench must check.**
