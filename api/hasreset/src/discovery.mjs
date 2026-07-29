/**
 * Extract @thsottiaux candidate posts from a free-form discovery Responses payload.
 */

const STATUS_URL_RE = /https?:\/\/(?:www\.)?(?:x|twitter)\.com\/(?:thsottiaux|i)\/status\/(\d{1,30})/gi;
const POST_ID_RE = /\b(\d{15,30})\b/g;

export function extractDiscoveryCandidates(response) {
  const byId = new Map();
  const text = extractOutputText(response);
  const annotationUrls = collectAnnotationUrls(response);

  for (const url of annotationUrls) {
    const postId = postIdFromUrl(url);
    if (!postId) continue;
    upsert(byId, {
      postId,
      url: `https://x.com/thsottiaux/status/${postId}`,
      announcedAt: null,
      snippet: "",
      kindGuess: "uncertain",
      parentContext: "",
    });
  }

  for (const match of text.matchAll(STATUS_URL_RE)) {
    const postId = match[1];
    upsert(byId, {
      postId,
      url: `https://x.com/thsottiaux/status/${postId}`,
      announcedAt: null,
      snippet: "",
      kindGuess: "uncertain",
      parentContext: "",
    });
  }

  for (const item of parseCandidateArray(text)) {
    const postId = normalizePostId(item.postId ?? item.post_id ?? item.id);
    if (!postId) continue;
    upsert(byId, {
      postId,
      url: typeof item.url === "string" && item.url.includes(postId)
        ? item.url
        : `https://x.com/thsottiaux/status/${postId}`,
      announcedAt: normalizeMaybeDate(item.announcedAt ?? item.announced_at ?? item.time),
      snippet: typeof item.snippet === "string"
        ? item.snippet.slice(0, 500)
        : (typeof item.text === "string" ? item.text.slice(0, 500) : ""),
      kindGuess: typeof item.kindGuess === "string"
        ? item.kindGuess
        : (typeof item.kind === "string" ? item.kind : "uncertain"),
      parentContext: typeof item.parentContext === "string"
        ? item.parentContext.slice(0, 500)
        : (typeof item.parent_context === "string" ? item.parent_context.slice(0, 500) : ""),
    });
  }

  // Prefer larger snowflake IDs first (newer tweets).
  return [...byId.values()].sort((left, right) => (
    right.postId.padStart(30, "0").localeCompare(left.postId.padStart(30, "0"))
  ));
}

export function discoveryCitationUrls(candidates) {
  return (Array.isArray(candidates) ? candidates : [])
    .map((item) => item?.url || (item?.postId
      ? `https://x.com/thsottiaux/status/${item.postId}`
      : null))
    .filter((url) => typeof url === "string" && url.length > 0);
}

/**
 * Attach discovery citations so parseGrokResponse accepts classified events.
 */
export function attachCandidateCitations(response, candidates) {
  const urls = discoveryCitationUrls(candidates);
  if (!response || typeof response !== "object") {
    return {
      status: "completed",
      citations: urls,
      output: [{
        type: "message",
        content: [{ type: "output_text", text: "{\"events\":[]}", annotations: urls.map((url) => ({ url })) }],
      }],
    };
  }
  const next = structuredClone(response);
  const existing = Array.isArray(next.citations) ? next.citations : [];
  next.citations = [...new Set([...existing, ...urls])];

  // Ensure the final output_text block has annotations for each candidate.
  if (Array.isArray(next.output)) {
    for (let index = next.output.length - 1; index >= 0; index -= 1) {
      const item = next.output[index];
      if (item?.type !== "message") continue;
      if (Array.isArray(item.content)) {
        for (const block of item.content) {
          if (block?.type !== "output_text") continue;
          const annotations = Array.isArray(block.annotations) ? block.annotations : [];
          const seen = new Set(annotations.map((value) => (
            typeof value === "string" ? value : value?.url
          )).filter(Boolean));
          for (const url of urls) {
            if (!seen.has(url)) annotations.push({ url });
          }
          block.annotations = annotations;
          return next;
        }
      }
    }
  }
  return next;
}

function extractOutputText(response) {
  if (!Array.isArray(response?.output)) return "";
  const chunks = [];
  for (const item of response.output) {
    if (item?.type !== "message") continue;
    if (Array.isArray(item.content)) {
      for (const block of item.content) {
        if (block?.type === "output_text" && typeof block.text === "string") {
          chunks.push(block.text);
        }
      }
    } else if (typeof item.content === "string") {
      chunks.push(item.content);
    }
  }
  return chunks.join("\n");
}

function collectAnnotationUrls(response) {
  const urls = [];
  if (Array.isArray(response?.citations)) {
    for (const value of response.citations) {
      if (typeof value === "string") urls.push(value);
      else if (value?.url) urls.push(value.url);
    }
  }
  if (Array.isArray(response?.output)) {
    for (const item of response.output) {
      if (item?.type === "message" && Array.isArray(item.content)) {
        for (const block of item.content) {
          if (!Array.isArray(block?.annotations)) continue;
          for (const annotation of block.annotations) {
            if (typeof annotation === "string") urls.push(annotation);
            else if (annotation?.url) urls.push(annotation.url);
          }
        }
      }
      if (item?.type === "web_search_call" || item?.type === "x_search_call") {
        const action = item.action;
        if (typeof action?.url === "string") urls.push(action.url);
        if (Array.isArray(action?.sources)) {
          for (const source of action.sources) {
            if (typeof source?.url === "string") urls.push(source.url);
          }
        }
      }
    }
  }
  return urls;
}

function parseCandidateArray(text) {
  if (typeof text !== "string" || text.trim() === "") return [];
  const trimmed = text.trim();
  const fenced = trimmed.match(/```(?:json)?\s*([\s\S]*?)\s*```/i);
  const body = fenced?.[1]?.trim() || trimmed;
  const start = body.indexOf("[");
  const end = body.lastIndexOf("]");
  if (start < 0 || end <= start) return [];
  try {
    const parsed = JSON.parse(body.slice(start, end + 1));
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    return [];
  }
}

function upsert(map, candidate) {
  const existing = map.get(candidate.postId);
  if (!existing) {
    map.set(candidate.postId, candidate);
    return;
  }
  map.set(candidate.postId, {
    postId: candidate.postId,
    url: existing.url || candidate.url,
    announcedAt: existing.announcedAt || candidate.announcedAt,
    snippet: pickLonger(existing.snippet, candidate.snippet),
    kindGuess: existing.kindGuess !== "uncertain"
      ? existing.kindGuess
      : candidate.kindGuess,
    parentContext: pickLonger(existing.parentContext, candidate.parentContext),
  });
}

export function mergeDiscoveryCandidates(...groups) {
  const byId = new Map();
  for (const group of groups) {
    if (!Array.isArray(group)) continue;
    for (const candidate of group) {
      if (!candidate?.postId) continue;
      upsert(byId, {
        postId: candidate.postId,
        url: candidate.url || `https://x.com/thsottiaux/status/${candidate.postId}`,
        announcedAt: candidate.announcedAt ?? null,
        snippet: candidate.snippet ?? "",
        kindGuess: candidate.kindGuess ?? "uncertain",
        parentContext: candidate.parentContext ?? "",
      });
    }
  }
  return [...byId.values()].sort((left, right) => (
    right.postId.padStart(30, "0").localeCompare(left.postId.padStart(30, "0"))
  ));
}

export function hasFutureScheduleSignal(candidates, now = new Date()) {
  const nowMs = now.getTime();
  return (Array.isArray(candidates) ? candidates : []).some((candidate) => {
    if (!candidate) return false;
    const kind = String(candidate.kindGuess || "").toLowerCase();
    if (kind === "reset_scheduled") return true;
    const blob = `${candidate.snippet || ""} ${candidate.parentContext || ""}`.toLowerCase();
    if (/decide accordingly|next reset|july 31|31 july|the 31st/.test(blob)) return true;
    if (candidate.announcedAt && Date.parse(candidate.announcedAt) > nowMs) return true;
    return false;
  });
}

function pickLonger(left, right) {
  const a = typeof left === "string" ? left : "";
  const b = typeof right === "string" ? right : "";
  return b.length > a.length ? b : a;
}

function postIdFromUrl(value) {
  if (typeof value !== "string") return null;
  try {
    const parsed = new URL(value);
    const host = parsed.hostname.toLowerCase().replace(/^www\./, "");
    if (!["x.com", "twitter.com"].includes(host)) return null;
    const match = parsed.pathname.match(/^\/([^/]+)\/status\/([0-9]{1,30})(?:\/|$)/i);
    if (!match) return null;
    const handle = match[1].toLowerCase();
    if (handle !== "thsottiaux" && handle !== "i") return null;
    return match[2];
  } catch {
    return null;
  }
}

function normalizePostId(value) {
  if (typeof value === "number" && Number.isInteger(value) && value >= 0) {
    value = String(value);
  }
  if (typeof value !== "string") return null;
  const digits = value.trim();
  if (!/^[0-9]{1,30}$/.test(digits)) return null;
  return digits;
}

function normalizeMaybeDate(value) {
  if (typeof value !== "string" || value.trim() === "") return null;
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return null;
  return date.toISOString();
}

// silence unused lint for rare regex export use
void POST_ID_RE;
