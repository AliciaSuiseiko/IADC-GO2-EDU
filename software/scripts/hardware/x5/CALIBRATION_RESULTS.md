# X5 and Mid-360 Temporal Calibration

## Active configuration

- SysNav image timestamp compensation: `0.218 s`
- Timestamp convention: `corrected_stamp = raw_image_stamp - 0.218 s`
- Raw calibration mode (`latency-session`) keeps compensation at `0.0 s`.
- Verification mode (`latency-verify`) applies the active compensation.

## Recorded runs

| Directory | Applied compensation | Result |
| --- | ---: | --- |
| `round1_20260820_204954` | `0.000 s` | Global best lag `+0.236 s`; window mean `+0.218 s` |
| `round2_20260820_205916` | `0.000 s` | Global best lag `+0.236 s`; window mean `+0.230 s` |
| `verify_235ms_20260820_214027` | `0.235 s` | Residual `-0.025 s`; zero-lag correlation `0.9628` |

The active `0.218 s` value is within the stable range measured across the raw
runs and avoids over-correcting by the full residual observed in the online
verification run.

## Data layout

- `data/imu_latency.txt` and `data/image_latency.txt` are scratch files. Each
  new recording overwrites them.
- `data/runs/round*` contains retained raw calibration sessions.
- `data/runs/verify*` contains retained compensated verification sessions.
- `data/runs/smoke_20260820` contains short bring-up samples only; do not use
  those files to estimate the final delay.
