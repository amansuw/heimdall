<div align="center">

# Heimdall
## High-Performance macOS System Monitor

</div>

A native macOS system monitoring utility built for extreme efficiency. Monitors CPU, GPU, RAM, Disk, Network, Battery, and all SMC sensors with fan control — all under **100MB RAM** and **5% CPU**.

## Architecture & Optimization

| Technique | Why |
|-----------|-----|
| `@Observable` macro | Per-property tracking eliminates cascade view redraws |
| `Canvas` (Core Graphics) | ~10x cheaper than Apple `Charts` for live graphs |
| `CAShapeLayer` / `CATextLayer` menu bar | GPU-composited, zero SwiftUI overhead |
| Ring buffers | Fixed-size, zero allocations after init |
| Visibility-aware polling | Slower rate when window/popover hidden |
| Sleep/wake pausing | Zero CPU when display is off |
| Solid backgrounds | No `.ultraThinMaterial` compositing overhead |
| Tiered polling | Fast (2s), Medium (10s), Slow (60s) tiers |

## Features

Explore each module below for a closer look at Heimdall's monitoring and control surfaces.

### Dashboard
System overview with CPU/GPU temperature cards, selectable temperature history, fan status, and quick fan presets.
![Dashboard](images/dashboard.png)

### CPU
P/E-core usage gauges, per-core bars, usage history with selectable time range (default 5 minutes), load averages, clock frequencies, and top CPU processes ranked over the selected window with one-click quit.
![CPU](images/cpu.png)

### GPU
GPU utilization gauge, render/tiler split, usage history, device stats, and top GPU processes over the selected time range.
![GPU](images/gpu.png)

### Memory
Live memory pressure, app/wired/compressed/swap breakdown, trend charts, and top memory processes over the selected time range.
![Memory](images/memory.png)

### Network
Download/upload gauges, selectable traffic history, interface details, IP addresses, DNS servers, public IP lookup, and top bandwidth processes over the selected window.
![Network](images/network.png)

### Disk
Volume usage gauges, I/O throughput history, and top disk processes over the selected time range.
![Disk](images/disk.png)

### Battery
Charge level, health percentage aligned with Apple Settings, cycle count, capacity in mAh, adapter info, power draw, and charging status.
![Battery](images/battery.png)

### Sensors
Full SMC sensor grid with search, category filters, and live readings for temperature, voltage, current, and power.
![Sensors](images/sensors.png)

### Fan Settings
Fan profiles (Default, Silent, Performance, and custom), control mode picker, per-fan RPM cards, and manual speed control.
![Fan Settings](images/fansettings.png)

### Fan Curve
Interactive temperature-to-fan-speed curve editor with draggable control points for custom cooling profiles.
![Fan Curve](images/fancurve.png)

### Menu Bar Popover
Compact temperature stats, live chart, system gauges, fan RPMs, and quick profile switching (Default, Silent, Performance, plus your latest custom profile).

## Requirements

- macOS 15.0 (Sequoia) or later
- Xcode 16.0+ for building
- Admin privileges needed once to install root helper for SMC reads/writes

## Building

```bash
git clone https://github.com/amansuw/heimdall.git && cd heimdall
xcodebuild -project Heimdall.xcodeproj -scheme Heimdall -configuration Debug build
```

Or open `Heimdall.xcodeproj` in Xcode and press ⌘R.

## Project Structure

```
Heimdall/
├── HeimdallApp.swift              # App entry, AppDelegate, window + menu bar
├── main.swift                     # CLI modes (--smc-daemon, --reset-fans)
├── Core/
│   ├── SMCKit.swift               # Low-level SMC interface via IOKit
│   ├── SensorDefinitions.swift    # Sensor key lookup & validation
│   ├── RingBuffer.swift           # Fixed-size circular buffer
│   └── Formatters.swift           # Byte/speed/temp formatting
├── Readers/                       # Pure data collection (no UI state)
│   ├── CPUReader.swift            # host_processor_info, sysctl
│   ├── GPUReader.swift            # IOKit GPU stats
│   ├── RAMReader.swift            # host_statistics64
│   ├── DiskReader.swift           # statfs, IOKit disk I/O
│   ├── NetworkReader.swift        # getifaddrs, if_data
│   ├── BatteryReader.swift        # IOKit power source
│   ├── SensorReader.swift         # SMC sensor enumeration + reads
│   └── ProcessReader.swift        # proc_listpids, proc_pidinfo
├── State/                         # @Observable classes (per-property tracking)
│   ├── CPUState.swift, GPUState.swift, RAMState.swift
│   ├── DiskState.swift, NetworkState.swift, BatteryState.swift
│   ├── SensorState.swift, FanState.swift
│   └── ProcessHistory.swift       # Time-windowed process metrics
├── Coordinator/
│   ├── MonitorCoordinator.swift   # Tiered polling, visibility-aware
│   └── FanController.swift        # Fan mode, curve eval, profiles
├── Daemon/
│   └── SMCDaemon.swift            # Root LaunchDaemon for SMC access
├── MenuBar/                       # Pure AppKit (no SwiftUI)
│   ├── StatusBarController.swift  # NSStatusItem management
│   └── MenuBarWidgetView.swift    # CALayer-based widget rendering
├── Views/                         # SwiftUI (only for layout)
│   ├── MainWindow/                # Dashboard, CPU, GPU, RAM, etc.
│   ├── Popover/                   # Menu bar popover
│   └── Shared/
│       └── CanvasChart.swift      # Reusable Canvas-based charts
└── Models/
    ├── SystemModels.swift         # Data structs (Sendable)
    ├── FanCurve.swift             # Curve with interpolation
    └── FanProfile.swift           # Profile presets + custom
```

## How It Works

- **SMCKit** communicates directly with Apple's SMC via `IOConnectCallStructMethod`
- **Fan writes require `Ftst` unlock on Apple Silicon**: writes `Ftst=1` to tell `thermalmonitord` to yield
- **All fan reads/writes go through a root LaunchDaemon** — no password after first install
- Fan curves use linear interpolation between user-defined control points
- Fans reset to macOS automatic control on app quit

## License

See [LICENSE](LICENSE) for details.