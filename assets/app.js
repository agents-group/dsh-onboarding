/**
 * dsh-onboarding site helpers: load defaults, build install commands, copy UX.
 */
(function () {
  const state = {
    config: null,
    siteBase: '',
  };

  function $(sel, root = document) {
    return root.querySelector(sel);
  }

  function $all(sel, root = document) {
    return Array.from(root.querySelectorAll(sel));
  }

  function normalizeBase(url) {
    if (!url) return '';
    return String(url).trim().replace(/\/+$/, '');
  }

  function detectSiteBase() {
    // Prefer explicit override from localStorage / input; else current origin + path root.
    const saved = localStorage.getItem('dsh_onboard_site_base');
    if (saved) return normalizeBase(saved);

    const { origin, pathname } = window.location;
    // If hosted at .../dsh-onboarding/ or .../dsh-onboarding/index.html
    let path = pathname.replace(/\\/g, '/');
    if (path.endsWith('.html')) {
      path = path.slice(0, path.lastIndexOf('/'));
    }
    path = path.replace(/\/+$/, '');
    return normalizeBase(origin + path);
  }

  function maskKey(key) {
    if (!key) return '（未配置）';
    if (/REPLACE_WITH_YOUR_KEY|sk-xxx|changeme/i.test(key)) return '（占位，请先填写真实 Key）';
    if (key.length <= 8) return '*'.repeat(key.length);
    return `${key.slice(0, 4)}${'*'.repeat(Math.min(12, key.length - 8))}${key.slice(-4)}`;
  }

  function buildCommands(base, config) {
    const configUrl = `${base}/config/defaults.json`;
    const shUrl = `${base}/scripts/bootstrap.sh`;
    const psUrl = `${base}/scripts/bootstrap.ps1`;
    const winBootUrl = `${base}/scripts/bootstrap-win.ps1`;

    // Windows: one-liner downloads temp runtime via Cloudflare site + mirrors, then runs install agent.
    const win = `$env:DSH_ONBOARD_CONFIG_URL='${configUrl}'; irm '${winBootUrl}' | iex`;
    const winCheckDownload = `$env:DSH_ONBOARD_CONFIG_URL='${configUrl}'; irm '${winBootUrl}' -OutFile bootstrap-win.ps1; .\\bootstrap-win.ps1 -NoLaunch`;
    const winNoLaunch = `$env:DSH_ONBOARD_CONFIG_URL='${configUrl}'; irm '${winBootUrl}' -OutFile bootstrap-win.ps1; .\\bootstrap-win.ps1 -NoLaunch`;

    const unix = `curl -fsSL '${shUrl}' | bash -s -- --config-url '${configUrl}'`;
    const unixCheck = `curl -fsSL '${shUrl}' | bash -s -- --config-url '${configUrl}' --check-only`;
    const unixNoLaunch = `curl -fsSL '${shUrl}' | bash -s -- --config-url '${configUrl}' --no-launch`;

    const manual = [
      `# 1) 安装 Node.js 22.19+ 或 24+  https://nodejs.org/`,
      `# 2) 写入凭据（PowerShell 示例）`,
      `$dsh = Join-Path $HOME '.dsh'`,
      `New-Item -ItemType Directory -Force -Path $dsh | Out-Null`,
      `"DEEPSEEK_API_KEY: ${config.apiKey}" | Set-Content (Join-Path $dsh '.credentials.yaml')`,
      `"DEEPSEEK_BASE_URL=${config.baseURL}" | Set-Content (Join-Path $dsh '.env')`,
      `# 3) 启动`,
      `npx -y ${config.cliPackage || '@deepseek-ai/dsh'} ${(config.launchArgs || ['web']).join(' ')}`,
    ].join('\n');

    return {
      configUrl,
      shUrl,
      psUrl,
      win,
      winCheck: winCheckDownload,
      winNoLaunch,
      unix,
      unixCheck,
      unixNoLaunch,
      manual,
    };
  }

  function setText(id, text) {
    const el = document.getElementById(id);
    if (el) el.textContent = text;
  }

  function setCode(id, text) {
    const el = document.getElementById(id);
    if (el) el.textContent = text;
  }

  function applyConfig(config, base) {
    state.config = config;
    state.siteBase = base;

    const cmds = buildCommands(base, config);

    setText('cfg-product', config.productName || 'DeepSeek Harness');
    setText('cfg-package', config.cliPackage || '@deepseek-ai/dsh');
    setText('cfg-node', config.nodeEngines || '^22.19.0 || >=24.0.0');
    setText('cfg-baseurl', config.baseURL || '');
    setText('cfg-apikey', maskKey(config.apiKey));
    setText('cfg-port', String(config.defaultPort || 3080));

    setCode('cmd-windows', cmds.win);
    setCode('cmd-unix', cmds.unix);
    setCode('cmd-windows-check', cmds.winCheck);
    setCode('cmd-unix-check', cmds.unixCheck);
    setCode('cmd-windows-nolaunch', cmds.winNoLaunch);
    setCode('cmd-unix-nolaunch', cmds.unixNoLaunch);
    setCode('cmd-manual', cmds.manual);

    const input = $('#site-base-input');
    if (input && !input.value) input.value = base;

    const placeholderWarning = $('#placeholder-warning');
    if (placeholderWarning) {
      const isPlaceholder = !config.apiKey || /REPLACE_WITH_YOUR_KEY|sk-xxx|changeme/i.test(config.apiKey);
      placeholderWarning.hidden = !isPlaceholder;
    }
  }

  async function loadConfig() {
    const base = detectSiteBase();
    let config;
    try {
      const res = await fetch(`${base}/config/defaults.json`, { cache: 'no-store' });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      config = await res.json();
    } catch (err) {
      console.warn('defaults.json load failed, using fallback', err);
      config = {
        productName: 'DeepSeek Harness',
        cliPackage: '@deepseek-ai/dsh',
        launchArgs: ['web'],
        defaultPort: 3080,
        nodeEngines: '^22.19.0 || >=24.0.0',
        apiKey: 'sk-REPLACE_WITH_YOUR_KEY',
        baseURL: 'https://api.deepseek.com',
      };
    }
    applyConfig(config, base);
  }

  function initTabs() {
    $all('[data-tabs]').forEach((root) => {
      const tabs = $all('[data-tab]', root);
      const panels = $all('[data-panel]', root);
      tabs.forEach((tab) => {
        tab.addEventListener('click', () => {
          const id = tab.getAttribute('data-tab');
          tabs.forEach((t) => t.classList.toggle('active', t === tab));
          panels.forEach((p) => p.classList.toggle('active', p.getAttribute('data-panel') === id));
        });
      });
    });
  }

  async function copyText(text) {
    if (navigator.clipboard && window.isSecureContext) {
      await navigator.clipboard.writeText(text);
      return;
    }
    const ta = document.createElement('textarea');
    ta.value = text;
    ta.style.position = 'fixed';
    ta.style.left = '-9999px';
    document.body.appendChild(ta);
    ta.select();
    document.execCommand('copy');
    document.body.removeChild(ta);
  }

  function initCopyButtons() {
    $all('[data-copy-target]').forEach((btn) => {
      btn.addEventListener('click', async () => {
        const targetId = btn.getAttribute('data-copy-target');
        const el = document.getElementById(targetId);
        if (!el) return;
        try {
          await copyText(el.textContent || '');
          const old = btn.textContent;
          btn.classList.add('copied');
          btn.textContent = '已复制';
          setTimeout(() => {
            btn.classList.remove('copied');
            btn.textContent = old;
          }, 1500);
        } catch (e) {
          btn.textContent = '复制失败';
        }
      });
    });
  }

  function initSiteBaseForm() {
    const form = $('#site-base-form');
    const input = $('#site-base-input');
    if (!form || !input) return;

    form.addEventListener('submit', (e) => {
      e.preventDefault();
      const base = normalizeBase(input.value);
      if (!base) return;
      localStorage.setItem('dsh_onboard_site_base', base);
      if (state.config) applyConfig(state.config, base);
    });

    $('#site-base-reset')?.addEventListener('click', () => {
      localStorage.removeItem('dsh_onboard_site_base');
      input.value = '';
      loadConfig();
    });
  }

  document.addEventListener('DOMContentLoaded', () => {
    initTabs();
    initCopyButtons();
    initSiteBaseForm();
    loadConfig();
  });
})();
