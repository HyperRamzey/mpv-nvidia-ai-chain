/*
 * background.js -- MV3 service worker for the mpv AI chain extension.
 *
 * It does one thing: take a URL the browser can see, hand it to the native
 * messaging host, and let the host start mpv detached. All policy (which mpv
 * wrapper, extra arguments, yt-dlp format) is stored in chrome.storage.sync
 * and re-read on every request, so changing it in the options page takes
 * effect on the next click without reloading the extension.
 *
 * Entry points:
 *   * toolbar icon          -> current tab
 *   * Alt+Shift+M           -> current tab
 *   * right-click menu      -> page / link / video / audio / selected URL
 *
 * The badge is the only feedback channel: OK on launch, ! on failure (with
 * the reason in the service-worker console).
 */

"use strict";

const HOST_NAME = "com.hyperramzey.mpv_ai";
const MENU_ROOT = "mpv-ai-send";
const BADGE_MS = 3000;

const DEFAULTS = {
  profile: "ai",
  fullscreen: false,
  extraArgs: "",
  format: "",
};

/** Options with defaults filled in. */
async function settings() {
  const stored = await chrome.storage.sync.get(DEFAULTS);
  return Object.assign({}, DEFAULTS, stored);
}

/**
 * One-shot native message. The host process starts, answers, and exits; no
 * long-lived port is kept, so a host crash can never wedge the extension.
 */
function sendNative(message) {
  return new Promise((resolve, reject) => {
    chrome.runtime.sendNativeMessage(HOST_NAME, message, (reply) => {
      const err = chrome.runtime.lastError;
      if (err) {
        reject(new Error(err.message));
        return;
      }
      if (!reply) {
        reject(new Error("native host returned no reply"));
        return;
      }
      if (!reply.ok) {
        reject(new Error(reply.error || "native host rejected the request"));
        return;
      }
      resolve(reply);
    });
  });
}

let badgeTimer = null;

async function badge(text, color) {
  try {
    await chrome.action.setBadgeBackgroundColor({ color });
    await chrome.action.setBadgeText({ text });
  } catch (e) {
    // Action API is unavailable in some pinned builds; the console still has
    // the real result.
  }
  if (badgeTimer) clearTimeout(badgeTimer);
  badgeTimer = setTimeout(() => {
    chrome.action.setBadgeText({ text: "" }).catch(() => {});
  }, BADGE_MS);
}

/** Start playback and report through the badge. */
async function play(url, opts) {
  opts = opts || {};
  if (!/^https?:\/\//i.test(url || "")) {
    throw new Error("not an http(s) URL: " + url);
  }
  const s = await settings();
  const reply = await sendNative({
    cmd: "play",
    url,
    profile: opts.profile || s.profile,
    fullscreen: opts.fullscreen === undefined ? s.fullscreen : opts.fullscreen,
    args: s.extraArgs,
    format: s.format,
    title: opts.title || "",
  });
  console.info("[mpv-ai] started pid " + reply.pid + ": " + reply.argv.join(" "));
  await badge("OK", "#2f9e44");
  return reply;
}

/** Keep every entry point from throwing into the void. */
async function guarded(what, fn) {
  try {
    return await fn();
  } catch (e) {
    console.error("[mpv-ai] " + what + " failed:", e);
    await badge("!", "#c92a2a");
    return null;
  }
}

/** The URL a context-menu click is about, most specific first. */
function pickUrl(info, tab) {
  if (info.linkUrl) return info.linkUrl;
  if (info.srcUrl) return info.srcUrl;
  if (info.selectionText) {
    const m = info.selectionText.match(/https?:\/\/[^\s"'<>]+/);
    if (m) return m[0];
  }
  return tab && tab.url ? tab.url : "";
}

function buildMenus() {
  chrome.contextMenus.removeAll(() => {
    const contexts = ["page", "link", "video", "audio", "selection"];
    chrome.contextMenus.create({
      id: MENU_ROOT,
      title: "Send to mpv",
      contexts,
    });
    const items = [
      ["ai", "AI chain (VSR + TrueHDR + NR + FG)"],
      ["nr", "Noise reduction only"],
      ["plain", "Plain mpv"],
    ];
    for (const [id, title] of items) {
      chrome.contextMenus.create({
        id: MENU_ROOT + "/" + id,
        parentId: MENU_ROOT,
        title,
        contexts,
      });
    }
  });
}

chrome.runtime.onInstalled.addListener(buildMenus);
chrome.runtime.onStartup.addListener(buildMenus);

chrome.contextMenus.onClicked.addListener((info, tab) => {
  const profile = String(info.menuItemId).split("/")[1] || "ai";
  const url = pickUrl(info, tab);
  guarded("context menu", () =>
    play(url, { profile, title: tab && tab.title })
  );
});

chrome.action.onClicked.addListener((tab) => {
  guarded("toolbar click", () =>
    play(tab && tab.url, { title: tab && tab.title })
  );
});

chrome.commands.onCommand.addListener((command) => {
  if (command !== "send-to-mpv") return;
  chrome.tabs.query({ active: true, currentWindow: true }).then(([tab]) => {
    guarded("keyboard command", () =>
      play(tab && tab.url, { title: tab && tab.title })
    );
  });
});

// The options page asks for a host round trip so the user can tell a missing
// native host from a missing mpv.
chrome.runtime.onMessage.addListener((msg, _sender, respond) => {
  if (!msg || msg.type !== "ping") return false;
  sendNative({ cmd: "ping" })
    .then((r) => respond(Object.assign({ ok: true }, r)))
    .catch((e) => respond({ ok: false, error: e.message }));
  return true;
});
