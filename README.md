# Smartutil CPUFreq Governor

A `schedutil` derivative that measures the demand above a saturated CPU's capacity instead of waiting for PELT to report it.

## How It Works

### Measured demand

Each CPU closes intervals on itself, of at least `max(min_rate_limit_ns, 1 tick)`, and measures over each one
```
D = busy * freq_scale * capacity        (PELT's frequency-invariant units)
```
from `kcpustat` idle time. An interval with any idle in it shows the demand exactly. One with no idle is *censored*: the CPU is falling behind, and its demand is only known to be at least `D`.

### State per CPU

- **H**, the envelope of `D`: it follows a rise at once and decays exactly like PELT (`decay_load()`).
- **censored_run**, how many recent intervals closed with no idle: up one per idle-free interval, down one per interval with idle in it.
`censored_run` is what says how far behind the CPU is. One idle-free interval means little — a tick without idle is ordinary on a CPU that is keeping up. A run of them means the CPU really is behind.

### The request

```
util = max(PELT, H), capped by uclamp_max
freq = ref_freq * util / max                     purely proportional, no fixed headroom
freq = freq + per-tier headroom                  interpolated over the load range
freq = min(freq, per-tier ceiling)               percent of power, not of fmax
freq = max(freq, floor s*(p*lambda))             s*(l) = argmin_s (P(s) + l)/s
```
The base mapping is strictly proportional, so a lightly loaded CPU is driven towards `policy->min`. Three load tiers then add headroom or trim and set a ceiling; both are spread across the load range and joined at their endpoints, so nothing steps at a tier boundary.
Behind with probability `p`, a unit of work costs `(P(s) + p*lambda)/s` in energy plus latency, and `s*(p*lambda)` is the speed that minimizes it. `s*(0)` is the most efficient speed; work that is behind runs at `s*(lambda)`. The floor is tabulated over `p` (65 points), so a frequency update only looks it up.

### Power model

| Source | s*(0) | s*(lambda) |
|---|---|---|
| Energy Model | cheapest state per unit of work | exact, from the state table |
| none | 0 (as `schedutil`) | cube-law model |
The floors are rebuilt only at start, on a limits change, on a `latency_weight` write and when the Energy Model's table is replaced; nothing is added to the update path but a table lookup.

### What stays with PELT

PELT is read, never simulated. Wake-up prediction (`util_est`), task migration, uclamp, RT, DL and I/O wait boost all work exactly as in `schedutil`.

## Tunables

Under `/sys/devices/system/cpu/cpufreq/policy*/smartutil/`. All of them device-independent — ratios and fractions, not absolute per-device numbers.
| Tunable | Default | Description |
|---|---|---|
| `up_rate_limit_us` | 1000 | Minimum interval between frequency increases (µs). Measurement intervals are at least `max(min_rate_limit_ns, 1 tick)`. |
| `down_rate_limit_us` | 2000 | Minimum interval between frequency decreases (µs). |
| `target_load1` | 40 | Lower bound of the medium tier (% of capacity). |
| `target_load2` | 80 | Lower bound of the heavy tier (% of capacity). |
| `boost_light_pct` | 10 | Headroom at light load (%). Decays continuously from idle to `target_load1`. |
| `cut_heavy_pct` | 10 | Trim at heavy load (%). |
| `cap_light_power` | 45 | Ceiling at light load (% of the top state's power). |
| `cap_mid_power` | 25 | Ceiling at medium load (% of the top state's power). |
| `cap_heavy_power` | 20 | Ceiling at heavy load (% of the top state's power). |
| `latency_weight` | 216 | The latency weight `lambda`, per mille of `lambda_max`. The floor's ceiling at `p = 1` is `(latency_weight/1000)^(1/3) * fmax`, so the default 216 holds it at 60% of `fmax` on any device. Lower it to trade latency for energy; `0` keeps only the efficiency floor `s*(0)`. Up to 100000. |
The frequency each `cap_*_power` buys is read off the **Energy Model**, so the same number means the same headroom on any device: a core whose power climbs steeply runs out of budget well below `fmax`, one that scales gently does not. Without an Energy Model the cube law is used (`cbrt(power/100) * fmax`). `cap_heavy_power` is the strongest single heat-control knob — the only one that really holds a busy CPU below `fmax`.

## Response shape

How sharply the requested frequency moves as load moves. Simulated on a 3 GHz cluster with cube-law ceilings — not measured on a device.
| | |
|---|---|
| Jump across `load = 40` | 0.0 MHz |
| Jump across `load = 80` | 0.0 MHz |
| Worst change per 1 load point | 32.9 MHz |
| Floor step per interval | 14.7 MHz |

## Supported Kernels

| Patch | Base |
|---|---|
| `patches/0001-linux6.6.144-smartutil-v0.2.0.patch` | Linux 6.6.144 (LTS) |

## Installation

### 1. Apply the patch

```sh
cd /path/to/linux
patch -p1 < /path/to/smartutil/patches/0001-linux6.6.144-smartutil-v0.2.0.patch
```

The patch also touches the scheduler and the cpufreq core, to move `cpufreq_cpu_dl_bw()` into `kernel/sched/cpufreq.c` so it compiles with `CONFIG_CPU_FREQ` alone.

### 2. Enable in kernel config

```
CONFIG_CPU_FREQ_GOV_SMARTUTIL=y
```

`CONFIG_ENERGY_MODEL` are used when present; Smartutil works without them.

### 3. Activate

```sh
cat /sys/devices/system/cpu/cpufreq/policy*/scaling_available_governors
echo smartutil > /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
```

If `smartutil` shows up in that list, the patch and the config are right.

## Dependencies

- A Linux kernel with `CPU_FREQ` and `SMP` enabled
- A cpufreq driver that uses governors: `scmi-cpufreq`, `cpufreq-dt`, `acpi-cpufreq`, `cppc_cpufreq`, and so on
- `CONFIG_ENERGY_MODEL` is used when present; without it the cube law is used
- A standard kernel build toolchain (gcc or clang); arm64 is build-tested