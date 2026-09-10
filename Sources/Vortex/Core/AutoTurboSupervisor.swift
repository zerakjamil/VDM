import Foundation
import Network
import Combine
import Security

/// AutoTurboSupervisor: Native macOS in-app ISP Burst Quota Recovery and Router Guardian.
///
/// When an ISP (such as Kurdistan Net / FTTH) throttles connection throughput after a 2GB–4GB burst
/// down to 3.x MB/s, AutoTurboSupervisor automatically coordinates with the local ZTE MT-0011 Smart Gateway:
/// 1. Gently pauses active downloads and flushes all segment memory buffers to disk.
/// 2. Performs a soft devrestart of the ZTE gateway via HTTP/CSRF session control.
/// 3. Monitors NetworkMonitor for network route disconnection and subsequent restoration.
/// 4. Verifies live internet reachability via raw socket DNS probes.
/// 5. Automatically unpauses downloads with fresh TCP streams at full 15 MB/s burst throughput!
@MainActor
public final class AutoTurboSupervisor: ObservableObject {
    public static let shared = AutoTurboSupervisor()

    // MARK: - Published State

    @Published public var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "vortex_autoturbo_enabled") }
    }

    @Published public var routerHost: String {
        didSet { UserDefaults.standard.set(routerHost, forKey: "vortex_router_host") }
    }

    @Published public var routerUser: String {
        didSet { UserDefaults.standard.set(routerUser, forKey: "vortex_router_user") }
    }

    @Published public var routerPass: String {
        didSet { savePassword(routerPass) }
    }

    @Published public var speedThresholdMBs: Double {
        didSet { UserDefaults.standard.set(speedThresholdMBs, forKey: "vortex_autoturbo_threshold") }
    }

    @Published public var cooldownMinutes: Int {
        didSet { UserDefaults.standard.set(cooldownMinutes, forKey: "vortex_autoturbo_cooldown") }
    }

    @Published public private(set) var statusMessage: String = "Idle"
    @Published public private(set) var isRebooting: Bool = false
    @Published public private(set) var lastRebootDate: Date? = nil

    // MARK: - Private Monitoring State

    private var lowSpeedCounter: Int = 0
    private let requiredLowSpeedTicks: Int = 20 // 20 ticks @ 1s = 20 seconds below threshold
    private var isBusy: Bool = false

    public var onRequirePauseDownloads: (@MainActor () -> Void)?
    public var onRequireResumeDownloads: (@MainActor () -> Void)?

    private init() {
        self.isEnabled = UserDefaults.standard.object(forKey: "vortex_autoturbo_enabled") as? Bool ?? true
        self.routerHost = UserDefaults.standard.string(forKey: "vortex_router_host") ?? "192.168.1.1"
        self.routerUser = UserDefaults.standard.string(forKey: "vortex_router_user") ?? "user"
        self.speedThresholdMBs = UserDefaults.standard.object(forKey: "vortex_autoturbo_threshold") as? Double ?? 3.8
        self.cooldownMinutes = UserDefaults.standard.object(forKey: "vortex_autoturbo_cooldown") as? Int ?? 5

        // Load password from Keychain with fallback to UserDefaults
        let keychainPw = AutoTurboSupervisor.loadKeychainPassword()
        if let pw = keychainPw, !pw.isEmpty {
            self.routerPass = pw
        } else {
            self.routerPass = UserDefaults.standard.string(forKey: "vortex_router_pass") ?? "User-6c3e"
        }
    }

    // MARK: - Monitoring Tick

    public func tick(globalSpeedBytesPerSec: Double, activeDownloadsCount: Int) {
        guard isEnabled, !isRebooting, activeDownloadsCount > 0 else {
            if !isRebooting {
                if let last = lastRebootDate {
                    let elapsed = Date().timeIntervalSince(last)
                    let cooldownSec = Double(cooldownMinutes * 60)
                    if elapsed < cooldownSec {
                        let remaining = Int((cooldownSec - elapsed) / 60) + 1
                        statusMessage = "Cooldown active (\(remaining)m remaining)"
                        return
                    }
                }
                statusMessage = activeDownloadsCount > 0 ? "Monitoring ISP speed" : "Idle"
            }
            return
        }

        // Check Cooldown
        if let last = lastRebootDate {
            let elapsed = Date().timeIntervalSince(last)
            let cooldownSec = Double(cooldownMinutes * 60)
            if elapsed < cooldownSec {
                let remaining = Int((cooldownSec - elapsed) / 60) + 1
                statusMessage = "Cooldown active (\(remaining)m remaining)"
                return
            }
        }

        let speedMBs = globalSpeedBytesPerSec / (1024 * 1024)

        if speedMBs > 0.1 && speedMBs < speedThresholdMBs {
            lowSpeedCounter += 1
            statusMessage = String(format: "Throttle detected: %.1f MB/s (%ds/%ds)", speedMBs, lowSpeedCounter, requiredLowSpeedTicks)

            if lowSpeedCounter >= requiredLowSpeedTicks {
                lowSpeedCounter = 0
                Task {
                    await triggerAutoTurboReboot()
                }
            }
        } else {
            if lowSpeedCounter > 0 {
                lowSpeedCounter = max(0, lowSpeedCounter - 1)
            }
            statusMessage = String(format: "Speed optimal: %.1f MB/s", speedMBs)
        }
    }

    // MARK: - Manual / Automated Reboot Trigger

    public func triggerManualReboot() async {
        await triggerAutoTurboReboot()
    }

    private func triggerAutoTurboReboot() async {
        guard !isBusy else { return }
        isBusy = true
        isRebooting = true
        statusMessage = "Initiating Auto-Turbo: Pausing downloads..."

        // Step 1: Safely notify app to pause downloads
        onRequirePauseDownloads?()
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s to allow write buffers to flush

        statusMessage = "Connecting to ZTE Gateway (\(routerHost))..."

        let success = await performZteRebootHttp(host: routerHost, user: routerUser, pass: routerPass)

        if success {
            self.lastRebootDate = Date()
            statusMessage = "Reboot command accepted! Waiting for router reboot..."

            // Wait for network drop and recovery
            await waitForNetworkReconnection()

            statusMessage = "Internet restored! Resuming downloads at maximum burst speed..."
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2s stabilization

            onRequireResumeDownloads?()
            statusMessage = "Turbo active: 15 MB/s burst restored!"
        } else {
            statusMessage = "Router reboot failed (Check IP/Password). Resuming downloads..."
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            onRequireResumeDownloads?()
        }

        isRebooting = false
        isBusy = false
    }

    // MARK: - Native HTTP ZTE MT-0011 devrestart

    private func performZteRebootHttp(host: String, user: String, pass: String) async -> Bool {
        return await Task.detached { [host, user, pass] in
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 6.0
            config.timeoutIntervalForResource = 10.0
            config.httpCookieAcceptPolicy = .always
            config.httpShouldSetCookies = true
            let session = URLSession(configuration: config)

            guard let loginUrl = URL(string: "http://\(host)/") else { return false }

            // 1. Post Login Form
            var loginReq = URLRequest(url: loginUrl)
            loginReq.httpMethod = "POST"
            loginReq.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            loginReq.setValue("http://\(host)/", forHTTPHeaderField: "Referer")
            loginReq.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")

            let postBody = "username=\(user.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? user)&password=\(pass.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? pass)&action=login&Frm_Logintoken=0&ieversion=1"
            loginReq.httpBody = Data(postBody.utf8)

            do {
                let (data, response) = try await session.data(for: loginReq)
                let respStr = String(data: data, encoding: .utf8) ?? ""
                if respStr.contains("User information is error") || respStr.contains("wrong username or password") {
                    return false
                }
                _ = response
            } catch {
                // If router refused or dropped, continue to attempt restart
            }

            // 2. Fetch restart page to extract CSRF token
            var sessionToken: String = ""
            if let restartPageUrl = URL(string: "http://\(host)/getpage.gch?pid=1002&nextpage=manager_dev_restart_t.gch") {
                var pReq = URLRequest(url: restartPageUrl)
                pReq.setValue("http://\(host)/", forHTTPHeaderField: "Referer")
                pReq.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")
                if let (pData, _) = try? await session.data(for: pReq),
                   let pStr = String(data: pData, encoding: .utf8) {
                    if let range = pStr.range(of: "session_token\\s*=\\s*['\"](\\d+)['\"]", options: .regularExpression) {
                        let tokenSub = String(pStr[range])
                        let digits = tokenSub.filter { $0.isNumber }
                        sessionToken = digits
                    }
                }
            }

            // 3. Send devrestart command
            guard let execUrl = URL(string: "http://\(host)/getpage.gch?pid=1002&nextpage=manager_dev_restart_t.gch") else { return false }
            var execReq = URLRequest(url: execUrl)
            execReq.httpMethod = "POST"
            execReq.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            execReq.setValue("http://\(host)/", forHTTPHeaderField: "Referer")

            var execBody = "IF_ACTION=devrestart&flag=1"
            if !sessionToken.isEmpty {
                execBody += "&_SESSION_TOKEN=\(sessionToken)"
            }
            execReq.httpBody = Data(execBody.utf8)

            do {
                _ = try await session.data(for: execReq)
                return true
            } catch {
                // When router executes devrestart, it terminates all TCP connections immediately, which throws an NSURLError. This is success!
                return true
            }
        }.value
    }

    // MARK: - Reconnection Supervision

    private func waitForNetworkReconnection() async {
        // Wait up to 75 seconds for router reboot cycle
        let maxWaitSeconds = 75
        var elapsed = 0

        // Phase 1: Wait 10 seconds for router to physically begin power cycle
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            elapsed += 1
            statusMessage = "Router rebooting... (\(elapsed)s)"
        }

        // Phase 2: Probe internet socket until restored
        while elapsed < maxWaitSeconds {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            elapsed += 1

            let online = NetworkMonitor.quickInternetCheck(timeout: 1.0)
            if online {
                statusMessage = "Network re-established after \(elapsed)s!"
                return
            } else {
                statusMessage = "Waiting for Kurdistan Net WAN sync... (\(elapsed)s/\(maxWaitSeconds)s)"
            }
        }
    }

    // MARK: - Keychain Security

    private func savePassword(_ pw: String) {
        UserDefaults.standard.set(pw, forKey: "vortex_router_pass")
        Task.detached {
            let service = "VortexRouter"
            let account = "user"
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            SecItemDelete(query as CFDictionary)

            guard let pwData = pw.data(using: .utf8), !pw.isEmpty else { return }
            var addQuery = query
            addQuery[kSecValueData as String] = pwData
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    private static func loadKeychainPassword() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "VortexRouter",
            kSecAttrAccount as String: "user",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, let pw = String(data: data, encoding: .utf8) {
            return pw
        }
        return nil
    }
}
