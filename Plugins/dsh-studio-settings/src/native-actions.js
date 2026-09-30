let sequence = 0;
const pending = new Map();

function receive(reply) {
  const request = pending.get(reply?.requestId);
  if (!request) return;
  pending.delete(reply.requestId);
  clearTimeout(request.timer);
  if (reply.ok) request.resolve(reply.result);
  else request.reject(new Error(reply.error || "Native operation failed"));
}

if (typeof window !== "undefined") {
  window.__dshStudioReceive = receive;
}

export function nativeAction(action, payload = {}) {
  const handler = globalThis.window?.webkit?.messageHandlers?.deepseekStudio;
  if (!handler) return Promise.reject(new Error("DSH Studio native bridge unavailable"));
  const requestId = `studio-${Date.now()}-${++sequence}`;
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      pending.delete(requestId);
      reject(new Error("Native operation timed out"));
    }, 30_000);
    pending.set(requestId, { resolve, reject, timer });
    handler.postMessage({ type: "dshStudio.action", action, payload, requestId });
  });
}
