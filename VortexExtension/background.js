// Vortex Chrome Extension - Background Service Worker
const VORTEX_IPC_URL = 'http://127.0.0.1:17890';

const DEFAULT_EXTENSIONS = [
  'zip', 'rar', '7z', 'iso', 'bin', 'cue', 'pkg', 'dmg', 'tar', 'gz', 'bz2',
  'exe', 'msi', 'mp4', 'mkv', 'avi', 'mov', 'flv', 'wmv', 'mp3', 'flac',
  'wav', 'pdf', 'apk', 'ipa', 'rom', 'cso', 'chd', 'zst'
];

// Domains that should always be intercepted regardless of extension (e.g. romsfun direct CDN links)
const ALWAYS_INTERCEPT_DOMAINS = [
  'romsfun.com', 'romspure.cc', '1fichier.com', 'rapidgator.net', 'buzzheavier.com', 'mega.nz'
];

// Set default settings on install
chrome.runtime.onInstalled.addListener(() => {
  chrome.storage.local.get(['interceptEnabled', 'extensions', 'interceptAll'], (res) => {
    if (res.interceptEnabled === undefined) {
      chrome.storage.local.set({
        interceptEnabled: true,
        interceptAll: false,
        extensions: DEFAULT_EXTENSIONS
      });
    }
  });

  // Setup context menus
  chrome.contextMenus.create({
    id: 'vortex-download-link',
    title: 'Download with Vortex',
    contexts: ['link']
  });

  chrome.contextMenus.create({
    id: 'vortex-download-media',
    title: 'Download Media with Vortex',
    contexts: ['video', 'audio', 'image']
  });
});

// Helper: Check if URL or filename matches downloadable types
function shouldIntercept(url, filename, settings) {
  if (!settings.interceptEnabled) return false;
  if (settings.interceptAll) return true;

  // Check domain list
  try {
    const parsed = new URL(url);
    if (ALWAYS_INTERCEPT_DOMAINS.some(d => parsed.hostname.includes(d))) {
      return true;
    }
  } catch (e) {}

  // Check file extension
  const target = (filename || url).split('?')[0].split('#')[0].toLowerCase();
  const ext = target.split('.').pop();
  return (settings.extensions || DEFAULT_EXTENSIONS).includes(ext);
}

// Track downloads we have already canceled to prevent duplicates
const handledDownloadIds = new Set();

// Intercept browser downloads
chrome.downloads.onCreated.addListener(async (item) => {
  if (handledDownloadIds.has(item.id)) return;

  // CRITICAL: Ignore historical, completed, interrupted, or restored downloads from past sessions
  if (item.state && item.state !== 'in_progress') return;
  if (item.bytesReceived && item.bytesReceived > 0) return;
  if (item.startTime) {
    const elapsed = Date.now() - new Date(item.startTime).getTime();
    if (elapsed > 10000 || elapsed < -10000) return; // Ignore items older than 10 seconds
  }

  chrome.storage.local.get(['interceptEnabled', 'extensions', 'interceptAll'], async (settings) => {
    const downloadUrl = item.finalUrl || item.url;
    if (!downloadUrl || downloadUrl.startsWith('blob:') || downloadUrl.startsWith('data:')) return;

    if (shouldIntercept(downloadUrl, item.filename, settings)) {
      handledDownloadIds.add(item.id);

      // Cancel Chrome's native download
      try {
        await chrome.downloads.cancel(item.id);
        await chrome.downloads.erase({ id: item.id });
      } catch (e) {
        console.warn('[Vortex] Could not cancel Chrome download:', e);
      }

      // Collect cookies for the domain (vital for romsfun & authenticated tokens)
      const cookies = await getCookiesForUrl(downloadUrl);

      // Send to Vortex Native App
      await dispatchToVortex({
        url: downloadUrl,
        referrer: item.referrer || '',
        filename: item.filename ? item.filename.split('/').pop().split('\\').pop() : '',
        cookies: cookies,
        userAgent: navigator.userAgent,
        segments: 16
      });
    }
  });
});

// Also hook onDeterminingFilename for earlier interception
chrome.downloads.onDeterminingFilename.addListener((item, suggest) => {
  if (handledDownloadIds.has(item.id)) return;

  // Ignore historical downloads
  if (item.state && item.state !== 'in_progress') return;
  if (item.bytesReceived && item.bytesReceived > 0) return;
  if (item.startTime) {
    const elapsed = Date.now() - new Date(item.startTime).getTime();
    if (elapsed > 10000 || elapsed < -10000) return;
  }

  chrome.storage.local.get(['interceptEnabled', 'extensions', 'interceptAll'], async (settings) => {
    const downloadUrl = item.finalUrl || item.url;
    if (shouldIntercept(downloadUrl, item.filename, settings)) {
      handledDownloadIds.add(item.id);

      try {
        await chrome.downloads.cancel(item.id);
        await chrome.downloads.erase({ id: item.id });
      } catch (e) {}

      const cookies = await getCookiesForUrl(downloadUrl);
      await dispatchToVortex({
        url: downloadUrl,
        referrer: item.referrer || '',
        filename: item.filename ? item.filename.split('/').pop().split('\\').pop() : '',
        cookies: cookies,
        userAgent: navigator.userAgent,
        segments: 16
      });
    }
  });
  return false;
});

// Context Menu clicks
chrome.contextMenus.onClicked.addListener(async (info, tab) => {
  const targetUrl = info.linkUrl || info.srcUrl;
  if (!targetUrl) return;

  const cookies = await getCookiesForUrl(targetUrl);
  await dispatchToVortex({
    url: targetUrl,
    referrer: info.pageUrl || tab?.url || '',
    filename: '',
    cookies: cookies,
    userAgent: navigator.userAgent,
    segments: 16
  });
});

// Helper: Get cookies as "name=val; name2=val2" string
async function getCookiesForUrl(url) {
  try {
    const cookies = await chrome.cookies.getAll({ url });
    if (!cookies || cookies.length === 0) return '';
    return cookies.map(c => `${c.name}=${c.value}`).join('; ');
  } catch (e) {
    return '';
  }
}

// Helper: Format bytes
function formatBytes(bytes) {
  if (!bytes || bytes <= 0) return '0 B';
  const k = 1024;
  const sizes = ['B', 'KB', 'MB', 'GB', 'TB'];
  const i = Math.floor(Math.log(bytes) / Math.log(k));
  return (bytes / Math.pow(k, i)).toFixed(1) + ' ' + sizes[i];
}

// Dispatch payload to Vortex via HTTP IPC or deep link fallback
async function dispatchToVortex(payload) {
  try {
    // 1. First check if there is an expired or paused download waiting for renewal!
    const statusResp = await fetch(`${VORTEX_IPC_URL}/status`, { cache: 'no-store' });
    if (statusResp.ok) {
      const statusData = await statusResp.json();
      const expiredList = statusData.expiredDownloads || [];

      // Check if this download matches an existing expired download in Vortex
      const matched = expiredList.find(exp => {
        if (payload.referrer && exp.originalPageUrl) {
          try {
            const refPath = new URL(payload.referrer).pathname;
            const expPath = new URL(exp.originalPageUrl).pathname;
            if (refPath === expPath) return true;
          } catch (e) {}
        }
        if (payload.filename && exp.fileName) {
          if (exp.fileName.toLowerCase().includes(payload.filename.toLowerCase()) ||
              payload.filename.toLowerCase().includes(exp.fileName.toLowerCase())) {
            return true;
          }
        }
        return false;
      }) || (expiredList.length === 1 ? expiredList[0] : null);

      if (matched) {
        console.log('[Vortex] Found matching expired download:', matched.fileName, 'Auto-renewing link...');
        const refreshResp = await fetch(`${VORTEX_IPC_URL}/refresh`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            taskId: matched.id,
            originalUrl: payload.referrer || '',
            filename: payload.filename || '',
            newUrl: payload.url,
            cookies: payload.cookies,
            userAgent: payload.userAgent
          })
        });

        if (refreshResp.ok) {
          const resData = await refreshResp.json();
          const resumedAt = resData.resumedFrom || matched.downloadedBytes || 0;
          const total = resData.totalBytes || matched.totalBytes || 1;
          const percent = Math.round((resumedAt / total) * 100);

          showBadge('✓', '#00C853');
          console.log(`[Vortex] Auto-renewed successfully! Resumed at ${formatBytes(resumedAt)} (${percent}% preserved).`);
          return;
        }
      }
    }

    // 2. Otherwise add as new download
    const response = await fetch(`${VORTEX_IPC_URL}/download`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload)
    });

    if (response.ok) {
      showBadge('✓', '#00C853');
      return;
    }
  } catch (err) {
    console.log('[Vortex] Local IPC server not reached. Launching via vortex:// URL scheme...');
  }

  // Fallback: Launch Vortex via custom URL scheme
  const params = new URLSearchParams({
    url: payload.url,
    referer: payload.referrer || '',
    filename: payload.filename || '',
    cookies: payload.cookies || '',
    userAgent: payload.userAgent || ''
  });

  const deepLink = `vortex://download?${params.toString()}`;
  chrome.tabs.create({ url: deepLink, active: false }, (tab) => {
    // Close the deep link tab shortly after invocation
    setTimeout(() => {
      if (tab && tab.id) chrome.tabs.remove(tab.id).catch(() => {});
    }, 1500);
  });

  showBadge('⚡', '#0091FF');
}

function showBadge(text, color) {
  chrome.action.setBadgeText({ text });
  chrome.action.setBadgeBackgroundColor({ color });
  setTimeout(() => {
    chrome.action.setBadgeText({ text: '' });
  }, 4000);
}

// -------------------------------------------------------------
// Autonomous Zero-Click Headless Token Renewal Watchdog
// -------------------------------------------------------------
const activeRenewals = new Set();

async function pollAndAutoRenewExpiredDownloads() {
  try {
    const res = await fetch(`${VORTEX_IPC_URL}/status`);
    if (!res.ok) return;
    const data = await res.json();
    const expiredList = data.expiredDownloads || [];

    for (const exp of expiredList) {
      if (!exp.originalPageUrl || activeRenewals.has(exp.id)) continue;
      activeRenewals.add(exp.id);

      console.log(`[Vortex Auto-Renew] Found expired task ${exp.id} (${exp.fileName}). Launching silent renewal tab...`);
      showBadge('↻', '#FF9100');

      chrome.tabs.create({ url: exp.originalPageUrl, active: false }, (tab) => {
        if (!tab || !tab.id) {
          activeRenewals.delete(exp.id);
          return;
        }

        const tabId = tab.id;
        let triggered = false;

        const updateListener = (tId, changeInfo) => {
          if (tId === tabId && changeInfo.status === 'complete' && !triggered) {
            triggered = true;
            chrome.tabs.onUpdated.removeListener(updateListener);

            // Wait 2.5s for dynamic JS countdowns / DOM to hydrate
            setTimeout(() => {
              chrome.scripting.executeScript({
                target: { tabId },
                func: () => {
                  const selectors = [
                    '#download', '.download', 'a.btn-download', 'a[href*="download"]',
                    'button[type="submit"]', 'a.slow-download', '#btn-download'
                  ];
                  for (const sel of selectors) {
                    const el = document.querySelector(sel);
                    if (el) {
                      el.click();
                      break;
                    }
                  }
                }
              }).catch(() => {});

              // Auto-close renewal tab after 25s
              setTimeout(() => {
                chrome.tabs.remove(tabId).catch(() => {});
                activeRenewals.delete(exp.id);
              }, 25000);
            }, 2500);
          }
        };

        chrome.tabs.onUpdated.addListener(updateListener);
      });
    }
  } catch (e) {}
}

// Poll every 8 seconds for expired downloads
setInterval(pollAndAutoRenewExpiredDownloads, 8000);

