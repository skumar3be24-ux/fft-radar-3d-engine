# The Memory Problem — Team Brief

## The problem in one line

**Our data doesn't fit on the chip. It's 7× too big.**

```
What one radar frame is:   1024 samples x 256 chirps x 4 antennas
                           = 1,048,576 numbers x 4 bytes each
                           = 4.2 MB

What the FPGA chip holds:  0.6 MB
```

---

## Why changing the board didn't help

Zybo Z7-20 and PYNQ-Z2 use the **same FPGA chip** — XC7Z020.

That memory sits *inside* the chip, not on the board. Same chip = same 0.6 MB.
No board can fix this.

---

## Why we can't just keep a small piece

The range FFT gives us data **one chirp at a time**.
The Doppler FFT needs **one distance across all 256 chirps**.

So Doppler can't start until every chirp is finished. All 4.2 MB has to sit
somewhere in between.

**That waiting area is the corner turn.** It's not optional.

---

## So the data goes to DDR. New problem: speed.

DDR has plenty of space (512 MB / 1 GB). But we have to move the data in and out
five times per frame:

```
write range results        4.2 MB
read for Doppler           4.2 MB
write Doppler results      4.2 MB
read for angle             4.2 MB
write final output         4.2 MB
                           -------
                           21 MB, 98 times per second = 2.05 GB/s
```

**Zybo can realistically do about 2.5 GB/s. PYNQ-Z2 only about 1.2 GB/s.**

So: too tight on Zybo, impossible on PYNQ.

---

## The fix — two changes, 60% less traffic

**1. Do all 4 antennas at the same time.**
The angle FFT is tiny (4 points, no multipliers). If we run 4 Doppler engines side
by side, all 4 antennas come out together and feed the angle FFT directly.
**The second corner turn disappears.**

```
21 MB  ->  12.6 MB per frame
```

**2. Do the target detection (CFAR) on the chip.**
Then we only write out the few targets we found, not the whole cube.

```
12.6 MB  ->  8.4 MB per frame  =  0.82 GB/s
```

**0.82 GB/s out of 2.5 GB/s available. Comfortable.**

---

## What the corner-turn block needs to be

DDR holds the big cube. On-chip memory holds only the small piece being worked on:

```
16 range bins x 256 chirps x 4 antennas, double-buffered = 21% of BRAM  -> fits fine
```

Three things it needs that the current version doesn't have:

1. **Talks to DDR** (AXI master, read + write)
2. **Works for 1024 x 256**, not a fixed 64 x 64 square
3. **Has `ready` signals** — right now it can't be paused, so if the FFT stalls,
   data is lost silently. This is a bug today, even without any of the above.

---

## What we need to decide

1. **Use the Zybo** (2× the DDR speed). Keep PYNQ-Z2 for demos — Python is much
   easier than bare-metal C.
2. **Do we do all 4 antennas in parallel?** This removes a whole corner turn.
3. **Who builds CFAR?** Putting it on-chip is what makes the speed work.
4. Small note: input rate is 102.4 MSPS, slightly more than one FFT lane's 100 MSPS.
   The range stage needs 2 lanes.

---

## Bottom line

**The FFT engine is small — about a tenth of the chip.
The memory between the stages is 30× bigger than the engine and doesn't fit at all.**

In this project, memory is the hard part. The maths is the easy part.
