---
name: Hardware report (add support for your Mac)
about: Sensors, fans or CPU clusters wrong on your machine? Send a diagnostics dump.
title: "Hardware report: <your Mac model>"
labels: hardware-report
---

Heimdall is developed on a single machine (an M3 Pro), so the surest way to make
it correct on yours is a diagnostics dump. Everything below is read-only.

## Your Mac

- Model (Apple menu > About This Mac):
- macOS version:
- Chip:

## What looks wrong

<!-- e.g. "P/E core counts are swapped", "no fans detected", "GPU temp missing" -->

## Diagnostics

Run this and paste the output. It reads CPU topology, GPU core count and the
SMC key table. It changes nothing and needs no admin password.

```bash
sysctl hw.nperflevels hw.physicalcpu hw.logicalcpu machdep.cpu.brand_string
for i in 0 1 2 3; do
  n=$(sysctl -n hw.perflevel$i.name 2>/dev/null) || continue
  [ -z "$n" ] && continue
  echo "perflevel$i: $n logical=$(sysctl -n hw.perflevel$i.logicalcpu)"
done
ioreg -lw0 -p IODeviceTree | grep -E '"(cluster-type|logical-cpu-id)"' | paste - -
ioreg -lw0 | grep -o '"gpu-core-count" = [0-9]*' | sort -u
```

<details><summary>Output</summary>

```
paste here
```

</details>

## Screenshot

If a panel renders wrongly, a screenshot of it helps a lot.
