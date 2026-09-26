import { afterEach, describe, expect, it, vi } from "vitest";
import { buildOpenAIRealtimeVoiceProvider } from "../../extensions/openai/api.js";
import {
  clearTalkRealtimeRelaySessionsForTest,
  createTalkRealtimeRelaySession,
  stopTalkRealtimeRelaySession,
  submitTalkRealtimeRelayToolResult,
} from "./talk-realtime-relay.js";

const { FakeWebSocket } = vi.hoisted(() => {
  type Listener = (...args: unknown[]) => void;
  class Socket {
    static OPEN = 1;
    static CLOSED = 3;
    static instances: Socket[] = [];
    readyState = 0;
    listeners = new Map<string, Listener[]>();
    sent: string[] = [];
    constructor() {
      Socket.instances.push(this);
    }
    on(type: string, callback: Listener) {
      this.listeners.set(type, [...(this.listeners.get(type) ?? []), callback]);
      return this;
    }
    emit(type: string, ...args: unknown[]) {
      for (const callback of this.listeners.get(type) ?? []) {
        callback(...args);
      }
    }
    send(payload: string) {
      this.sent.push(payload);
    }
    close(code = 1000, reason = "fixture close") {
      this.readyState = Socket.CLOSED;
      this.emit("close", code, Buffer.from(reason));
    }
    terminate() {
      this.close(1006);
    }
  }
  return { FakeWebSocket: Socket };
});
vi.mock("ws", () => ({ default: FakeWebSocket }));
vi.mock("openclaw/plugin-sdk/provider-auth", async (importOriginal) => ({
  ...(await importOriginal<typeof import("openclaw/plugin-sdk/provider-auth")>()),
  resolveProviderAuthProfileApiKey: vi.fn(async () => ({
    apiKey: "fixture-key",
    source: "fixture",
  })),
  isProviderAuthProfileConfigured: vi.fn(() => true),
}));

describe("ARG-46 provider reconnect tool-result identity evidence", () => {
  afterEach(() => {
    clearTalkRealtimeRelaySessionsForTest();
    FakeWebSocket.instances.length = 0;
    vi.useRealTimers();
  });
  it.each([true, false])(
    "rejects old provider result (continuing=%s) after reconnect",
    async (willContinue) => {
      vi.useFakeTimers();
      const broadcastToConnIds = vi.fn();
      const session = createTalkRealtimeRelaySession({
        context: { broadcastToConnIds } as never,
        connId: "fixture-owner",
        provider: buildOpenAIRealtimeVoiceProvider(),
        providerConfig: { apiKey: "fixture-key" },
        instructions: "fixture",
        tools: [],
      });
      await Promise.resolve();
      const oldSocket = FakeWebSocket.instances[0];
      expect(oldSocket).toBeDefined();
      const emit = (socket: InstanceType<typeof FakeWebSocket>, event: Record<string, unknown>) =>
        socket.emit("message", Buffer.from(JSON.stringify(event)));
      oldSocket.readyState = FakeWebSocket.OPEN;
      oldSocket.emit("open");
      emit(oldSocket, { type: "session.updated" });
      await Promise.resolve();
      emit(oldSocket, {
        type: "response.function_call_arguments.done",
        call_id: "call-old",
        item_id: "item-old",
        name: "fixture_read",
        arguments: "{}",
      });
      expect(
        broadcastToConnIds.mock.calls.some(
          (call) => call[1].type === "toolCall" && call[1].callId === "call-old",
        ),
      ).toBe(true);
      oldSocket.close(1006, "fixture transient drop");
      await vi.advanceTimersByTimeAsync(1000);
      const newSocket = FakeWebSocket.instances[1];
      expect(newSocket).toBeDefined();
      newSocket.readyState = FakeWebSocket.OPEN;
      newSocket.emit("open");
      emit(newSocket, { type: "session.updated" });
      await Promise.resolve();
      const binding = { relaySessionId: session.relaySessionId, connId: "fixture-owner" };
      broadcastToConnIds.mockClear();
      submitTalkRealtimeRelayToolResult({
        ...binding,
        callId: "call-old",
        result: { text: "late old result" },
        options: { willContinue },
      });
      expect(
        newSocket.sent
          .map((raw) => JSON.parse(raw))
          .filter((event) => event.item?.call_id === "call-old"),
      ).toEqual([]);
      expect(
        broadcastToConnIds.mock.calls.some(
          (call) => call[1].type === "toolResult" && call[1].callId === "call-old",
        ),
      ).toBe(false);
      emit(newSocket, {
        type: "response.function_call_arguments.done",
        call_id: "call-new",
        item_id: "item-new",
        name: "fixture_read",
        arguments: "{}",
      });
      submitTalkRealtimeRelayToolResult({
        ...binding,
        callId: "call-new",
        result: { text: "ordinary new result" },
      });
      expect(
        newSocket.sent
          .map((raw) => JSON.parse(raw))
          .filter((event) => event.item?.call_id === "call-new"),
      ).toHaveLength(1);
      expect(
        newSocket.sent
          .map((raw) => JSON.parse(raw))
          .filter((event) => event.type === "response.create"),
      ).toHaveLength(1);
      emit(newSocket, { type: "response.created", response: { id: "response-new" } });
      for (const bytes of [
        [5, 6],
        [7, 8],
      ]) {
        emit(newSocket, {
          type: "response.output_audio.delta",
          response_id: "response-new",
          item_id: "item-answer-new",
          delta: Buffer.from(bytes).toString("base64"),
        });
      }
      emit(newSocket, {
        type: "response.output_audio_transcript.done",
        response_id: "response-new",
        item_id: "item-answer-new",
        transcript: "complete new answer",
      });
      emit(newSocket, {
        type: "response.audio.done",
        response_id: "response-new",
        item_id: "item-answer-new",
      });
      const events = broadcastToConnIds.mock.calls.map((call) => call[1]);
      expect(
        events
          .filter((event) => event.type === "audio")
          .map((event) => ({
            id: event.responseId,
            audio: Buffer.from(event.audioBase64, "base64"),
          })),
      ).toEqual([
        { id: "response-new", audio: Buffer.from([5, 6]) },
        { id: "response-new", audio: Buffer.from([7, 8]) },
      ]);
      expect(
        events.filter((event) => event.type === "transcript").map((event) => event.text),
      ).toEqual(["complete new answer"]);
      expect(
        events.filter((event) => event.type === "audioDone" && event.responseId === "response-new"),
      ).toHaveLength(1);
      expect(events.every((event) => event.relaySessionId === session.relaySessionId)).toBe(true);
      stopTalkRealtimeRelaySession(binding);
    },
  );
});
