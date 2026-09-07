// Control UI tests cover application-owned overlay races.
import { webcrypto } from "node:crypto";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { GatewayBrowserClient, GatewayEventFrame } from "../api/gateway.ts";
import type { ApplicationGateway, ApplicationGatewaySnapshot } from "./gateway.ts";
import { createApplicationOverlays } from "./overlays.ts";

afterEach(() => vi.unstubAllGlobals());

type RequestFn = (method: string, params?: unknown) => Promise<unknown>;

function deferred<T = unknown>() {
  let resolve!: (value: T | PromiseLike<T>) => void;
  let reject!: (reason?: unknown) => void;
  const promise = new Promise<T>((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, reject, resolve };
}

function approval(id: string, createdAtMs: number) {
  return {
    id,
    createdAtMs,
    expiresAtMs: Date.now() + 60_000,
    request: { command: `echo ${id}` },
  };
}

function createGatewayHarness(initialClient: GatewayBrowserClient) {
  let snapshot: ApplicationGatewaySnapshot = {
    assistantAgentId: "main",
    client: initialClient,
    connected: true,
    reconnecting: false,
    hello: null,
    lastError: null,
    lastErrorCode: null,
    sessionKey: "main",
  };
  const snapshotListeners = new Set<(next: ApplicationGatewaySnapshot) => void>();
  const eventListeners = new Set<(event: GatewayEventFrame) => void>();
  const gateway = {
    get snapshot() {
      return snapshot;
    },
    connection: { gatewayUrl: "ws://gateway.test", password: "", token: "" },
    eventLog: [],
    connect() {},
    setSessionKey() {},
    start() {},
    stop() {},
    subscribe(listener: (next: ApplicationGatewaySnapshot) => void) {
      snapshotListeners.add(listener);
      return () => snapshotListeners.delete(listener);
    },
    subscribeEventLog() {
      return () => {};
    },
    subscribeEvents(listener: (event: GatewayEventFrame) => void) {
      eventListeners.add(listener);
      return () => eventListeners.delete(listener);
    },
  } satisfies ApplicationGateway;
  return {
    emitApproval(id: string, createdAtMs: number) {
      const event: GatewayEventFrame = {
        event: "exec.approval.requested",
        payload: approval(id, createdAtMs),
        type: "event",
      };
      for (const listener of eventListeners) {
        listener(event);
      }
    },
    gateway,
    update(next: Partial<ApplicationGatewaySnapshot>) {
      snapshot = { ...snapshot, ...next };
      for (const listener of snapshotListeners) {
        listener(snapshot);
      }
    },
  };
}

function client(request: RequestFn): GatewayBrowserClient {
  return { request } as unknown as GatewayBrowserClient;
}

describe("application approval overlays", () => {
  it("does not attach an older resolve failure to a newer approval", async () => {
    const resolveAttempt = deferred();
    const request = vi.fn<RequestFn>((method) =>
      method.endsWith(".list") ? Promise.resolve([]) : resolveAttempt.promise,
    );
    const harness = createGatewayHarness(client(request));
    const overlays = createApplicationOverlays(harness.gateway);

    harness.emitApproval("approval-active", 1_000);
    const decision = overlays.decideApproval("allow-once");
    harness.emitApproval("approval-newer", 2_000);
    resolveAttempt.reject(new Error("gateway unavailable"));
    await decision;

    expect(overlays.snapshot.approvalQueue.map((entry) => entry.id)).toEqual([
      "approval-newer",
      "approval-active",
    ]);
    expect(overlays.snapshot.approvalError).toBeNull();
    expect(overlays.snapshot.approvalBusy).toBe(false);
    overlays.dispose();
  });

  it("does not release a new client's busy state when an old resolve settles", async () => {
    const oldResolve = deferred();
    const oldRequest = vi.fn<RequestFn>((method) =>
      method.endsWith(".list") ? Promise.resolve([]) : oldResolve.promise,
    );
    const harness = createGatewayHarness(client(oldRequest));
    const overlays = createApplicationOverlays(harness.gateway);

    harness.emitApproval("approval-old", 1_000);
    const oldDecision = overlays.decideApproval("allow-once");
    harness.update({ client: null, connected: false });

    const newResolve = deferred();
    const newClient = client((method) =>
      method.endsWith(".list") ? Promise.resolve([]) : newResolve.promise,
    );
    harness.update({ client: newClient, connected: true });
    await Promise.resolve();
    harness.emitApproval("approval-new", 2_000);
    const newDecision = overlays.decideApproval("deny");
    expect(overlays.snapshot.approvalBusy).toBe(true);

    oldResolve.reject(new Error("gateway client stopped"));
    await oldDecision;
    expect(overlays.snapshot.approvalBusy).toBe(true);
    expect(overlays.snapshot.approvalError).toBeNull();

    newResolve.resolve({ ok: true });
    await newDecision;
    expect(overlays.snapshot.approvalBusy).toBe(false);
    expect(overlays.snapshot.approvalQueue).toEqual([]);
    overlays.dispose();
  });
});

describe("application update overlays", () => {
  it("surfaces a coalesced restart while reconnect verification remains active", async () => {
    const request = vi.fn<RequestFn>().mockResolvedValue({
      ok: true,
      restart: { coalesced: true },
      result: { status: "ok", after: { version: "2.0.0" } },
    });
    const harness = createGatewayHarness(client(request));
    const overlays = createApplicationOverlays(harness.gateway);

    await overlays.runUpdate();

    expect(request).toHaveBeenCalledWith("update.run", {});
    expect(overlays.snapshot.updateStatusBanner).toEqual({
      tone: "info",
      text: "Update installed. A gateway restart is already in progress; status will refresh after it reconnects.",
    });
    expect(overlays.snapshot.updateRunning).toBe(false);
    overlays.dispose();
  });
});

it("resolves artifact reviews with bound identity and can defer without recording a decision", async () => {
  vi.stubGlobal("crypto", webcrypto);
  const binding = {
    operation_id: "operation",
    event_id: "event",
    artifact_sha256: ["a".repeat(64)],
  };
  const request = vi.fn(async (method: string, params?: unknown) => {
    if (
      method === "plugin.approval.list" &&
      (params as { kind?: string })?.kind === "artifact_review"
    )
      return {
        available: true,
        items: [{ id: "review", binding, created_at_ms: 1000, expires_at_ms: Date.now() + 60000 }],
      };
    return [];
  });
  const harness = createGatewayHarness({ request } as unknown as GatewayBrowserClient);
  const overlays = createApplicationOverlays(harness.gateway);
  harness.update({ connected: true });
  await vi.waitFor(() => expect(overlays.snapshot.approvalQueue[0]?.kind).toBe("artifact_review"));
  overlays.deferApproval?.();
  expect(overlays.snapshot.approvalQueue).toHaveLength(0);
  expect(request.mock.calls.some(([method]) => method === "plugin.approval.resolve")).toBe(false);
  await overlays.refreshApprovals?.();
  await overlays.decideApproval("accept_artifact");
  expect(request).toHaveBeenCalledWith("plugin.approval.resolve", {
    kind: "artifact_review",
    id: "review",
    decision: "accept_artifact",
    binding,
    idempotency_key: expect.stringMatching(/^artifact-review:[a-f0-9]{64}$/),
  });
  overlays.dispose();
});

it("refreshes durable pending reviews on a same-client reconnect", async () => {
  const request = vi.fn<RequestFn>().mockResolvedValue([]);
  const harness = createGatewayHarness(client(request));
  const overlays = createApplicationOverlays(harness.gateway);
  await overlays.refreshApprovals?.();
  request.mockClear();
  harness.update({ connected: false });
  harness.update({ connected: true });
  await vi.waitFor(() =>
    expect(request).toHaveBeenCalledWith("plugin.approval.list", { kind: "artifact_review" }),
  );
  overlays.dispose();
});

it("uses bounded deterministic resolution keys for maximum-length review IDs", async () => {
  vi.stubGlobal("crypto", webcrypto);
  const row = {
    id: "r".repeat(512),
    binding: { operation_id: "operation", event_id: "event", artifact_sha256: ["a".repeat(64)] },
    created_at_ms: 1000,
    expires_at_ms: Date.now() + 60000,
  };
  const request = vi.fn<RequestFn>(async (method, params) => {
    if (method === "plugin.approval.resolve") throw new Error("retryable unavailable");
    if ((params as { kind?: string })?.kind === "artifact_review")
      return { available: true, items: [row] };
    return [];
  });
  const harness = createGatewayHarness(client(request));
  const overlays = createApplicationOverlays(harness.gateway);
  await vi.waitFor(() => expect(overlays.snapshot.approvalQueue).toHaveLength(1));
  await overlays.decideApproval("accept_artifact");
  await overlays.decideApproval("accept_artifact");
  await overlays.decideApproval("reject_artifact");
  const keys = request.mock.calls
    .filter(([method]) => method === "plugin.approval.resolve")
    .map(([, params]) => (params as { idempotency_key: string }).idempotency_key);
  expect(keys).toHaveLength(3);
  expect(keys[0]).toMatch(/^artifact-review:[a-f0-9]{64}$/);
  expect(keys[0]).toBe(keys[1]);
  expect(keys[2]).not.toBe(keys[0]);
  overlays.dispose();
});
