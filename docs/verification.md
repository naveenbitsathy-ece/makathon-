# Verification and Results

## Reported integrated simulation tests
The following results were reported by the project workflow and should be checked against the latest XSim transcript before publication.

| Test | Operation | Inputs | Expected result |
|---|---|---|---|
| 1 | Sequence matching | `ACGTACGT` vs `ACGTACGT` | FOUND |
| 2 | Sequence matching | `ACGTACGT` vs `ACGTTCGT` | NOT FOUND |
| 3 | Sequence matching | `ACGT` vs `ACGTACGT` | NOT FOUND (length mismatch) |
| 4 | Motif detection | Target `ACGTACGT`, motif `ACGT` | Count 2, positions 0 and 4 |
| 5 | Motif detection | Target `AAAAAAAAAA`, motif `AAA` | Count 8, positions 0 through 7 |
| 6 | Motif detection | Target `GGGGACGT`, motif `ACGT` | Count 1, position 4 |

## Evidence to add before submission
- [ ] Latest integrated XSim transcript showing pass/fail for each test.
- [ ] Waveform screenshots showing completed transactions, not only initial boot.
- [ ] PuTTY screenshot from the actual board demonstration.
- [ ] Vivado implementation timing summary.
- [ ] Vivado utilization report (LUTs, flip-flops, BRAM, DSPs).
- [ ] Board photograph and pin/clock constraints, if permitted.

## Important distinction
Simulation, implementation reports, and physical-board tests are different evidence. Do not claim physical hardware passed a test solely because a simulation passed. Do not claim a speedup unless software-only and accelerated implementations have been measured under comparable conditions.
