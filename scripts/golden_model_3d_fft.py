import numpy as np

# Radar Data Cube Dimensions -- FROZEN SPEC (SPEC_FROZEN.md / PROJECT_LOG.md Day 1)
# Do not change without an explicit spec change. Was previously 512x128x4, which
# no longer matched the frozen 1024x256x4 cube used throughout the RTL, build
# scripts, and testbenches -- fixed so this golden model is a valid numerical
# reference for the actual design rather than a stale, smaller stand-in.
N_range = 1024
N_doppler = 256
N_angle = 4

print("Generating synthetic 16-bit complex ADC data cube...")
raw_adc = np.random.randn(N_range, N_doppler, N_angle) + 1j * np.random.randn(N_range, N_doppler, N_angle)

# Mathematical 3D FFT Reference
print("Computing Range FFT (Dim 1)...")
range_fft = np.fft.fft(raw_adc, axis=0)

print("Computing Doppler FFT (Dim 2)...")
doppler_fft = np.fft.fft(range_fft, axis=1)

print("Computing Angle FFT (Dim 3)...")
angle_fft = np.fft.fft(doppler_fft, axis=2)

np.save('golden_cube.npy', angle_fft)
print("SUCCESS: golden_cube.npy saved for RTL cross-verification.")
