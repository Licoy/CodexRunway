import { readFileSync } from "node:fs";

const analysisSchema = JSON.parse(readFileSync(
  new URL("../schemas/grok-analysis.schema.json", import.meta.url),
  "utf8",
));
const LOOPBACK_HOSTS = new Set(["localhost", "127.0.0.1", "[::1]"]);

const CLASSIFY_SYSTEM_PROMPT = [
  "You classify Codex / ChatGPT Work quota announcements from pre-fetched @thsottiaux posts.",
  "Only posts authored by @thsottiaux (Tibo) are valid event evidence.",
  "Parent/quoted tweets by other users are context only; never emit events for non-@thsottiaux authors.",
  "Classify EVERY distinct relevant candidate post as its own event. Newest announcedAt first.",
  "Never invent post IDs or URLs; use only candidates supplied in the user message.",
  "reset_completed: usage limits HAVE been / ARE being reset. Examples: \"I've reset usage limits\", \"I've reset usage limits for all ChatGPT Work and Codex users\", \"usage limits have been reset\", \"Hello people of Sol! I've reset...\".",
  "A long multi-paragraph post is still reset_completed when it contains an explicit completed-reset claim.",
  "reset_scheduled: upcoming reset not yet completed. Always set effectiveAt.",
  "Examples: \"I'm feeling like a limit reset\" + \"in a few hours\"; replies deciding next reset timing.",
  "\"in a few hours\" / \"when I'm back\": effectiveAt = announcedAt + 3 hours.",
  "Calendar-only day (e.g. July 31): effectiveAt = that date at 12:00:00.000Z.",
  "If a reply discusses deciding resets and parentContext/snippet names a future day (e.g. 31 July), emit reset_scheduled for that day at 12:00:00.000Z unless clearly rejected.",
  "Example: snippet \"I read your tweets and decide accordingly\" with parentContext mentioning July 31 → reset_scheduled effectiveAt that July 31 at 12:00:00.000Z.",
  "If upcoming reset is clear but no timing cue exists, reset_scheduled with effectiveAt = announcedAt + 3 hours.",
  "banked_reset / limit_increase / uncertain only when appropriate; do not use uncertain to hide a clear completed or scheduled reset.",
  "Jokes with no operational claim are not events.",
  "Preserve each post's actual publication time in announcedAt (ISO).",
  "For completed resets, set effectiveAt only when the post gives a distinct reset time different from announcement.",
  "sourceUrl must be https://x.com/thsottiaux/status/<postId>.",
  "Do not quote long post text; return only the requested classification fields.",
].join(" ");

/**
 * Phase 1: free-form tool search to collect candidate post IDs/snippets.
 * Kept short so Cloudflare HTTP proxies do not 504.
 */
export function buildDiscoveryRequest({ model, now = new Date() }) {
  assertNonEmpty(model, "GROK_MODEL");
  const toDate = isoDate(now);
  const fromDate = isoDate(new Date(now.getTime() - (72 * 60 * 60 * 1_000)));
  const todayUTC = toDate;
  const nowISO = now.toISOString();

  return {
    model,
    store: false,
    max_tool_calls: 8,
    max_output_tokens: 3_000,
    parallel_tool_calls: false,
    tool_choice: "required",
    reasoning: { effort: "low" },
    input: [
      {
        role: "user",
        content: [
          `Current UTC time: ${nowISO}. UTC today: ${todayUTC}.`,
          `Find @thsottiaux X posts AND replies from ${fromDate} through ${toDate} about Codex / ChatGPT Work / Sol usage-limit resets or schedules.`,
          "Priority: UTC today completed resets first, then Tibo replies about next reset timing, then older posts.",
          "Must run multiple tool searches for these phrases:",
          "\"I've reset usage limits\", \"Hello people of Sol\", \"usage limits have been reset\", \"feeling like a limit reset\",",
          "\"I read your tweets and decide accordingly\", \"decide accordingly\", reset button, \"next reset\".",
          "Also search replies: from:thsottiaux filter:replies reset OR limits OR decide.",
          "Use both x_search and web_search. Prefer x.com/thsottiaux/status URLs.",
          "If a reply sits under a thread predicting a future reset day (e.g. 31 July), still include that reply.",
          "Return ONLY a JSON array of objects:",
          "{\"postId\",\"url\",\"announcedAt\",\"snippet\",\"kindGuess\",\"parentContext\"}",
          "kindGuess one of: reset_completed, reset_scheduled, banked_reset, limit_increase, uncertain, other.",
          "parentContext: short note if the parent/quoted post names a future reset date.",
          "announcedAt as ISO if known, else best-effort. snippet: short paraphrase or key clause (not full essay).",
          "Include every distinct matching @thsottiaux post ID you find — do not stop after the first completed reset.",
        ].join(" "),
      },
    ],
    tools: [
      {
        type: "x_search",
        allowed_x_handles: ["thsottiaux"],
        from_date: fromDate,
        to_date: toDate,
        enable_image_understanding: false,
        enable_video_understanding: false,
      },
      {
        type: "web_search",
        enable_image_understanding: false,
      },
    ],
  };
}

/**
 * Optional follow-up discovery for short schedule-decision replies that main
 * search often misses after a large completed-reset post.
 */
export function buildScheduleReplyDiscoveryRequest({ model, now = new Date() }) {
  assertNonEmpty(model, "GROK_MODEL");
  const toDate = isoDate(now);
  const fromDate = isoDate(new Date(now.getTime() - (48 * 60 * 60 * 1_000)));
  const nowISO = now.toISOString();

  return {
    model,
    store: false,
    max_tool_calls: 6,
    max_output_tokens: 2_000,
    parallel_tool_calls: false,
    tool_choice: "required",
    reasoning: { effort: "low" },
    input: [
      {
        role: "user",
        content: [
          `Current UTC time: ${nowISO}.`,
          `Find @thsottiaux replies from ${fromDate} through ${toDate} about deciding the next Codex/ChatGPT Work reset timing.`,
          "Especially the reply: \"I read your tweets and decide accordingly\".",
          "Include parent/quoted context when it names a future day (e.g. 31 July).",
          "Use x_search and web_search. Return ONLY a JSON array of",
          "{\"postId\",\"url\",\"announcedAt\",\"snippet\",\"kindGuess\",\"parentContext\"}.",
          "kindGuess should usually be reset_scheduled when the reply is about future reset timing.",
        ].join(" "),
      },
    ],
    tools: [
      {
        type: "x_search",
        allowed_x_handles: ["thsottiaux"],
        from_date: fromDate,
        to_date: toDate,
        enable_image_understanding: false,
        enable_video_understanding: false,
      },
      {
        type: "web_search",
        enable_image_understanding: false,
      },
    ],
  };
}

/**
 * Phase 2: structured classification of discovery candidates (no tools).
 */
export function buildClassificationRequest({ model, now = new Date(), candidates = [] }) {
  assertNonEmpty(model, "GROK_MODEL");
  if (!Array.isArray(candidates)) {
    throw new Error("candidates must be an array");
  }
  const nowISO = now.toISOString();
  const todayUTC = isoDate(now);

  return {
    model,
    store: false,
    max_output_tokens: 4_000,
    parallel_tool_calls: false,
    tool_choice: "none",
    reasoning: { effort: "low" },
    input: [
      { role: "system", content: CLASSIFY_SYSTEM_PROMPT },
      {
        role: "user",
        content: [
          `Current UTC time: ${nowISO}. UTC today: ${todayUTC}.`,
          "Classify the following candidate @thsottiaux posts into events.",
          "Return one event per relevant post. Omit pure jokes and unrelated posts.",
          "Candidates JSON:",
          JSON.stringify(candidates),
        ].join("\n"),
      },
    ],
    text: {
      format: {
        type: "json_schema",
        name: "hasreset_analysis",
        schema: analysisSchema,
        strict: true,
      },
    },
  };
}

/** @deprecated Use buildDiscoveryRequest / buildClassificationRequest. Kept for tests. */
export function buildGrokRequest({ model, now = new Date(), focus = "full" }) {
  // Back-compat: map old dual-focus search into discovery request.
  void focus;
  return buildDiscoveryRequest({ model, now });
}

export function responsesURL(baseURL) {
  return responsesEndpointURL(baseURL, { websocket: false });
}

export function responsesWebSocketURL(baseURL) {
  return responsesEndpointURL(baseURL, { websocket: true });
}

/**
 * Build a WebSocket `response.create` envelope from the HTTP Responses body.
 * xAI WebSocket mode streams events; omit transport-only fields.
 */
export function buildWebSocketCreateMessage(request) {
  if (!request || typeof request !== "object" || Array.isArray(request)) {
    throw new Error("Grok request body is required");
  }
  const {
    stream: _stream,
    background: _background,
    ...rest
  } = request;
  return {
    type: "response.create",
    ...rest,
    input: normalizeWebSocketInput(rest.input),
  };
}

function responsesEndpointURL(baseURL, { websocket }) {
  assertNonEmpty(baseURL, "GROK_API_BASE_URL");
  const parsed = new URL(baseURL);
  const secure = parsed.protocol === "https:" || parsed.protocol === "wss:";
  const localHTTP = (parsed.protocol === "http:" || parsed.protocol === "ws:")
    && LOOPBACK_HOSTS.has(parsed.hostname);
  if (!secure && !localHTTP) {
    throw new Error("GROK_API_BASE_URL must use HTTPS unless it is loopback HTTP");
  }
  if (parsed.username || parsed.password || parsed.search || parsed.hash) {
    throw new Error("GROK_API_BASE_URL must not contain credentials, a query, or a fragment");
  }

  const segments = parsed.pathname.split("/").filter(Boolean);
  if (segments.length === 0) {
    parsed.pathname = "/v1/responses";
  } else if (!/^v[0-9]+$/i.test(segments.at(-1) ?? "")) {
    throw new Error("GROK_API_BASE_URL must end with an API version directory");
  } else {
    parsed.pathname = `${parsed.pathname.replace(/\/+$/, "")}/responses`;
  }

  if (websocket) {
    parsed.protocol = secure ? "wss:" : "ws:";
  } else {
    parsed.protocol = secure || parsed.protocol === "wss:" ? "https:" : "http:";
  }
  return parsed;
}

function normalizeWebSocketInput(input) {
  if (!Array.isArray(input)) return input;
  return input.map((item) => {
    if (!item || typeof item !== "object" || Array.isArray(item)) return item;
    if (item.type) return item;
    if (typeof item.role !== "string") return item;
    if (typeof item.content === "string") {
      return {
        type: "message",
        role: item.role,
        content: [{ type: "input_text", text: item.content }],
      };
    }
    return { type: "message", ...item };
  });
}

function assertNonEmpty(value, name) {
  if (typeof value !== "string" || value.trim() === "") {
    throw new Error(`${name} is required`);
  }
}

function isoDate(value) {
  if (!(value instanceof Date) || Number.isNaN(value.getTime())) {
    throw new Error("now must be a valid Date");
  }
  return value.toISOString().slice(0, 10);
}
