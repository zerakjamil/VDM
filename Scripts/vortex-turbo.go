package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"net"
	"net/http"
	"os/exec"
	"strings"
	"time"
)

const vortexURL = "http://127.0.0.1:17890"

type TaskInfo struct {
	ID       string  `json:"id"`
	Filename string  `json:"filename"`
	Status   string  `json:"status"`
	Speed    float64 `json:"speed"`
}

func getWifiInterface() string {
	cmd := exec.Command("networksetup", "-listallhardwareports")
	out, err := cmd.Output()
	if err != nil {
		return "en0"
	}
	lines := strings.Split(string(out), "\n")
	foundWifi := false
	for _, line := range lines {
		if strings.Contains(line, "Hardware Port: Wi-Fi") || strings.Contains(line, "Hardware Port: AirPort") {
			foundWifi = true
		} else if foundWifi && strings.HasPrefix(line, "Device:") {
			parts := strings.Split(line, ":")
			if len(parts) >= 2 {
				return strings.TrimSpace(parts[1])
			}
		} else if foundWifi && strings.HasPrefix(line, "Hardware Port:") {
			foundWifi = false
		}
	}
	return "en0"
}

func checkInternet() bool {
	conn, err := net.DialTimeout("tcp", "8.8.8.8:53", 2*time.Second)
	if err != nil {
		return false
	}
	conn.Close()
	return true
}

func postVortex(endpoint string) error {
	client := &http.Client{Timeout: 3 * time.Second}
	resp, err := client.Post(vortexURL+endpoint, "application/json", bytes.NewBuffer([]byte("{}")))
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	return nil
}

func getTasks() ([]TaskInfo, error) {
	client := &http.Client{Timeout: 2 * time.Second}
	resp, err := client.Get(vortexURL + "/downloads")
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	var tasks []TaskInfo
	err = json.NewDecoder(resp.Body).Decode(&tasks)
	return tasks, err
}

func bounceWifi(dev string) bool {
	fmt.Printf("\n[⚡ TURBO] Bouncing Wi-Fi on %s to renew router NAT session...\n", dev)
	_ = exec.Command("networksetup", "-setairportpower", dev, "off").Run()
	time.Sleep(1500 * time.Millisecond)
	_ = exec.Command("networksetup", "-setairportpower", dev, "on").Run()
	fmt.Print("[⚡ TURBO] Waiting for connection restoration...")
	for i := 0; i < 20; i++ {
		time.Sleep(1 * time.Second)
		if checkInternet() {
			fmt.Printf(" connected in %ds!\n", i+1)
			return true
		}
	}
	fmt.Println(" timed out.")
	return false
}

func main() {
	ifaceFlag := flag.String("interface", "", "Wi-Fi interface device (e.g. en0)")
	threshFlag := flag.Float64("threshold-mb", 3.8, "Speed threshold in MB/s")
	peakFlag := flag.Float64("peak-mb", 7.0, "Minimum peak speed in MB/s")
	throttleTime := flag.Int("throttle-time", 14, "Seconds throttled before trigger")
	recycleOnly := flag.Bool("recycle-only", false, "Only recycle sockets, do not bounce Wi-Fi")
	flag.Parse()

	iface := *ifaceFlag
	if iface == "" {
		iface = getWifiInterface()
	}

	threshBytes := *threshFlag * 1024 * 1024
	peakBytes := *peakFlag * 1024 * 1024

	fmt.Println("=================================================================")
	fmt.Println(" 🚀 VORTEX HIGH-SPEED AUTO-TURBO WATCHDOG (NATIVE)")
	fmt.Println("=================================================================")
	fmt.Printf(" • Interface       : %s\n", iface)
	fmt.Printf(" • Peak Trigger    : %.1f MB/s\n", *peakFlag)
	fmt.Printf(" • Throttle Floor  : %.1f MB/s\n", *threshFlag)
	fmt.Printf(" • Mode            : %s\n", map[bool]string{true: "TCP Recycle Only", false: "Hybrid (Recycle + Wi-Fi Bounce)"}[*recycleOnly])
	fmt.Println("=================================================================")

	var peakSpeed float64
	var throttledSince time.Time
	var lastBounce time.Time

	for {
		tasks, err := getTasks()
		if err != nil {
			fmt.Printf("\r[Vortex Offline] Waiting for Vortex to start...           ")
			time.Sleep(3 * time.Second)
			continue
		}

		var active []TaskInfo
		var currentSpeed float64
		for _, t := range tasks {
			if t.Status == "downloading" || t.Status == "connecting" {
				active = append(active, t)
				currentSpeed += t.Speed
			}
		}

		if len(active) == 0 {
			peakSpeed = 0
			throttledSince = time.Time{}
			fmt.Printf("\r[Vortex Idle] No active downloads. Waiting...             ")
			time.Sleep(2 * time.Second)
			continue
		}

		if currentSpeed > peakSpeed {
			peakSpeed = currentSpeed
		}

		currentMB := currentSpeed / (1024 * 1024)
		peakMB := peakSpeed / (1024 * 1024)
		name := active[0].Filename
		if len(name) > 20 {
			name = name[:17] + "..."
		}

		if peakSpeed >= peakBytes && currentSpeed < threshBytes {
			if throttledSince.IsZero() {
				throttledSince = time.Now()
			}
			dur := int(time.Since(throttledSince).Seconds())
			fmt.Printf("\r[%s] Speed: %5.1f MB/s | Peak: %5.1f MB/s | THROTTLED (%ds/%ds)", name, currentMB, peakMB, dur, *throttleTime)

			if dur >= *throttleTime {
				fmt.Printf("\n[!] Throttle threshold reached! Speed collapsed to %.1f MB/s.\n", currentMB)
				fmt.Println("  ➜ Step 1: Recycling TCP connections with fresh sockets...")
				_ = postVortex("/recycle")
				time.Sleep(5 * time.Second)

				// Verify recovery
				chkTasks, _ := getTasks()
				var chkSpeed float64
				for _, t := range chkTasks {
					if t.Status == "downloading" {
						chkSpeed += t.Speed
					}
				}
				if chkSpeed >= threshBytes*1.5 {
					fmt.Printf("  ✅ [RESTORED] Speed jumped back to %.1f MB/s!\n", chkSpeed/(1024*1024))
					throttledSince = time.Time{}
					peakSpeed = chkSpeed
					continue
				}

				if !*recycleOnly && time.Since(lastBounce) > 45*time.Second {
					fmt.Println("  ➜ Step 2: Session locked at router NAT/DHCP level. Bouncing Wi-Fi...")
					_ = postVortex("/pause")
					time.Sleep(500 * time.Millisecond)
					bounceWifi(iface)
					lastBounce = time.Now()
					fmt.Println("  ➜ Resuming Vortex downloads...")
					_ = postVortex("/resume")
					throttledSince = time.Time{}
					peakSpeed = 0
					time.Sleep(3 * time.Second)
				} else {
					throttledSince = time.Time{}
				}
			}
		} else {
			throttledSince = time.Time{}
			fmt.Printf("\r[%s] Speed: %5.1f MB/s | Peak: %5.1f MB/s | OK                 ", name, currentMB, peakMB)
		}

		time.Sleep(2 * time.Second)
	}
}
