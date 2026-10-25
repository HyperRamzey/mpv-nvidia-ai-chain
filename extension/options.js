/*
 * options.js -- reads and writes chrome.storage.sync, and offers a "Test
 * native host" button that asks the host what it resolved on PATH. That
 * answers the only two failure modes users hit: the host manifest is not
 * installed, or mpv/yt-dlp are not where the host looks.
 */

"use strict";

const DEFAULTS = {
  profile: "ai",
  fullscreen: false,
  extraArgs: "",
  format: "",
};

const $ = (id) => document.getElementById(id);
const statusEl = $("status");
const pingEl = $("ping");

function setStatus(text, kind) {
  statusEl.textContent = text;
  statusEl.className = kind || "";
  if (!text) return;
  if (kind !== "ok") return;
  setTimeout(() => {
    if (statusEl.className === "ok") setStatus("");
  }, 2500);
}

function showPing(obj) {
  pingEl.style.display = "block";
  if (!obj.ok) {
    pingEl.textContent = "host error: " + obj.error;
    return;
  }
  const lines = [
    "host        " + obj.host,
    "python      " + obj.python,
    "PATH        " + obj.path,
    "mpv-ai      " + (obj.tools["mpv-ai"] || "(missing)"),
    "mpv-nr      " + (obj.tools["mpv-nr"] || "(missing)"),
    "mpv         " + (obj.tools["mpv"] || "(missing)"),
    "yt-dlp      " + (obj.tools["yt-dlp"] || "(missing)"),
    "log         " + obj.log,
  ];
  pingEl.textContent = lines.join("\n");
}

async function load() {
  const s = await chrome.storage.sync.get(DEFAULTS);
  $("profile").value = s.profile;
  $("fullscreen").checked = !!s.fullscreen;
  $("extraArgs").value = s.extraArgs || "";
  $("format").value = s.format || "";
}

async function save() {
  const value = {
    profile: $("profile").value,
    fullscreen: $("fullscreen").checked,
    extraArgs: $("extraArgs").value.trim(),
    format: $("format").value.trim(),
  };
  await chrome.storage.sync.set(value);
  setStatus("saved", "ok");
}

function test() {
  setStatus("contacting host...");
  pingEl.style.display = "none";
  chrome.runtime.sendMessage({ type: "ping" }, (reply) => {
    const err = chrome.runtime.lastError;
    if (err) {
      setStatus("no reply from the extension background worker", "err");
      showPing({ ok: false, error: err.message });
      return;
    }
    if (!reply) {
      setStatus("empty reply", "err");
      showPing({ ok: false, error: "empty reply" });
      return;
    }
    if (reply.ok) {
      const missing = Object.entries(reply.tools)
        .filter(([, p]) => !p)
        .map(([name]) => name);
      setStatus(
        missing.length ? "host ok, missing: " + missing.join(", ") : "host ok",
        missing.length ? "err" : "ok"
      );
    } else {
      setStatus("host error", "err");
    }
    showPing(reply);
  });
}

$("save").addEventListener("click", () => {
  save().catch((e) => setStatus(String(e), "err"));
});
$("test").addEventListener("click", test);

load().catch((e) => setStatus(String(e), "err"));
