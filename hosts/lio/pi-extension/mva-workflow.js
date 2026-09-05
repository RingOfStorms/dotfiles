const ENTRY = "mva-workflow-state";
const MAX_AUTO_CONTINUES = 8;

const emptyState = () => ({
  version: 1,
  task: "",
  goal: "",
  todos: [],
  activeTodo: null,
  completed: [],
  blockers: [],
  verification: [],
  mode: "work",
  status: "idle",
  autoContinues: 0,
});

let state = emptyState();
let lastPrompt = "";
let lastPersisted = "";

function loadState(ctx) {
  const entries = ctx.sessionManager.getEntries();
  for (const entry of entries) {
    if (entry.type === "custom" && entry.customType === ENTRY && entry.data) {
      state = { ...emptyState(), ...entry.data };
    }
  }
}

function persist(pi) {
  const serialized = JSON.stringify(state);
  if (serialized !== lastPersisted) {
    pi.appendEntry(ENTRY, state);
    lastPersisted = serialized;
  }
}

function todoText(todo, index) {
  const marker = todo.status === "done" ? "x" : todo.status === "blocked" ? "!" : " ";
  return `${index + 1}. [${marker}] ${todo.text}`;
}

function workflowPrompt() {
  const todos = state.todos.length ? state.todos.map(todoText).join("\n") : "(none)";
  const completed = state.completed.length ? state.completed.map((x) => `- ${x}`).join("\n") : "(none)";
  const blockers = state.blockers.length ? state.blockers.map((x) => `- ${x}`).join("\n") : "(none)";
  const verification = state.verification.length ? state.verification.map((x) => `- ${x}`).join("\n") : "(none)";
  return `[MVA session workflow — session-scoped; do not infer state from other sessions]
Task: ${state.task || "(not set)"}
Goal: ${state.goal || "(not set)"}
Mode: ${state.mode}
Status: ${state.status}
Active todo: ${state.activeTodo ?? "(none)"}
Todos:
${todos}
Completed:
${completed}
Blockers:
${blockers}
Verification:
${verification}

Workflow rules:
- Keep this state current with the mva_workflow tool.
- Work one actionable todo at a time and verify changes.
- Do not invent a todo when none exists; stop and report instead.
- Stop and report when blocked, ambiguous, verification fails, or the bounded continuation limit is reached.
- In plan mode, inspect and propose/update todos only; do not edit files or run shell commands.`;
}

function textOf(message) {
  if (!message || !Array.isArray(message.content)) return "";
  return message.content.filter((part) => part.type === "text").map((part) => part.text).join("\n");
}

export default function mvaWorkflow(pi) {
  pi.on("session_start", (_event, ctx) => {
    loadState(ctx);
    lastPersisted = JSON.stringify(state);
  });

  pi.on("before_agent_start", (event) => {
    if (event.prompt && event.prompt !== lastPrompt) {
      lastPrompt = event.prompt;
      if (!state.task) state.task = event.prompt;
      if (state.status === "idle") state.status = "active";
      persist(pi);
    }
    return { systemPrompt: `${event.systemPrompt}\n\n${workflowPrompt()}` };
  });

  pi.on("context", (event) => {
    // Keep only the current user request and the active tool exchange. Never
    // replay unrelated transcript messages from this or another session.
    let latestUser = null;
    for (const message of event.messages) {
      if (message.role === "user") latestUser = message;
    }
    const latestUserText = textOf(latestUser);
    const suffix = [];
    let inActiveExchange = false;
    for (let i = event.messages.length - 1; i >= 0; i--) {
      const message = event.messages[i];
      if (message.role === "toolResult") {
        inActiveExchange = true;
        suffix.unshift(message);
      } else if (inActiveExchange && message.role === "assistant") {
        suffix.unshift(message);
        break;
      } else if (message.role === "user") {
        break;
      }
    }
    const workflow = { role: "user", content: [{ type: "text", text: workflowPrompt() }] };
    const current = latestUserText && latestUserText !== workflowPrompt() ? [latestUser] : [];
    return { messages: [workflow, ...current, ...suffix] };
  });

  pi.registerCommand("plan", {
    description: "Enter Pi-only MVA planning mode",
    handler: async (_args, ctx) => {
      state.mode = "plan";
      state.status = "planning";
      persist(pi);
      ctx.ui.notify("MVA planning mode enabled; writes and shell are prohibited.", "info");
      pi.sendUserMessage("Review the task, inspect as needed, and update the unified todos. Do not edit files or run shell commands.", { deliverAs: "followUp" });
    },
  });

  pi.registerTool({
    name: "mva_workflow",
    label: "mva workflow",
    description: "Update the current session's unified MVA task, goal, todos, progress, blockers, and verification. State is persisted only in this Pi session.",
    promptSnippet: "Update session-scoped MVA workflow state",
    parameters: {
      type: "object",
      properties: {
        task: { type: "string" },
        goal: { type: "string" },
        mode: { type: "string", enum: ["work", "plan"] },
        status: { type: "string", enum: ["idle", "active", "planning", "blocked", "done", "stopped"] },
        activeTodo: { type: ["string", "null"] },
        addTodos: { type: "array", items: { type: "string" } },
        completeTodos: { type: "array", items: { type: "string" } },
        completed: { type: "array", items: { type: "string" } },
        blockers: { type: "array", items: { type: "string" } },
        verification: { type: "array", items: { type: "string" } },
      },
      additionalProperties: false,
    },
    async execute(_id, input) {
      if (input.task !== undefined) state.task = input.task;
      if (input.goal !== undefined) state.goal = input.goal;
      if (input.mode !== undefined) state.mode = input.mode;
      if (input.status !== undefined) state.status = input.status;
      if (input.activeTodo !== undefined) state.activeTodo = input.activeTodo;
      for (const text of input.addTodos ?? []) state.todos.push({ text, status: "pending" });
      for (const text of input.completeTodos ?? []) {
        const todo = state.todos.find((x) => x.text === text);
        if (todo) todo.status = "done";
        if (!state.completed.includes(text)) state.completed.push(text);
      }
      if (input.completed) state.completed = input.completed;
      if (input.blockers) state.blockers = input.blockers;
      if (input.verification) state.verification = input.verification;
      if (!state.activeTodo) state.activeTodo = state.todos.find((x) => x.status === "pending")?.text ?? null;
      persist(pi);
      return { content: [{ type: "text", text: workflowPrompt() }] };
    },
  });

  pi.on("agent_settled", (_event, ctx) => {
    const pending = state.todos.some((x) => x.status === "pending");
    if (state.mode === "plan" || state.status === "blocked" || state.status === "stopped" || !pending) return;
    if (state.autoContinues >= MAX_AUTO_CONTINUES) {
      state.status = "stopped";
      persist(pi);
      ctx.ui.notify("MVA continuation limit reached; stopped and reported.", "warning");
      return;
    }
    state.autoContinues += 1;
    persist(pi);
    pi.sendUserMessage("Continue with the active actionable todo. If blocked or ambiguous, update mva_workflow and stop with a report.", { deliverAs: "followUp" });
  });
}
