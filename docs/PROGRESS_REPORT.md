# Progress Report — Radar FFT Accelerator

Written in plain language. For explaining where the project stands.

---

## 1. What the project is

We are building hardware (on an FPGA) that processes radar signals in real time.

A radar sends out a signal, it bounces off objects, and comes back. To work out **how far
away** something is, **how fast it is moving**, and **which direction** it is in, you have to
run a mathematical operation called an FFT three separate times on the same data — once for
each of those three questions.

My part of the project is the **FFT engine** — the block that actually does that maths.

---

## 2. What is finished

> **Scope note, stated plainly.** What is finished is **one 1-D FFT engine, one lane,
> configured for the distance axis.** The full 3-D system needs about a dozen blocks; this is
> one of them. It is reusable for two of the three axes, but the system is **not** built.
> Roughly 20 % of the hardware code is written and **nothing has run on an FPGA yet.**

### The FFT engine is built, tested and working

I designed it, ran it through the full Xilinx tool flow (synthesis and implementation), and
verified it in simulation. These are real measured numbers, not estimates:

| what | result |
|---|---|
| Speed | 100 million samples per second, one every clock tick |
| Timing margin | 38 % spare — it could run at 138 MHz if needed |
| Chip space used | about **10 %** of the FPGA |
| Tests | 7 test cases, 28 checks, **0 errors** |

It handles two different FFT sizes (1024 and 2048 points) and can **switch between them while
running**, which is what the radar needs.

### Six real bugs found and fixed

While building it I found and fixed six genuine problems. Three worth mentioning:

- The original design said to compute **signal strength** at this stage. That destroys the
  direction information, which the next two stages need. Fixed by keeping the full data — and
  it costs nothing, the data is the same size either way.
- The control block could set the FFT size **once** after power-on and never change it again,
  so switching sizes was impossible. Rewritten.
- One connection was left unconnected, which made the FFT jam on the **second** frame. It
  looked like a speed problem but wasn't.

---

## 3. The problem I found

This is the main issue, and it is not about the FFT at all.

Between the first FFT (distance) and the second FFT (speed), **all the data has to be stored
somewhere temporarily.** This is unavoidable, because of the order the data comes out in:

- The first FFT works through **one chirp at a time**
- The second FFT needs **one distance across all 256 chirps**

So nothing can start until everything is finished and stored.

**How much data:**

```
1024 distances x 256 chirps x 4 antennas = 1,048,576 measurements
each measurement = 4 bytes
                                         = 4.2 MB
```

**How much fast memory the chip has: 0.6 MB.**

**We are 7 times over.** This is a physical limit of the chip — it cannot be increased.

### I checked whether a different board fixes it

I have three boards. I checked all of them:

| board | chip | fast memory | fixes it? |
|---|---|---|---|
| Zybo Z7-20 | XC7Z020 | 0.6 MB | no |
| PYNQ-Z2 | **XC7Z020 — same chip** | 0.6 MB | **no** |
| KC705 | XC7K325T | 2.0 MB | still short, but see below |

The PYNQ-Z2 and Zybo use the **identical FPGA chip**, so switching between them changes
nothing. The KC705 has more memory but still not enough for 4.2 MB.

**Conclusion: the data has to go out to the large DDR memory chip on the board and come
back.** That memory is big enough (512 MB to 1 GB) — the question becomes **how fast we can
move data in and out.**

---

## 4. What I did about it — I measured the real speed

The datasheet for the PYNQ-Z2 says its memory can do **2100 MB/s**. That number is not
usable for design work, because it ignores real overheads.

So I built a small test design — just the processor and one data-mover, looping back on
itself — and **measured** it:

| transfer size | measured speed |
|---|---|
| 128 bytes | 6 MB/s |
| 4 KB | 141 MB/s |
| 64 KB | 728 MB/s |
| 1 MB | 1,477 MB/s |
| 16 MB | **1,539 MB/s** |

```
real streaming speed  = 1,541 MB/s     (datasheet said 2,100)
fixed cost per move   = 38 microseconds
```

**Two things this tells us.** The real speed is about 73 % of the datasheet figure. And small
transfers are terrible — moving 128 bytes at a time gets 6 MB/s, because the setup cost
dominates. **We must move data in large blocks.**

---

## 5. The important discovery

I worked out how much memory speed the design actually needs, and something surprising
falls out:

```
needed speed = 2 x bytes per sample x number of antennas x sampling rate
             = 2 x 4 B x 4 antennas x 25.6 MSPS
             = 819 MB/s
```

**The FFT size does not appear in this formula.** It cancels out — a bigger FFT means more
data, but it also takes proportionally longer to collect, so the required speed is the same.

**This means we cannot fix the problem by making the FFT smaller.** The only things that
matter are how many antennas we have and how fast they sample. That is a useful result and
it closed off a whole direction we might otherwise have wasted time on.

### Comparing what we need against what we measured

| design | memory traffic needed | PYNQ-Z2 (1,541 MB/s) |
|---|---:|---|
| Straightforward design | 2,052 MB/s | **too slow — fails** |
| My improved design | 819 MB/s | works, 1.9× margin |

So the obvious way of building it **does not work** on the Zynq boards. My improved version
does, but only just.

---

## 6. How I improved it — two changes

**Change 1: process all 4 antennas at the same time.**
The third FFT (direction) is tiny — only 4 points — and needs **no multipliers at all**, just
8 additions. If I run four copies of the second FFT side by side, one per antenna, then all
four antenna values arrive together and feed straight into the third FFT. **This deletes an
entire storage stage.** It saves 40 % of the memory traffic and costs no speed.

**Change 2: find the targets before saving.**
The final answer is a short list of detected objects, not the whole data block. If I do the
detection on the chip first, I only save the list. That saves another 30 %.

Together: **2,052 MB/s → 819 MB/s.**

---

## 7. Where I am going — the KC705 board

The KC705 uses a bigger FPGA (Kintex-7) with a much wider connection to its memory:

| | Zynq boards | KC705 |
|---|---|---|
| Memory connection | 16 or 32 bits wide | **64 bits wide** |
| Memory speed | 1050 Mbps | 1600 Mbps |
| Estimated real speed | 1,541 MB/s (measured) | **~6,000+ MB/s** |
| Chip space (DSP) | 220 | **840** |
| Chip space (memory) | 0.6 MB | **2.0 MB** |

**On the KC705, 819 MB/s is about 14 % of what the memory can do.** The problem that was
nearly stopping the project stops being a problem.

### The cost of moving

The KC705 has **no ARM processor**. The Zynq boards have a small computer built into the
chip that handles memory and control for us. On the KC705 we have to build that ourselves.

That means rebuilding:
- The memory controller (using Xilinx's MIG tool instead of the built-in one)
- The control and readout software path

**My FFT engine itself moves across unchanged** — it is ordinary hardware code plus a
standard Xilinx block. The faster chip should also make it run better.

---

## 8. What I am doing next

1. **Repeat the memory measurement on the KC705.** Same test, new board. I need the real
   number, not an estimate — that is what the last measurement taught me.
2. **Rebuild the FFT engine for the Kintex chip** and check it still meets timing.
3. **Build the storage block** (the "corner turn") that holds the data between the two FFT
   stages. This is the hardest remaining piece.
4. **Add the extra FFT copies** — 2 for distance, 4 for speed. These are copies of the block
   I already built and verified.
5. **Add the direction FFT and the detection stage.**
6. **Test the whole thing** against a known correct answer computed in Python.

---

## 9. Problems I still have

**The storage block needs rewriting.** My teammate built one, but it only handles a square
64×64 block of data and ours is 1024×256. It also cannot be paused — if the FFT gets busy,
data is silently lost. That has to be fixed regardless of everything else.

**Three pieces have no owner yet:**

- **The window function.** Without it, a strong nearby object drowns out weaker ones and the
  radar results are not trustworthy. It is small and cheap to add, but nobody is building it.
- **The detection stage (CFAR).** This is now part of how we save memory traffic, so it
  matters more than it did.
- **Scale tracking between stages.** Each FFT reports a scaling number, and they have to be
  added up correctly across the three stages. If this is wrong, the answers look reasonable
  but are wrong by a large factor — which is the hardest kind of mistake to notice.

**One thing I need confirmed:** the radar's actual timing (how long each chirp lasts). Every
speed calculation depends on it, and I have been assuming 40 microseconds.

---

## 10. Honest completion status

| block | built? | verified? |
|---|---|---|
| Range FFT engine — 1 lane | **yes** | **yes, in simulation** |
| Range FFT — 2nd lane | no | no |
| Doppler FFT ×4 (N=256) | no | no |
| Angle FFT (4-point) | no | no |
| Corner turn / cube buffer | no | no |
| Address generator | no | no |
| DDR interface (MIG) | no | no |
| Magnitude | no | no |
| CFAR detection | no | no |
| Exponent accumulator | no | no |
| Window function | no | no |
| Sequencer / control | no | no |
| 3-D integration | no | no |
| **Running on an FPGA** | **no** | **no** |

**About 20 % of the hardware code is written. Nothing has run on a board yet.**

The engine that is finished is reusable for two of the three axes, so the percentage
understates the value — but the 3-D system is not built and should not be described as built.

## 11. Summary

**Done:** One 1-D FFT engine built, tested, verified — 10 % of the chip, 38 % timing margin.
Six bugs found and fixed. Memory bottleneck identified and **measured**, not guessed.

**Found:** The FFT is not the hard part — moving data in and out of memory is. And the amount
of memory speed required does not depend on the FFT size, so it cannot be reduced by making
the transform smaller.

**Solved:** Two design changes cut the memory traffic by 60 %, from 2,052 MB/s down to
819 MB/s, which fits.

**Next:** Move to the KC705 board, where that 819 MB/s is only 14 % of capacity, and build the
remaining blocks.
