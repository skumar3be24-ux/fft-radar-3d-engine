# Radar Accelerator RTL Modules

This directory contains the core SystemVerilog hardware description files for the multi-lane radar signal processing pipeline.

## Module Breakdown

| File Name | Description |
| :--- | :--- |
| `radar_multilane_top.sv` | Top-level wrapper managing the 4 parallel physical receive antenna lanes and synchronizing data streams. |
| `fft_engine_top.sv` | Core top-level controller orchestrating the FFT transformation pipeline stages. |
| `fft_lane.sv` | Single-lane processing unit handling independent channel data flow. |
| `window_lane.sv` | Applies window functions to raw baseband chirps before transformation. |
| `doppler_lane.sv` | Processes velocity dimensions across frames following the transpose stage. |
| `angle_fft_lane.sv` | Computes spatial phase differences across antennas for 3D direction finding. |
| `ca_cfar.sv` | Constant False Alarm Rate hardware detector for isolating target returns from noise floors. |
| `complex_mag2.sv` | Calculates the squared magnitude of complex radar return data. |
| `fft_config_fsm.sv` | Finite State Machine managing configuration states and handshakes for the FFT IP blocks. |
| `fft_status_capture.sv` | Monitors and captures execution status, overflow flags, and completion handshakes. |
| `axis_skid.sv` | AXI-Stream skid buffer used for backpressure management and pipeline pipelining. |
| `hanning_1024.mem` | Pre-calculated coefficient memory file for the 1024-point Hanning window function. |
| `timing.xdc` | Physical design constraints specifying clock definitions and timing exceptions. |
