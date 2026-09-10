// Vortex Chrome Extension - Popup Logic
const VORTEX_IPC_URL = 'http://127.0.0.1:17890';

document.addEventListener('DOMContentLoaded', () => {
  const statusBadge = document.getElementById('status-badge');
  const statusIndicator = document.getElementById('status-indicator');
  const statusTitle = document.getElementById('status-title');
  const statusDetail = document.getElementById('status-detail');
  const btnLaunch = document.getElementById('btn-launch-vortex');
  const toggleIntercept = document.getElementById('toggle-intercept');
  const toggleAll = document.getElementById('toggle-all');
  const quickUrlInput = document.getElementById('quick-url');
  const btnPaste = document.getElementById('btn-paste');
  const btnSend = document.getElementById('btn-send-download');
  const feedbackMsg = document.getElementById('feedback-msg');

  // Load saved settings
  chrome.storage.local.get(['interceptEnabled', 'interceptAll'], (res) => {
    toggleIntercept.checked = res.interceptEnabled !== false;
    toggleAll.checked = res.interceptAll === true;
  });

  // Check connection status to native app
  checkVortexStatus();

  async function checkVortexStatus() {
    try {
      const resp = await fetch(`${VORTEX_IPC_URL}/status`, { cache: 'no-store' });
      if (resp.ok) {
        const data = await resp.json();
        statusBadge.textContent = 'CONNECTED';
        statusBadge.className = 'status-badge connected';
        statusIndicator.className = 'indicator-dot connected';
        statusTitle.textContent = `Vortex App Ready (v${data.version || '1.0'})`;
        statusDetail.textContent = `${data.activeDownloads || 0} active downloads`;
        btnLaunch.style.display = 'none';
        return;
      }
    } catch (e) {}

    // Disconnected state
    statusBadge.textContent = 'OFFLINE';
    statusBadge.className = 'status-badge disconnected';
    statusIndicator.className = 'indicator-dot disconnected';
    statusTitle.textContent = 'Vortex Not Running';
    statusDetail.textContent = 'Click "Launch App" to open Vortex';
    btnLaunch.style.display = 'block';
  }

  // Toggles
  toggleIntercept.addEventListener('change', () => {
    chrome.storage.local.set({ interceptEnabled: toggleIntercept.checked });
  });

  toggleAll.addEventListener('change', () => {
    chrome.storage.local.set({ interceptAll: toggleAll.checked });
  });

  // Launch App
  btnLaunch.addEventListener('click', () => {
    chrome.tabs.create({ url: 'vortex://open', active: false }, (tab) => {
      setTimeout(() => {
        if (tab && tab.id) chrome.tabs.remove(tab.id).catch(() => {});
        checkVortexStatus();
      }, 1000);
    });
  });

  // Paste from clipboard
  btnPaste.addEventListener('click', async () => {
    try {
      const text = await navigator.clipboard.readText();
      quickUrlInput.value = text.trim();
    } catch (e) {
      feedbackMsg.textContent = 'Clipboard permission denied';
      feedbackMsg.style.color = '#ff5252';
    }
  });

  // Send Download
  btnSend.addEventListener('click', async () => {
    const url = quickUrlInput.value.trim();
    if (!url || (!url.startsWith('http://') && !url.startsWith('https://'))) {
      feedbackMsg.textContent = 'Please enter a valid HTTP/HTTPS URL';
      feedbackMsg.style.color = '#ff5252';
      return;
    }

    feedbackMsg.textContent = 'Sending to Vortex...';
    feedbackMsg.style.color = '#00e5ff';

    // Get active tab for referrer
    chrome.tabs.query({ active: true, currentWindow: true }, async (tabs) => {
      const currentTab = tabs[0];
      const referrer = currentTab?.url || '';

      // Get cookies
      let cookies = '';
      try {
        const cList = await chrome.cookies.getAll({ url });
        cookies = cList.map(c => `${c.name}=${c.value}`).join('; ');
      } catch (e) {}

      try {
        const resp = await fetch(`${VORTEX_IPC_URL}/download`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            url,
            referrer,
            filename: '',
            cookies,
            userAgent: navigator.userAgent,
            segments: 8
          })
        });

        if (resp.ok) {
          feedbackMsg.textContent = '✓ Download dispatched to Vortex!';
          feedbackMsg.style.color = '#00e676';
          quickUrlInput.value = '';
          setTimeout(() => { feedbackMsg.textContent = ''; }, 3000);
          return;
        }
      } catch (err) {}

      // Fallback: Launch via deep link
      const params = new URLSearchParams({ url, referer: referrer, cookies });
      chrome.tabs.create({ url: `vortex://download?${params.toString()}`, active: false }, (t) => {
        setTimeout(() => {
          if (t && t.id) chrome.tabs.remove(t.id).catch(() => {});
        }, 1000);
      });

      feedbackMsg.textContent = '✓ Sent to Vortex via Deep Link!';
      feedbackMsg.style.color = '#00e676';
      quickUrlInput.value = '';
    });
  });
});
