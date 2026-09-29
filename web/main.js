/* NotchCenter 产品主页交互
 *
 * 职责只有四件：语言切换、插件网格渲染、演示视频的播放控制、图标 sprite 的引用。
 *
 * 双语策略：中文文案写死在 index.html 里（那也是无 JS 时的基准语言），本文件只保存
 * 英文；切回中文时从 DOM 现场快照恢复原文，所以中文文案全局只有一份，不存在两份
 * 会互相漂移的翻译表。见 web/README.md。
 *
 * 插件数据来自 data/plugins.gen.js（由 web/tools/gen-plugins.mjs 从 Plugins 目录下每个
 * 插件的 Plugin.plist 生成），本文件不含任何插件清单，因此新增或改名插件都不需要动这里。
 */

(() => {
  "use strict";

  const STORAGE_KEY = "notchcenter.lang";

  // 插件目录名 -> sprite 符号 id。没登记的插件回退到通用图标（不画错、不留白），
  // 并在控制台提示，便于维护者补一个图标。键是目录名而非 PluginID：目录名稳定，
  // 且 Plugins/ 的目录名就是插件身份（PluginID 存在历史前缀差异）。
  const ICON_BY_DIR = {
    AlbumPlugin: "i-album",
    CaffeinatePlugin: "i-caffeinate",
    CalendarPlugin: "i-calendar",
    CalibrePlugin: "i-calibre",
    CameraPlugin: "i-camera",
    ClipboardHistoryPlugin: "i-clipboard",
    ClockPlugin: "i-clock",
    CommandSchedulerPlugin: "i-terminal",
    DisplayPlugin: "i-display",
    DshPlugin: "i-server",
    LidAngleDepthPlugin: "i-lid",
    MediaControlsPlugin: "i-media",
    NotesPlugin: "i-notes",
    PomodoroPlugin: "i-pomodoro",
    QuickButtonBoxPlugin: "i-box",
    RemindersPlugin: "i-reminders",
    ScratchpadPlugin: "i-scratchpad",
    SystemMonitorPlugin: "i-monitor",
  };
  const FALLBACK_ICON = "i-plugin";

  const STRINGS = {
    en: {
      "meta.title": "NotchCenter - Turn your Mac's notch into a control center",
      skip: "Skip to main content",
      "nav.features": "Features",
      "nav.demos": "Demos",
      "nav.plugins": "Plugins",
      "nav.install": "Install",
      "nav.github": "Open the repository on GitHub",
      "hero.eyebrow": "macOS 15+ · Native Swift · Apple Silicon and Intel",
      "hero.title": "Turn the notch into a control center",
      "hero.lead":
        "Move the pointer to the notch at the top of your screen and a drawer unfolds from it: a grid of blocks provided by plugins - Markdown notes, a file shelf, clipboard history, system monitors. The core only handles notch interaction, window management and layout; every feature is a plugin.",
      "hero.downloadDmg": "Download .dmg",
      "hero.downloadZip": "Download .zip",
      "hero.repo": "View on GitHub",
      "hero.note":
        "Public builds are ad-hoc signed and not notarized by Apple, so the first launch needs a right-click and Open.",
      "hero.shotAlt":
        "The NotchCenter drawer expanded: grid blocks under the notch, including a Pomodoro timer, a file shelf, service switches and a Markdown editor",
      "features.title": "What it solves",
      "features.lead":
        "Not another menu bar icon. It turns the black strip at the top of your screen into an entry point that is always there.",
      "features.f1.title": "Notch-first",
      "features.f1.desc":
        "Every surface is anchored to the top center of the screen: the compact state sits beside the notch, the drawer unfolds downward, and it never steals focus or desktop space.",
      "features.f2.title": "A plugin host",
      "features.f2.desc":
        "The core only handles notch interaction, window management, plugin loading and the layout engine. Features come from plugins, and third-party .bundle files install at runtime.",
      "features.f3.title": "A drawer grid you can change",
      "features.f3.desc":
        "Every block can be rearranged, resized, added or removed; the number of slots follows the icons instead of being fixed. Edit mode edits the layout directly.",
      "features.f4.title": "Local first",
      "features.f4.desc":
        "Notes and shelf entries stay on your Mac and survive reinstalling the app. The file shelf only holds references - it never moves or deletes your originals.",
      "features.f5.title": "Out of the way",
      "features.f5.desc":
        "It runs as an accessory: no Dock icon, a single status bar menu item, and the drawer collapses as soon as the pointer leaves the stay region.",
      "demos.title": "See it move",
      "demos.lead":
        "Two muted loops: everyday use and editing the layout. The drawer collapses by itself once the pointer leaves the stay region.",
      "demos.common.title": "Everyday use",
      "demos.common.desc":
        "Move to the notch to unfold the drawer: a Pomodoro timer, service switches, the file shelf and notes all on one screen.",
      "demos.settings.title": "Editing the layout",
      "demos.settings.desc":
        "In edit mode you drag, resize, add and remove blocks; slots follow the content and take effect when you leave.",
      "demos.pause": "Pause demo",
      "demos.play": "Play demo",
      "plugins.title": "official plugins, bundled with the app",
      "plugins.lead":
        "Every official plugin ships with the app and works out of the box. Third-party plugins install at runtime as .bundle files and show up in the drawer grid and the compact area just the same.",
      "plugins.noscript":
        "The plugin list needs JavaScript to render. You can browse all plugins in the Plugins/ directory on GitHub.",
      "plugins.error": "The plugin list could not be loaded.",
      "install.title": "Install",
      "install.lead":
        "The download is universal (Apple Silicon and Intel) and requires macOS 15 or later.",
      "install.s1.title": "Download the disk image",
      "install.s1.desc": "Grab the latest NotchCenter.dmg (the zip archive works too).",
      "install.s2.title": "Drag it into Applications",
      "install.s2.desc":
        "Mount the image and drag NotchCenter.app into Applications; the zip archive ends in the same step.",
      "install.s3.title": "Right-click to open the first time",
      "install.s3.desc":
        "Right-click the app and choose Open. If macOS still blocks it, open System Settings → Privacy & Security and click Open Anyway.",
      "install.gatekeeper":
        "Public builds are ad-hoc signed and not notarized by Apple, so the first launch shows a security prompt. That does not mean the app is damaged; prompt-free distribution needs a Developer ID certificate and Apple notarization.",
      "install.linkDmg": "Latest release (dmg)",
      "install.linkZip": "Latest release (zip)",
      "install.linkReleases": "All releases",
      "footer.tagline": "A native macOS plugin host for the notch.",
      "footer.downloads": "Download",
      "footer.releases": "Releases",
      "footer.project": "Project",
      "footer.repo": "GitHub repository",
      "footer.docs": "Developer docs",
      "footer.license": "MIT license",
      "footer.attribution":
        "NotchCenter was rebuilt from NotchNotes; the original project keeps the early notes, file shelf and keep-awake implementation.",
    },
  };

  // 语言切换按钮的无障碍标签（两种语言下都要说清楚点了会发生什么）。
  const TOGGLE_LABEL = {
    zh: { text: "EN", label: "切换到英文" },
    en: { text: "中文", label: "Switch to Chinese" },
  };

  const originalTitle = document.title;
  const originals = new WeakMap();

  function storeFor(element) {
    let store = originals.get(element);
    if (!store) {
      store = {};
      originals.set(element, store);
    }
    return store;
  }

  function translationFor(key, fallback) {
    const value = STRINGS.en[key];
    if (value === undefined) {
      console.warn(`main.js: 缺少英文文案 "${key}"，该处保留中文`);
      return fallback;
    }
    return value;
  }
  // ---- 语言 --------------------------------------------------------------

  function resolveLang() {
    const query = new URLSearchParams(window.location.search).get("lang");
    if (query) {
      const normalized = query.toLowerCase();
      if (normalized.startsWith("zh")) return "zh";
      if (normalized.startsWith("en")) return "en";
    }
    try {
      const stored = window.localStorage.getItem(STORAGE_KEY);
      if (stored === "zh" || stored === "en") return stored;
    } catch (error) {
      // file:// 或隐私模式下 localStorage 可能不可用，忽略即可。
    }
    return (navigator.language || "en").toLowerCase().startsWith("zh") ? "zh" : "en";
  }

  let currentLang = resolveLang();

  function applyLang(lang) {
    document.documentElement.lang = lang === "zh" ? "zh-Hans" : "en";
    document.title = lang === "zh" ? originalTitle : STRINGS.en["meta.title"];

    for (const element of document.querySelectorAll("[data-i18n], [data-i18n-html]")) {
      const useHtml = element.hasAttribute("data-i18n-html");
      const key = useHtml ? element.dataset.i18nHtml : element.dataset.i18n;
      const store = storeFor(element);
      const slot = useHtml ? "html" : "text";
      if (store[slot] === undefined) {
        store[slot] = useHtml ? element.innerHTML : element.textContent;
      }
      const value = lang === "zh" ? store[slot] : translationFor(key, store[slot]);
      if (useHtml) element.innerHTML = value;
      else element.textContent = value;
    }

    for (const element of document.querySelectorAll("[data-i18n-attr]")) {
      const store = storeFor(element);
      for (const pair of element.dataset.i18nAttr.split(",")) {
        const [attribute, key] = pair.split("=").map((part) => part.trim());
        if (!attribute || !key) continue;
        const slot = `attr:${attribute}`;
        if (store[slot] === undefined) store[slot] = element.getAttribute(attribute) || "";
        const value = lang === "zh" ? store[slot] : translationFor(key, store[slot]);
        if (value === "") element.removeAttribute(attribute);
        else element.setAttribute(attribute, value);
      }
    }

    const toggle = document.querySelector("[data-lang-toggle]");
    if (toggle) {
      toggle.textContent = TOGGLE_LABEL[lang].text;
      toggle.setAttribute("aria-label", TOGGLE_LABEL[lang].label);
    }
  }

  function setLang(lang) {
    currentLang = lang;
    try {
      window.localStorage.setItem(STORAGE_KEY, lang);
    } catch (error) {
      // 存不下就算了，切换本身仍然生效。
    }
    render();
  }

  // ---- 插件网格 ----------------------------------------------------------

  function resolveIconId(dir) {
    const iconId = ICON_BY_DIR[dir] || FALLBACK_ICON;
    if (document.getElementById(iconId)) return iconId;
    return document.getElementById(FALLBACK_ICON) ? FALLBACK_ICON : null;
  }

  function renderPlugins(lang) {
    const grid = document.querySelector("[data-plugin-grid]");
    if (!grid) return;

    const plugins = Array.isArray(window.NOTCH_PLUGINS) ? window.NOTCH_PLUGINS : null;
    if (!plugins) {
      // data/plugins.gen.js 缺失（例如有人只拷了 index.html）：给出可读的失败态，
      // 而不是留下一个空白网格。
      console.warn("main.js: 未加载 data/plugins.gen.js，插件网格留空");
      const notice = document.createElement("li");
      notice.className = "callout plugins__notice";
      notice.textContent = translationFor("plugins.error", "");
      grid.textContent = "";
      grid.append(notice);
      return;
    }

    for (const counter of document.querySelectorAll("[data-plugin-count]")) {
      counter.textContent = String(plugins.length);
    }

    const fragment = document.createDocumentFragment();
    for (const plugin of plugins) {
      const item = document.createElement("li");
      item.className = "plugin";
      const iconId = resolveIconId(plugin.dir);
      item.innerHTML =
        (iconId
          ? `<svg class="plugin__icon" viewBox="0 0 24 24" aria-hidden="true"><use href="#${iconId}"></use></svg>`
          : "") + "<div><h3></h3><p></p></div>";
      // 名称与描述走 textContent：数据来自仓库内的 Plugin.plist，仍不做 HTML 拼接。
      item.querySelector("h3").textContent = plugin.name[lang];
      item.querySelector("p").textContent = plugin.desc[lang];
      fragment.append(item);
    }

    grid.textContent = "";
    grid.append(fragment);
  }

  // ---- 演示视频 ----------------------------------------------------------

  const demoSyncers = [];

  function setupDemos() {
    const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)");

    for (const video of document.querySelectorAll("[data-demo]")) {
      const button = video.parentElement.querySelector("[data-demo-toggle]");
      if (!button) continue;
      const label = button.querySelector("[data-demo-label]");

      const glyph = document.createElement("span");
      glyph.className = "demo__glyph";
      button.prepend(glyph);

      let userPaused = false;

      const sync = () => {
        const playing = !video.paused && !video.ended;
        glyph.innerHTML = `<svg viewBox="0 0 24 24" aria-hidden="true"><use href="#${playing ? "i-pause" : "i-play"}"></use></svg>`;
        if (label) {
          label.textContent = translationFor(
            playing ? "demos.pause" : "demos.play",
            label.textContent,
          );
        }
      };
      demoSyncers.push(sync);

      button.addEventListener("click", () => {
        if (video.paused) {
          userPaused = false;
          video.play().catch(sync);
        } else {
          userPaused = true;
          video.pause();
        }
      });
      video.addEventListener("play", sync);
      video.addEventListener("pause", sync);
      sync();

      // 自动播放策略：进入视口才播，离开即停；用户手动暂停过就不再自动恢复；
      // prefers-reduced-motion 下完全不自动播放，只留按钮（对应 WCAG 2.2.2 的可暂停要求）。
      const observer = new IntersectionObserver(
        (entries) => {
          for (const entry of entries) {
            if (entry.isIntersecting && !reduceMotion.matches && !userPaused) {
              video.play().catch(() => {});
            } else if (!entry.isIntersecting) {
              video.pause();
            }
          }
        },
        { threshold: 0.35 },
      );
      observer.observe(video);

      reduceMotion.addEventListener("change", (event) => {
        if (event.matches) video.pause();
      });
    }
  }

  // ---- 启动 --------------------------------------------------------------

  function render() {
    applyLang(currentLang);
    renderPlugins(currentLang);
    for (const sync of demoSyncers) sync();
  }

  const toggle = document.querySelector("[data-lang-toggle]");
  if (toggle) {
    toggle.addEventListener("click", () => setLang(currentLang === "zh" ? "en" : "zh"));
  }

  setupDemos();
  render();
})();
