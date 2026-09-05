const WORKFLOW_ENTRY = "mva-workflow-state";
const MAX_DISPLAY = 12000;
const MAX_LINES = 400;
const SENSITIVE = /key|token|secret|password|authorization|cookie/i;

let workflow = null;
let lastRequest = null;
let lastUser = "";
let turnStarted = 0;
let llmStarted = 0;
let llmMs = 0;
let turnCount = 0;

function textOf(message) {
  if (!message || !Array.isArray(message.content)) return "";
  return message.content
    .filter((part) => part.type === "text")
    .map((part) => part.text)
    .join("\n");
}

function redact(value, depth = 0) {
  if (depth > 8) return "[depth limited]";
  if (Array.isArray(value)) return value.map((item) => redact(item, depth + 1));
  if (!value || typeof value !== "object") return value;
  const result = {};
  for (const [key, child] of Object.entries(value)) {
    result[key] = SENSITIVE.test(key) ? "[redacted]" : redact(child, depth + 1);
  }
  return result;
}

function display(value) {
  const raw = typeof value === "string" ? value : JSON.stringify(redact(value), null, 2);
  return raw.length > MAX_DISPLAY ? `${raw.slice(0, MAX_DISPLAY)}\n… [truncated]` : raw;
}

function workflowText() {
  if (!workflow) return "No mva-workflow-state entry has been recorded in this session.";
  const todos = (workflow.todos ?? []).map((todo, i) => {
    const marker = todo.status === "done" ? "x" : todo.status === "blocked" ? "!" : " ";
    return `${i + 1}. [${marker}] ${todo.text}`;
  });
  return [
    `Task: ${workflow.task || "(not set)"}`,
    `Goal: ${workflow.goal || "(not set)"}`,
    `Mode: ${workflow.mode || "(unknown)"}`,
    `Status: ${workflow.status || "(unknown)"}`,
    `Active todo: ${workflow.activeTodo ?? "(none)"}`,
    "",
    "Todos:",
    ...(todos.length ? todos : ["(none)"]),
    "",
    "Blockers:",
    ...((workflow.blockers ?? []).map((item) => `- ${item}`) || ["(none)"]),
  ].join("\n");
}

class TextOverlay {
  constructor(title, body, theme, done) {
    this.title = title;
    this.lines = body.split("\n");
    this.theme = theme;
    this.done = done;
    this.offset = 0;
    this.width = 92;
    this.focused = false;
  }
  handleInput(data) {
    if (data === "\u001b" || data === "q" || data === "Q") return this.done();
    if (data === "\r" || data === "\n") return this.done();
    if (data === "\u001b[A" || data === "k") this.offset = Math.max(0, this.offset - 1);
    if (data === "\u001b[B" || data === "j") this.offset = Math.min(Math.max(0, this.lines.length - 1), this.offset + 1);
    if (data === "\u001b[5~") this.offset = Math.max(0, this.offset - 15);
    if (data === "\u001b[6~") this.offset = Math.min(Math.max(0, this.lines.length - 1), this.offset + 15);
  }
  render(width) {
    const w = Math.min(this.width, Math.max(40, width - 4));
    const inner = w - 2;
    const pad = (line) => line.slice(0, inner).padEnd(inner, " ");
    const row = (line) => this.theme.fg("border", "│") + pad(line) + this.theme.fg("border", "│");
    const height = 24;
    const visible = this.lines.slice(this.offset, this.offset + height - 5);
    return [
      this.theme.fg("border", `╭${"─".repeat(inner)}╮`),
      row(` ${this.theme.fg("accent", this.title)}`),
      row(` ${this.theme.fg("dim", "↑↓/PgUp/PgDn scroll • Esc/q close")}`),
      ...visible.map(row),
      ...Array(Math.max(0, height - 5 - visible.length)).fill(row("")),
      row(` ${this.theme.fg("dim", `line ${this.offset + 1}/${Math.max(1, this.lines.length)}`)}`),
      this.theme.fg("border", `╰${"─".repeat(inner)}╯`),
    ];
  }
  invalidate() {}
  dispose() {}
}

async function show(ctx, title, body) {
  if (!ctx.hasUI) return;
  await ctx.ui.custom((_tui, theme, _keys, done) => new TextOverlay(title, body, theme, done), { overlay: true });
}

function setStatus(ctx, text) {
  if (ctx.hasUI) ctx.ui.setStatus("pi-josh-utils", text);
}

export default function piJoshUtils(pi) {
  pi.on("session_start", (_event, ctx) => {
    for (const entry of ctx.sessionManager.getEntries()) {
      if (entry.type === "custom" && entry.customType === WORKFLOW_ENTRY) workflow = entry.data;
    }
    setStatus(ctx, "josh-utils ready");
  });

  pi.on("context", (event) => {
    for (let i = event.messages.length - 1; i >= 0; i--) {
      if (event.messages[i].role === "user") {
        lastUser = textOf(event.messages[i]);
        break;
      }
    }
  });

  pi.on("before_agent_start", (event) => {
    if (event.prompt) lastUser = event.prompt;
  });

  pi.on("before_provider_request", (event) => {
    lastRequest = redact(event.payload);
    llmStarted = Date.now();
  });

  pi.on("after_provider_response", () => {
    if (llmStarted) llmMs += Date.now() - llmStarted;
    llmStarted = 0;
  });

  pi.on("turn_start", (_event, ctx) => {
    turnStarted = Date.now();
    llmMs = 0;
    turnCount++;
    setStatus(ctx, `turn ${turnCount} running`);
  });

  pi.on("turn_end", (_event, ctx) => {
    const total = turnStarted ? Date.now() - turnStarted : 0;
    setStatus(ctx, `turn ${turnCount}: ${(total / 1000).toFixed(1)}s total • ${(llmMs / 1000).toFixed(1)}s LLM`);
  });

  pi.registerCommand("josh-context", { description: "Inspect maintained MVA workflow context", handler: (_args, ctx) => show(ctx, "Maintained context", workflowText()) });
  pi.registerCommand("josh-request", { description: "Inspect the last redacted provider request", handler: (_args, ctx) => show(ctx, "Last provider request (redacted)", lastRequest ? display(lastRequest) : "No provider request captured yet.") });
  pi.registerCommand("josh-last-user", { description: "Inspect the last user message", handler: (_args, ctx) => show(ctx, "Last user message", lastUser || "No user message captured yet.") });

  pi.registerShortcut("ctrl+alt+c", { description: "Show maintained context", handler: (_event, ctx) => show(ctx, "Maintained context", workflowText()) });
  pi.registerShortcut("ctrl+alt+r", { description: "Show last provider request", handler: (_event, ctx) => show(ctx, "Last provider request (redacted)", lastRequest ? display(lastRequest) : "No provider request captured yet.") });
  pi.registerShortcut("ctrl+alt+u", { description: "Show last user message", handler: (_event, ctx) => show(ctx, "Last user message", lastUser || "No user message captured yet.") });
}
