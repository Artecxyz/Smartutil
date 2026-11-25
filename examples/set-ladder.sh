#!/system/bin/sh
# smartutil ladder config example.
# Run by hand or install as /data/adb/service.d/99-smartutil-ladder.sh (root, 0755).

GOV=smartutil
BASE=/sys/devices/system/cpu/cpufreq/policy0/$GOV

# smartutil tunables are global; writing through policy0 applies to every cluster.
# Rungs above a cluster's fmax are clamped, so one list is safe for all clusters.

i=0
while [ ! -d "$BASE" ]; do
	i=$((i + 1))
	[ "$i" -gt 50 ] && exit 1
	sleep 0.2
done

for c in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
	echo "$GOV" > "$c"
done

# ---------------------------------------------------------------------------
# Rungs in kHz. Pick real OPPs for your device:
#   cat /sys/devices/system/cpu/cpufreq/policy0/scaling_available_frequencies
# ---------------------------------------------------------------------------
EFFICIENT="787200 1305600 1804800 2208000"

# Dwell per rung in ms. Last value repeats if the list is shorter.
DELAY="50 90 140 200"

echo "$EFFICIENT" > "$BASE/efficient_freq"
echo "$DELAY"     > "$BASE/up_delay"

# ---------------------------------------------------------------------------
# Optional: power ceiling per tier (% of top-state power, 100 = no cap).
# ---------------------------------------------------------------------------
# echo 45 > "$BASE/cap_light_power"
# echo 25 > "$BASE/cap_mid_power"
# echo 20 > "$BASE/cap_heavy_power"

# Optional: latency weight (0 to 100000), lower = more efficient.
# echo 216 > "$BASE/latency_weight"

echo "efficient_freq: $(cat "$BASE/efficient_freq")"
echo "up_delay:       $(cat "$BASE/up_delay")"
