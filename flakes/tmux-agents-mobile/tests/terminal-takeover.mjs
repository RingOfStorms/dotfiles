import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";

// Run against a disposable tmux-agents-mobile server and a Chrome CDP endpoint.
// This uses the real xterm parser, WebSocket, PTY, shell and Vim, not mocks.
export async function terminalTakeover(browser, baseURL) {
  const context = await browser.createBrowserContext();
  const a = await context.newPage();
  const frames = async (page) => {
    const cdp = await page.createCDPSession();
    const sent = [], control = [], urls = [];
    await cdp.send("Network.enable");
    cdp.on("Network.webSocketCreated", ({ url }) => urls.push(url));
    cdp.on("Network.webSocketFrameSent", ({ response }) => {
      if (response.opcode === 2) sent.push(Buffer.from(response.payloadData, "base64").toString());
    });
    cdp.on("Network.webSocketFrameReceived", ({ response }) => {
      if (response.opcode === 1) control.push(JSON.parse(response.payloadData));
    });
    return { cdp, sent, control, urls };
  };
  const waitText = (page, text) => page.waitForFunction(
    (text) => document.querySelector(".xterm-rows")?.innerText.includes(text),
    { timeout: 10000 }, text,
  );
  const input = (page, text) => page.type(".xterm-helper-textarea", text);
  let monitor;
  try {
    await a.goto(new URL("/term", baseURL).href);
    await a.waitForFunction(() => localStorage.getItem("tam.term.id") &&
      document.querySelector(".xterm-rows")?.innerText.trim(), { timeout: 10000 });
    await input(a, 'printf "start-%s\\n" "$((20+3))"\n');
    await waitText(a, "start-23");
    monitor = await frames(a);

    const b = await context.newPage();
    const other = await frames(b);
    await b.goto(new URL("/term", baseURL).href);
    await waitText(b, "start-23");
    await a.waitForFunction(() => !document.querySelector("#term-status").hidden,
      { polling: "mutation", timeout: 10000 });
    await input(b, "vim -Nu NONE -i NONE -n\n");
    await b.waitForFunction(() => document.querySelector(".xterm-rows")?.innerText.includes("All"),
      { timeout: 10000 });
    assert.ok(other.sent.some((data) => /\x1b\[\d+;\d+R/.test(data)),
      "fresh Vim must receive terminal query replies");
    await input(b, "iTAKEOVER-VIM");
    await waitText(b, "TAKEOVER-VIM");
    await b.click("[data-send=esc]");
    await input(b, ":q!\n");
    await b.waitForFunction(() => !document.querySelector(".xterm-rows").innerText.includes("TAKEOVER-VIM"),
      { timeout: 10000 });
    await input(b, 'printf "returned-%s\\n" "$((31+4))"\n');
    await waitText(b, "returned-35");

    // A still has its screen and nonzero offset. No reload: this is takeover-back.
    monitor.sent.length = 0;
    monitor.control.length = 0;
    await a.bringToFront();
    await a.$eval("#term-status", (el) => el.click());
    await waitText(a, "returned-35");
    assert.ok(monitor.urls.some((url) => Number(new URL(url).searchParams.get("from")) > 0),
      "takeover-back must resume a nonzero screen offset");
    assert.deepEqual(monitor.sent, [], "takeover history must not inject query replies into the shell");
    const takeoverInputFrames = monitor.sent.length;
    await input(a, 'printf "clean-%s\\n" "$((4*9))"\n');
    await waitText(a, "clean-36");
    return { takeoverInputFrames, controls: [...monitor.control], shellResult: "clean-36" };
  } finally {
    // Only this isolated browser context's shell is ended, even on assertion failure.
    await a.evaluate(async () => {
      const id = localStorage.getItem("tam.term.id");
      if (!id) return;
      await new Promise((resolve) => {
        const url = new URL("/term/ws", location.href);
        url.protocol = location.protocol === "https:" ? "wss:" : "ws:";
        url.searchParams.set("id", id);
        const ws = new WebSocket(url);
        const timer = setTimeout(() => { ws.close(); resolve(); }, 2000);
        ws.onmessage = (event) => {
          if (typeof event.data === "string" && JSON.parse(event.data).t === "hello") {
            ws.send(JSON.stringify({ t: "close" }));
          }
        };
        ws.onclose = ws.onerror = () => { clearTimeout(timer); resolve(); };
      });
    }).catch(() => {});
    await context.close();
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const require = createRequire(process.env.TAM_PUPPETEER_PREFIX
    ? pathToFileURL(`${process.env.TAM_PUPPETEER_PREFIX}/package.json`)
    : import.meta.url);
  const puppeteer = require("puppeteer-core");
  const browser = await puppeteer.connect({ browserURL: process.env.CHROME_CDP_URL || "http://127.0.0.1:9333" });
  try {
    console.log(await terminalTakeover(browser, process.env.TAM_URL || "http://127.0.0.1:8199"));
  } finally {
    await browser.disconnect();
  }
}
