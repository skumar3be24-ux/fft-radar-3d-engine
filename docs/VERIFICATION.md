## Verification Plan

**Stale as of 2 Sep** — this described verifying `ctm_tiled_pingpong.v`
(broken, now in `attic/`) via `sim/tb_radar_dsp_top.v` (also attic'd: it
only checked a beat count, `65536/65536`, never the actual data — it would
have passed against the broken transpose unchanged). See `ARCHITECTURE_3D.md`
for the real, current verification plan and order. Short version:

- `tb/tb_angle_fft4_par.sv` — value-checks the live angle-FFT module.
- `tb/tb_ctm_transpose.sv` — value-checks per-cell, per-lane transpose
  ordering, BLK_EXP passthrough, TLAST, and backpressure. This is the
  acceptance test the real corner-turn block must pass unchanged.
- `scripts/check_elab.tcl` — elaborates the full `radar_dsp_3d_top.sv`.
- `build_synth.tcl` — full out-of-context synthesis, correct KC705 part.

None of the above have been run yet.
