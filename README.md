# Vortex Download Manager (VDM) ⚡

A high-performance, frontier download manager built natively for **macOS (Apple Silicon & Intel)** in Swift & SwiftUI, paired with an IDM-grade **Chrome Extension**.

Designed specifically to solve slow download throttles, multi-part game archives, expired download tokens (e.g. from `romsfun`, cyberlockers, and direct link hosts), and large 30+ GB downloads.

---

## ✨ Features

- **⚡ Multi-Threaded Range Acceleration**: Splits files into 8, 16, 24, or 32 concurrent HTTP Range connections, bypassing single-connection cyberlocker throttles.
- **🔄 Autonomous Zero-Click Token Renewal**: Automatically detects expired links (HTTP 401/403/410), opens a background tab in Chrome, captures new session tokens & cookies, and resumes downloads at the exact byte offset without losing any downloaded data.
- **🚀 24x Stream Boost & Adaptive Stream Balancer**: BBR-inspired stream balancer detects stalled or throttled connections (< 25% avg) and dynamically splits remaining byte ranges to high-throughput workers.
- **💾 Zero-Assembly Direct Disk Storage**: Writes incoming chunks directly into APFS using POSIX `pwrite`. No slow assembly phases or temporary files taking double SSD space.
- **📦 Multi-Part Game Archive Auto-Extractor**: Automatically detects multi-volume RAR/7z/ZIP files (`.part01.rar`, `.r00`, `.7z.001`), verifies SFV/CRC32 checksums, and decompresses games on completion.
- **☁️ Native Debrid Cloud Uncapper**: Integrates with Real-Debrid and AllDebrid to convert 80+ throttled cyberlocker hosts (Rapidgator, 1fichier, Mega, MegaUp, etc.) into high-speed 10 Gbps CDN direct streams.
- **🧲 BitTorrent & Magnet Integration**: Native bencode parsing and magnet URI resolution.
- **🖥️ macOS Menu Bar HUD & Glass Drop Zone**: Menu bar popover with live aggregate speed (`⚡ MB/s`), quick pause/resume controls, and a floating desktop drop zone (`⌘ + Shift + D`).
- **🌙 Sleep Prevention**: Keeps your Mac awake (`IOPMAssertion`) during active downloads so 40 GB games finish uninterrupted overnight.

---

## 🏗️ Architecture

```
VortexDownloadManager/
├── Sources/Vortex/
│   ├── App/
│   │   ├── VortexApp.swift           # Application lifecycle, MenuBarExtra HUD
│   │   ├── AppState.swift            # Download collection, IPC coordinator
│   │   └── QueueManager.swift        # Concurrency & queue scheduler
│   ├── Core/
│   │   ├── DownloadTask.swift        # Task coordinator & stream booster
│   │   ├── SegmentWorker.swift       # HTTP Range chunk streamer
│   │   ├── StreamBalancer.swift      # Adaptive speed & choke balancer
│   │   ├── DebridResolver.swift      # Real-Debrid / AllDebrid unrestrictor
│   │   ├── ArchiveExtractor.swift    # Multi-part archive unpacker & SFV verifier
│   │   ├── FileStorage.swift         # Direct APFS POSIX pwrite engine
│   │   ├── VortexServer.swift        # Local IPC server (http://127.0.0.1:17890)
│   │   └── Torrent/                  # Native Bencode & Magnet engine
│   └── Views/
│       ├── MainWindowView.swift      # Modern sidebar & task visualizer
│       ├── DownloadRowView.swift     # Speed, ETA, and 24x Boost actions
│       ├── SegmentBarView.swift      # Multi-color live chunk bar
│       ├── MenuBarView.swift         # Mini HUD status bar dropdown
│       ├── FloatingDropZoneView.swift# Desktop glass drag-and-drop target
│       ├── BatchImportSheet.swift    # Multi-link bulk importer
│       └── PreferencesView.swift     # Settings & Debrid API keys
├── Tests/VortexTests/                # 11 Unit & integration tests
├── Scripts/
│   └── package_app.sh                # Release build & codesign packager
└── VortexExtension/                  # Manifest V3 Chrome Extension
    ├── manifest.json
    ├── background.js                 # Autonomous token renewal watchdog
    ├── popup.html / popup.js
    └── icons/
```

---

## 🚀 Getting Started

### Prerequisites
- macOS 13.0+ (Ventura, Sonoma, Sequoia)
- Apple Silicon (M1/M2/M3/M4) or Intel Mac
- Xcode 15+ or Swift 5.9+ Command Line Tools
- Google Chrome / Brave / Edge (for browser extension)

### 1. Build & Run Vortex
```bash
# Clone the repository
git clone https://github.com/zerakjamil/VDM.git
cd VDM

# Run unit tests
swift test

# Build and package Vortex.app
./Scripts/package_app.sh

# Launch the app
open Vortex.app
```

### 2. Install Chrome Extension
1. Open Google Chrome and navigate to `chrome://extensions`.
2. Enable **Developer mode** in the top right corner.
3. Click **Load unpacked** and select the `VortexExtension` folder inside this repository.
4. Any download initiated in Chrome will now route through Vortex with IDM-speed acceleration and automatic token renewal!

---

## 📜 License
MIT License.
