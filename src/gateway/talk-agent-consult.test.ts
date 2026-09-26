/** Isolated consult admission through the real relay registry; chat I/O is fake. */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { RealtimeVoiceProviderPlugin } from "../plugins/types.js";
import type { RealtimeVoiceBridgeCreateRequest } from "../talk/provider-types.js";
import { registerChatAbortController } from "./chat-abort.js";
import type {
  GatewayRequestContext,
  GatewayRequestHandlers,
} from "./server-methods/shared-types.js";
import { startTalkRealtimeAgentConsult } from "./talk-agent-consult.js";
import {
  cancelTalkRealtimeRelayTurn,
  clearTalkRealtimeRelaySessionsForTest,
  createTalkRealtimeRelaySession,
  sendTalkRealtimeRelayAudio,
  stopTalkRealtimeRelaySession,
} from "./talk-realtime-relay.js";

const mocks = vi.hoisted(() => ({ chatSend: vi.fn<GatewayRequestHandlers[string]>() }));
vi.mock("./server-methods/chat.js", () => ({ chatHandlers: { "chat.send": mocks.chatSend } }));

function fixture(forceAgentConsultOnFinalTranscript = false) {
  let callbacks: RealtimeVoiceBridgeCreateRequest | undefined;
  const close = vi.fn();
  const provider: RealtimeVoiceProviderPlugin = {
    id: "relay-test",
    label: "Relay Test",
    isConfigured: () => true,
    createBridge: (request) => {
      callbacks = request;
      return {
        connect: vi.fn(async () => undefined),
        sendAudio: vi.fn(),
        setMediaTimestamp: vi.fn(),
        handleBargeIn: vi.fn(),
        submitToolResult: vi.fn(),
        acknowledgeMark: vi.fn(),
        close,
        isConnected: () => true,
      };
    },
  };
  const chatAbortControllers: GatewayRequestContext["chatAbortControllers"] = new Map();
  const context = {
    getRuntimeConfig: () => ({}),
    broadcastToConnIds: vi.fn(),
    broadcast: vi.fn(),
    nodeSendToSession: vi.fn(),
    chatAbortControllers,
    chatRunBuffers: new Map(),
    chatAbortedRuns: new Map(),
    clearChatRunState: vi.fn(),
    removeChatRun: vi.fn(),
    agentRunSeq: new Map(),
  } as unknown as GatewayRequestContext;
  const session = createTalkRealtimeRelaySession({
    context,
    connId: "conn-1",
    sessionKey: "main",
    provider,
    providerConfig: {},
    instructions: "brief",
    tools: [],
    forceAgentConsultOnFinalTranscript,
  });
  const binding = { relaySessionId: session.relaySessionId, connId: "conn-1" };
  const consult = (overrides: Partial<Parameters<typeof startTalkRealtimeAgentConsult>[0]> = {}) =>
    startTalkRealtimeAgentConsult({
      context,
      client: { connId: "conn-1" } as never,
      isWebchatConnect: () => false,
      requestId: "request-1",
      sessionKey: "main",
      callId: "call-1",
      args: { question: "Check this request." },
      ...binding,
      ...overrides,
    }).catch((error: unknown) => ({ ok: false as const, error }));
  const emitTool = (callId = "call-1") => {
    if (!callbacks) {
      throw new Error("Missing bridge callbacks");
    }
    callbacks.onToolCall?.({
      itemId: "item-1",
      callId,
      name: "openclaw_agent_consult",
      args: { question: "Check this request." },
    });
  };
  return { context, binding, consult, emitTool, close, callbacks };
}

describe("realtime consult relay admission", () => {
  beforeEach(() => {
    mocks.chatSend.mockReset();
    mocks.chatSend.mockImplementation(async ({ respond, params, context }) => {
      const runId = params.idempotencyKey as string;
      registerChatAbortController({
        chatAbortControllers: context.chatAbortControllers,
        runId,
        sessionId: "session-1",
        sessionKey: "main",
        timeoutMs: 60_000,
        ownerConnId: "conn-1",
      });
      respond(true, { runId, status: "started" });
    });
  });
  afterEach(() => {
    clearTalkRealtimeRelaySessionsForTest();
    vi.useRealTimers();
  });

  it.each([
    "closed",
    "foreign-owner",
    "wrong-session",
    "missing-connection",
    "cancelled-call",
    "expired",
  ])("rejects %s before chat admission", async (state) => {
    vi.useFakeTimers();
    const f = fixture();
    const overrides: Partial<Parameters<typeof startTalkRealtimeAgentConsult>[0]> = {};
    if (state === "closed") {
      stopTalkRealtimeRelaySession(f.binding);
    }
    if (state === "foreign-owner") {
      overrides.connId = "conn-other";
    }
    if (state === "wrong-session") {
      overrides.sessionKey = "other";
    }
    if (state === "missing-connection") {
      overrides.connId = undefined;
    }
    if (state === "cancelled-call") {
      f.emitTool();
      cancelTalkRealtimeRelayTurn(f.binding);
    }
    if (state === "expired") {
      await vi.advanceTimersByTimeAsync(30 * 60_000 + 1);
    }
    const result = await f.consult(overrides);
    expect(result.ok).toBe(false);
    expect(mocks.chatSend).not.toHaveBeenCalled();
    if (state === "foreign-owner" || state === "wrong-session") {
      expect(f.close).not.toHaveBeenCalled();
      expect(() => sendTalkRealtimeRelayAudio({ ...f.binding, audioBase64: "AQI=" })).not.toThrow();
    }
  });

  it.each(["stop", "cancel-turn"])(
    "retires %s during chat admission before the fake agent starts",
    async (action) => {
      const f = fixture();
      f.emitTool();
      let release!: () => void;
      const gate = new Promise<void>((resolve) => {
        release = resolve;
      });
      let controller: AbortController | undefined;
      let admittedAfterAck: boolean | undefined;
      mocks.chatSend.mockImplementation(async ({ respond, params, context }) => {
        await gate;
        const runId = params.idempotencyKey as string;
        controller = registerChatAbortController({
          chatAbortControllers: context.chatAbortControllers,
          runId,
          sessionId: "session-1",
          sessionKey: "main",
          timeoutMs: 60_000,
          ownerConnId: "conn-1",
        }).controller;
        respond(true, { runId, status: "started" });
        // Real chat.send registers its controller before ACK and supplies this signal to dispatch.
        admittedAfterAck = !controller.signal.aborted;
      });
      const pending = f.consult();
      expect(mocks.chatSend).toHaveBeenCalledTimes(1);
      if (action === "stop") {
        stopTalkRealtimeRelaySession(f.binding);
      } else {
        cancelTalkRealtimeRelayTurn(f.binding);
      }
      release();
      const result = await pending;
      expect(result.ok).toBe(false);
      expect(controller?.signal.aborted).toBe(true);
      expect(admittedAfterAck).toBe(false);
      if (action === "cancel-turn") {
        await expect(f.consult({ callId: "call-next" })).resolves.toMatchObject({ ok: true });
      }
    },
  );

  it("registers at ACK so Stop during the remaining chat await aborts the exact run", async () => {
    const f = fixture();
    let release!: () => void;
    const gate = new Promise<void>((resolve) => {
      release = resolve;
    });
    let controller: AbortController | undefined;
    mocks.chatSend.mockImplementation(async ({ respond, params, context }) => {
      const runId = params.idempotencyKey as string;
      controller = registerChatAbortController({
        chatAbortControllers: context.chatAbortControllers,
        runId,
        sessionId: "session-1",
        sessionKey: "main",
        timeoutMs: 60_000,
        ownerConnId: "conn-1",
      }).controller;
      respond(true, { runId, status: "started" });
      await gate;
    });
    const pending = f.consult();
    stopTalkRealtimeRelaySession(f.binding);
    expect(controller?.signal.aborted).toBe(true);
    release();
    await pending;
  });

  it("rejects an emitted forced consult after cancellation before chat admission", async () => {
    vi.useFakeTimers();
    const f = fixture(true);
    f.callbacks?.onTranscript?.("user", "Check this request.", true);
    await vi.advanceTimersByTimeAsync(200);
    const calls = vi.mocked(f.context.broadcastToConnIds).mock.calls;
    const event = calls
      .map((call) => call[1])
      .find(
        (payload) =>
          Boolean(payload) &&
          typeof payload === "object" &&
          (payload as Record<string, unknown>).type === "toolCall",
      );
    expect(event).toMatchObject({ type: "toolCall", forced: true });
    const callId = (event as Record<string, string>).callId;
    cancelTalkRealtimeRelayTurn(f.binding);
    await expect(f.consult({ callId })).resolves.toMatchObject({ ok: false });
    expect(mocks.chatSend).not.toHaveBeenCalled();
  });

  it("does not abort a deduped run owned by another invocation during Stop", async () => {
    const f = fixture();
    let release!: () => void;
    const gate = new Promise<void>((resolve) => {
      release = resolve;
    });
    const { controller } = registerChatAbortController({
      chatAbortControllers: f.context.chatAbortControllers,
      runId: "existing-run",
      sessionId: "session-1",
      sessionKey: "main",
      timeoutMs: 60_000,
      ownerConnId: "conn-other",
    });
    mocks.chatSend.mockImplementation(async ({ respond }) => {
      await gate;
      respond(true, { runId: "existing-run", status: "in_flight" });
    });
    const pending = f.consult();
    stopTalkRealtimeRelaySession(f.binding);
    release();
    await expect(pending).resolves.toMatchObject({ ok: false });
    expect(controller.signal.aborted).toBe(false);
    expect(f.context.chatAbortControllers.has("existing-run")).toBe(true);
  });

  it("does not adopt another connection's deduped run", async () => {
    const f = fixture();
    const { controller } = registerChatAbortController({
      chatAbortControllers: f.context.chatAbortControllers,
      runId: "existing-run",
      sessionId: "session-1",
      sessionKey: "main",
      timeoutMs: 60_000,
      ownerConnId: "conn-other",
    });
    mocks.chatSend.mockImplementation(async ({ respond }) => {
      respond(true, { runId: "existing-run", status: "in_flight" });
    });
    await expect(f.consult()).resolves.toMatchObject({ ok: false });
    stopTalkRealtimeRelaySession(f.binding);
    expect(controller.signal.aborted).toBe(false);
  });

  it("keeps reconnect-only retirement separate from aborting an admitted operation", async () => {
    const f = fixture();
    f.emitTool();
    let controller: AbortController | undefined;
    mocks.chatSend.mockImplementation(async ({ respond, params, context }) => {
      const runId = params.idempotencyKey as string;
      controller = registerChatAbortController({
        chatAbortControllers: context.chatAbortControllers,
        runId,
        sessionId: "session-1",
        sessionKey: "main",
        timeoutMs: 60_000,
        ownerConnId: "conn-1",
      }).controller;
      f.callbacks?.onEvent?.({ direction: "client", type: "session.reconnect.scheduled" });
      respond(true, { runId, status: "started" });
    });
    await expect(f.consult()).resolves.toMatchObject({ ok: false });
    expect(controller?.signal.aborted).toBe(false);
    mocks.chatSend.mockImplementation(async ({ respond, params }) => {
      respond(true, { runId: params.idempotencyKey });
    });
    f.emitTool("call-next");
    await expect(f.consult({ callId: "call-next" })).resolves.toMatchObject({ ok: true });
  });

  it("uses the chat controller's canonical session key for subsequent Stop", async () => {
    const f = fixture();
    let controller: AbortController | undefined;
    mocks.chatSend.mockImplementation(async ({ respond, params, context }) => {
      const runId = params.idempotencyKey as string;
      controller = registerChatAbortController({
        chatAbortControllers: context.chatAbortControllers,
        runId,
        sessionId: "session-1",
        sessionKey: "agent:main:main",
        timeoutMs: 60_000,
        ownerConnId: "conn-1",
      }).controller;
      respond(true, { runId });
    });
    await expect(f.consult()).resolves.toMatchObject({ ok: true });
    stopTalkRealtimeRelaySession(f.binding);
    expect(controller?.signal.aborted).toBe(true);
  });

  it("preserves an active relay and the client-owned no-relay path", async () => {
    const f = fixture();
    await expect(f.consult()).resolves.toMatchObject({ ok: true });
    await expect(
      f.consult({ relaySessionId: undefined, connId: undefined, callId: "browser-call" }),
    ).resolves.toMatchObject({ ok: true });
    expect(mocks.chatSend).toHaveBeenCalledTimes(2);
  });
});
