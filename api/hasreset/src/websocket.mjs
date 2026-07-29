import { createHash, randomBytes } from "node:crypto";
import { request as httpRequest } from "node:http";
import { request as httpsRequest } from "node:https";
import { URL } from "node:url";

/**
 * Minimal RFC6455 client for text frames. No third-party dependency.
 * Supports wss:// and ws:// (loopback) with custom headers.
 */
export function openWebSocket(url, {
  headers = {},
  timeoutMs = 240_000,
  signal,
} = {}) {
  const parsed = new URL(url);
  if (!["https:", "http:", "wss:", "ws:"].includes(parsed.protocol)) {
    throw new Error("WebSocket URL must use ws(s) or http(s)");
  }

  const isSecure = parsed.protocol === "https:" || parsed.protocol === "wss:";
  const request = isSecure ? httpsRequest : httpRequest;
  const key = randomBytes(16).toString("base64");
  const expectedAccept = createHash("sha1")
    .update(`${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`)
    .digest("base64");

  return new Promise((resolve, reject) => {
    let settled = false;
    const fail = (error) => {
      if (settled) return;
      settled = true;
      reject(error);
    };

    const req = request({
      protocol: isSecure ? "https:" : "http:",
      hostname: parsed.hostname,
      port: parsed.port || (isSecure ? 443 : 80),
      path: `${parsed.pathname}${parsed.search}`,
      method: "GET",
      headers: {
        ...headers,
        Connection: "Upgrade",
        Upgrade: "websocket",
        "Sec-WebSocket-Version": "13",
        "Sec-WebSocket-Key": key,
      },
      timeout: timeoutMs,
    });

    const onAbort = () => {
      req.destroy(new Error("WebSocket request aborted"));
    };
    signal?.addEventListener("abort", onAbort, { once: true });

    req.on("upgrade", (response, socket) => {
      signal?.removeEventListener("abort", onAbort);
      const accept = response.headers["sec-websocket-accept"];
      if (accept !== expectedAccept) {
        socket.destroy();
        fail(new Error("WebSocket handshake accept mismatch"));
        return;
      }
      settled = true;
      resolve(createSocketSession(socket, { timeoutMs, signal }));
    });

    req.on("response", (response) => {
      const chunks = [];
      response.on("data", (chunk) => chunks.push(chunk));
      response.on("end", () => {
        const body = Buffer.concat(chunks).toString("utf8").slice(0, 200);
        fail(new Error(
          `WebSocket upgrade failed with HTTP ${response.statusCode}${body ? `: ${body}` : ""}`,
        ));
      });
    });

    req.on("timeout", () => {
      req.destroy(new Error("WebSocket handshake timed out"));
    });
    req.on("error", fail);
    req.end();
  });
}

function createSocketSession(socket, { timeoutMs, signal }) {
  let buffer = Buffer.alloc(0);
  let closed = false;
  const listeners = new Set();
  let idleTimer = null;
  // Cloudflare and many free proxies drop quiet sockets; keep the agentic
  // X Search turn alive while the model is still working server-side.
  const pingTimer = setInterval(() => {
    if (closed) return;
    try {
      socket.write(encodeFrame(Buffer.alloc(0), 0x9));
    } catch {
      // ignore
    }
  }, 15_000);
  if (typeof pingTimer.unref === "function") pingTimer.unref();

  const resetIdle = () => {
    if (idleTimer) clearTimeout(idleTimer);
    if (!timeoutMs) return;
    idleTimer = setTimeout(() => {
      close(1000, "idle timeout");
    }, timeoutMs);
  };

  const emit = (type, payload) => {
    for (const listener of listeners) {
      if (listener.type === type) listener.handler(payload);
    }
  };

  const onAbort = () => close(1000, "aborted");
  signal?.addEventListener("abort", onAbort, { once: true });

  socket.on("data", (chunk) => {
    resetIdle();
    buffer = Buffer.concat([buffer, chunk]);
    while (true) {
      const frame = decodeFrame(buffer);
      if (!frame) break;
      buffer = frame.rest;
      if (frame.opcode === 0x1) {
        emit("message", frame.payload.toString("utf8"));
      } else if (frame.opcode === 0x8) {
        close(1000, "remote closed");
      } else if (frame.opcode === 0x9) {
        socket.write(encodeFrame(frame.payload, 0xA));
      }
    }
  });

  socket.on("error", (error) => {
    emit("error", error);
    close(1011, "socket error");
  });

  socket.on("close", () => {
    closed = true;
    if (idleTimer) clearTimeout(idleTimer);
    clearInterval(pingTimer);
    signal?.removeEventListener("abort", onAbort);
    emit("close");
  });

  function send(text) {
    if (closed) throw new Error("WebSocket is closed");
    resetIdle();
    socket.write(encodeFrame(Buffer.from(String(text), "utf8"), 0x1));
  }

  function close(code = 1000, reason = "") {
    if (closed) return;
    closed = true;
    if (idleTimer) clearTimeout(idleTimer);
    clearInterval(pingTimer);
    try {
      const reasonBuf = Buffer.from(reason, "utf8").subarray(0, 123);
      const body = Buffer.alloc(2 + reasonBuf.length);
      body.writeUInt16BE(code, 0);
      reasonBuf.copy(body, 2);
      socket.write(encodeFrame(body, 0x8));
    } catch {
      // ignore
    }
    socket.end();
    socket.destroy();
  }

  function on(type, handler) {
    const listener = { type, handler };
    listeners.add(listener);
    return () => listeners.delete(listener);
  }

  resetIdle();
  return { send, close, on };
}

function encodeFrame(payload, opcode) {
  const length = payload.length;
  const mask = randomBytes(4);
  let header;
  if (length < 126) {
    header = Buffer.alloc(2);
    header[0] = 0x80 | opcode;
    header[1] = 0x80 | length;
  } else if (length < 65_536) {
    header = Buffer.alloc(4);
    header[0] = 0x80 | opcode;
    header[1] = 0x80 | 126;
    header.writeUInt16BE(length, 2);
  } else {
    header = Buffer.alloc(10);
    header[0] = 0x80 | opcode;
    header[1] = 0x80 | 127;
    header.writeBigUInt64BE(BigInt(length), 2);
  }
  const masked = Buffer.alloc(length);
  for (let i = 0; i < length; i += 1) {
    masked[i] = payload[i] ^ mask[i % 4];
  }
  return Buffer.concat([header, mask, masked]);
}

function decodeFrame(buffer) {
  if (buffer.length < 2) return null;
  const second = buffer[1];
  const masked = (second & 0x80) !== 0;
  let payloadLength = second & 0x7f;
  let offset = 2;
  if (payloadLength === 126) {
    if (buffer.length < 4) return null;
    payloadLength = buffer.readUInt16BE(2);
    offset = 4;
  } else if (payloadLength === 127) {
    if (buffer.length < 10) return null;
    const big = buffer.readBigUInt64BE(2);
    if (big > BigInt(Number.MAX_SAFE_INTEGER)) {
      throw new Error("WebSocket frame too large");
    }
    payloadLength = Number(big);
    offset = 10;
  }
  const maskLength = masked ? 4 : 0;
  const total = offset + maskLength + payloadLength;
  if (buffer.length < total) return null;
  const mask = masked ? buffer.subarray(offset, offset + 4) : null;
  offset += maskLength;
  const raw = buffer.subarray(offset, offset + payloadLength);
  const payload = Buffer.alloc(payloadLength);
  for (let i = 0; i < payloadLength; i += 1) {
    payload[i] = mask ? raw[i] ^ mask[i % 4] : raw[i];
  }
  return {
    opcode: buffer[0] & 0x0f,
    payload,
    rest: buffer.subarray(total),
  };
}
