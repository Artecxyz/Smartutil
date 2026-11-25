# Smartutil CPUFreq Governor

Smartutil is a `schedutil` derivative for Linux 6.6. It adds three things to schedutil: a demand estimate that does not depend on PELT catching up, a speed floor derived from that estimate, and an optional frequency ladder. It is a cpufreq policy governor and works with any driver that uses governors.

## Demand measurement

Each CPU samples itself at an interval of at least `max(min_rate_limit_ns, 1 tick)`. For each interval it computes

```
D = busy * freq_scale * capacity
```

from `kcpustat` idle time, in PELT's frequency-invariant units. If the interval contains idle time, `D` is the actual demand. If it contains none, the CPU was busy for the whole interval and `D` is only a lower bound; that interval is treated as censored.

Two values are kept per CPU:

- `H`: the envelope of `D`. It follows a rise immediately and decays with `decay_load()`, the same way PELT does.
- `p`: the estimated probability that the CPU is behind its work. `p` is a leaky integrator: on an interval with no idle it moves 1/16 of the remaining distance to 1, and on an interval with idle it drops by 1/16.

A single idle-free interval means little, since a tick without idle is normal on a CPU that keeps up. A run of them means the CPU is behind, which is why `p` integrates instead of counting consecutive intervals.

## Speed floor

With power `P(s)` at frequency `s`, running one unit of work takes `1/s` time and `P(s)/s` energy. If the CPU is behind with probability `p`, waiting costs `p*lambda` per unit of work, so the total cost is

```
(P(s) + p*lambda) / s
```

The frequency that minimizes this is written `s*(p*lambda)`. `s*(0)` is the most efficient frequency; `s*(lambda)` is used when the CPU is definitely behind. The floor is tabulated over `p` at 65 points, so the update path only performs a lookup.

`lambda` comes from `latency_weight`, expressed in per mille of `lambda_max`.

## Frequency ladder

`efficient_freq` defines rungs in kHz between `policy->min` and `fmax`, and `up_delay` gives each rung a dwell time in milliseconds:

```
min -- rung[0] -- rung[1] -- rung[2] -- fmax
          |          |          |
        50 ms      80 ms      120 ms
```

- A request above the active rung is held at that rung.
- Once the request has lasted for the rung's dwell, the next rung opens and must then wait out its own dwell. A burst therefore climbs one rung at a time.
- A request at or below the active rung releases the hold immediately and moves the ladder to the nearest rung at or above the request. The ladder only caps a request; it never raises one.
- Above the top rung the whole range opens as soon as the top dwell has passed.

The ladder runs after the mapping, the tier headroom and ceilings, and the floor, so it is the last step applied. It is disabled while `efficient_freq` is empty.

The ladder does not read utilization. It only trims a frequency that the governor has already computed, so it is independent of how demand is measured. Ladder state is per policy, and rungs are resolved against each policy's OPP range, so one shared list works for clusters with different `fmax`. Rungs are clamped to the policy range, duplicates are dropped, and the sysfs lists are validated and locked. On drivers that provide `cpufreq_driver_adjust_perf()`, an active ladder forces the frequency path so the ladder is not skipped.

## Request path

```
util = max(PELT, H)                 capped by uclamp_max
freq = ref_freq * util / max        proportional, no fixed headroom
freq = freq * (1 + tier)            tier headroom, interpolated
freq = min(freq, tier_cap)          percent of top-state power
freq = max(freq, floor)             s*(p*lambda)
freq = ladder(freq)                 optional
```

The base mapping is proportional, so light load drives the frequency towards `policy->min`. The three load tiers add headroom or trim and set a ceiling. Both are interpolated between `target_load1` and `target_load2`, so the result does not jump at a tier boundary.

The floor is also applied when a vendor hook supplies the base frequency, and again after `cpufreq_driver_resolve_freq()`, so OPP rounding cannot remove it. Only the ladder may cap below the floor.

## Tunables

All tunables are under `/sys/devices/system/cpu/cpufreq/policy*/smartutil/`. Most are ratios, so the same values work on different devices.

| Tunable | Default | Description |
|---|---|---|
| `up_rate_limit_us` | 1000 | Minimum interval between increases, in µs. A policy limits change bypasses the limit, and a rejected update is retried when the limit expires. Sampling intervals are at least `max(min_rate_limit_ns, 1 tick)`. |
| `down_rate_limit_us` | 2000 | Minimum interval between decreases, in µs. A policy limits change bypasses it as well. |
| `target_load1` | 40 | Start of the medium tier, in percent of capacity. |
| `target_load2` | 80 | Start of the heavy tier, in percent of capacity. |
| `boost_light_pct` | 10 | Headroom at light load, in percent. Falls linearly to zero at `target_load1`. |
| `cut_heavy_pct` | 10 | Trim at heavy load, in percent. Reaches its full value at `target_load2`. |
| `cap_light_power` | 45 | Ceiling at light load, in percent of the top state's power. |
| `cap_mid_power` | 25 | Ceiling at medium load, in percent of the top state's power. |
| `cap_heavy_power` | 20 | Ceiling at heavy load, in percent of the top state's power. The strongest of the three heat controls. |
| `latency_weight` | 216 | Latency weight `lambda`, in per mille of `lambda_max`, from 0 to 100000. The floor at `p = 1` is `(latency_weight/1000)^(1/3) * fmax`, so 216 gives 60% of `fmax`. 0 leaves only `s*(0)`. |
| `efficient_freq` | empty | Ladder rungs in kHz, ascending, up to 16 entries. Zero entries are ignored and an empty list disables the ladder. Device-specific. |
| `up_delay` | empty | Dwell per rung in ms, up to 60000. If the list is shorter than `efficient_freq`, the last value repeats. Device-specific. |

The frequency that each `cap_*_power` selects is read from the Energy Model, so the same percentage means the same relative power on any device. Without an Energy Model, the cube law is used: `cbrt(power/100) * fmax`.

A `cap_*_power` value that resolves at or below `policy->min` is treated as no ceiling, so 0 disables that cap.

Tunables are global. One ladder list is shared by all policies and resolved per policy, which makes it usable for little and big clusters at once. Set `CONFIG_CPU_FREQ_GOV_PER_POLICY=y` for a separate list per cluster.

All twelve tunables are connected to the frequency path. On drivers that provide `cpufreq_driver_adjust_perf()`, the performance-level path does not use the tier mapping (`target_load*`, `boost_light_pct`, `cut_heavy_pct`), the power ceilings, or the direction-specific rate limits. `latency_weight` still applies through the floor, and an active ladder forces the frequency path. In mainline 6.6 only `intel_pstate` and `amd-pstate` provide `adjust_perf`, so arm64 drivers use the frequency path.

A vendor hook that fills `next_freq` in `android_vh_map_util_freq` replaces the built-in mapping, so the tier knobs no longer shape the request. The floor is still applied and the ladder still caps.

## Ladder setup

Pick rungs from the device's OPP table (`scaling_available_frequencies`) and keep them ascending. Example for a device with a 2.8 GHz big core:

```sh
echo "787200 1305600 1804800 2208000" > /sys/devices/system/cpu/cpufreq/policy0/smartutil/efficient_freq
echo "50 90 140 200"                  > /sys/devices/system/cpu/cpufreq/policy0/smartutil/up_delay
```

With these values a short burst stays at 787 MHz. Load that lasts longer than 50 ms may reach 1305 MHz; longer than 90 ms, 1804 MHz; and so on. Writing an empty list disables the ladder.

How the ladder combines with the other tunables:

| Tunable | Interaction |
|---|---|
| `cap_*_power` | Hard power ceiling. The ladder cannot exceed it. |
| `latency_weight` | Sets the floor height. The ladder trims the floor while a dwell has not elapsed. |
| `up_rate_limit_us` | Applied first, with a much shorter interval than any dwell. |
| `down_rate_limit_us` | The ladder drops immediately, but the driver update still obeys this limit. |

If the frequency stays high for too long under sustained load, lower the top rung's `up_delay` or remove the top rung. If power use is still high, add a lower rung or raise the middle dwells. If scrolling and UI feel laggy, lower the first rung's dwell, for example to 30-40 ms.

## Supported kernels

| Patch | Base |
|---|---|
| `patches/0001-linux6.6.144-smartutil-v0.3.0.patch` | Linux 6.6.144 (LTS) |

## Installation

### 1. Apply the patch

```sh
cd /path/to/linux
patch -p1 < /path/to/smartutil/patches/0001-linux6.6.144-smartutil-v0.3.0.patch
```

Smartutil calls `cpufreq_cpu_dl_bw()` and `cpufreq_rq_is_capped()`, declared in `include/linux/sched/cpufreq.h`. The governor builds with `CONFIG_CPU_FREQ` alone.

### 2. Enable the governor

```
CONFIG_CPU_FREQ_GOV_SMARTUTIL=y
```

`CONFIG_ENERGY_MODEL` is used when present. Smartutil works without it.

### 3. Activate

```sh
cat /sys/devices/system/cpu/cpufreq/policy*/scaling_available_governors
echo smartutil > /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
```

If `smartutil` appears in that list, the installation is correct.

### 4. Enable the ladder (optional)

```sh
echo "787200 1305600 1804800 2208000" > /sys/devices/system/cpu/cpufreq/policy0/smartutil/efficient_freq
echo "50 90 140 200"                  > /sys/devices/system/cpu/cpufreq/policy0/smartutil/up_delay
```

See `examples/set-ladder.sh` for a boot-time script with device-specific rungs.

## Dependencies

- A Linux kernel with `CPU_FREQ` and `SMP` enabled
- A cpufreq driver that uses governors, such as `scmi-cpufreq`, `cpufreq-dt`, `acpi-cpufreq` or `cppc_cpufreq`
- `CONFIG_ENERGY_MODEL` is used when present; without it the cube law is used
- A standard kernel toolchain (gcc or clang)

