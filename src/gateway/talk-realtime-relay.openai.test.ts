import { afterEach, describe, expect, it, vi } from "vitest";
import { buildOpenAIRealtimeVoiceProvider } from "../../extensions/openai/api.js";
import {
  cancelTalkRealtimeRelayTurn,
  clearTalkRealtimeRelaySessionsForTest,
  createTalkRealtimeRelaySession,
  sendTalkRealtimeRelayAudio,
  stopTalkRealtimeRelaySession,
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

describe("actual OpenAI provider through bridge and gateway relay", () => {
  afterEach(() => {
    clearTalkRealtimeRelaySessionsForTest();
    FakeWebSocket.instances.length = 0;
  });

  it.each([50, 400])(
    "explicit cancellation at %ims preserves only the follow-up audio",
    async (elapsed) => {
      const broadcastToConnIds = vi.fn();
      const session = createTalkRealtimeRelaySession({
        context: { broadcastToConnIds } as never,
        connId: "fixture-owner",
        provider: buildOpenAIRealtimeVoiceProvider(),
        providerConfig: { apiKey: "fixture-key" },
        instructions: "fixture",
        tools: [],
      });
      await vi.waitFor(() => expect(FakeWebSocket.instances).toHaveLength(1));
      const socket = FakeWebSocket.instances[0];
      socket.readyState = FakeWebSocket.OPEN;
      socket.emit("open");
      const emit = (event: Record<string, unknown>) =>
        socket.emit("message", Buffer.from(JSON.stringify(event)));
      emit({ type: "session.updated" });
      const binding = { relaySessionId: session.relaySessionId, connId: "fixture-owner" };
      const input = (timestamp: number) =>
        sendTalkRealtimeRelayAudio({
          ...binding,
          timestamp,
          audioBase64: Buffer.from([0, 0]).toString("base64"),
        });
      const output = (id: string, bytes: number[]) =>
        emit({
          type: "response.output_audio.delta",
          response_id: "response-" + id,
          item_id: "item-" + id,
          delta: Buffer.from(bytes).toString("base64"),
        });
      input(1000);
      emit({ type: "response.created", response: { id: "response-old" } });
      output("old", [1, 2]);
      input(1000 + elapsed);
      if (elapsed === 50) {
        // Automatic speech detection retains its minimum window; explicit stop below does not.
        emit({ type: "input_audio_buffer.speech_started" });
        output("old", [11, 12]);
        expect(
          socket.sent
            .map((raw) => JSON.parse(raw))
            .some((event) => event.type === "response.cancel"),
        ).toBe(false);
        expect(
          broadcastToConnIds.mock.calls.filter((call) => call[1].type === "audio"),
        ).toHaveLength(2);
      }
      cancelTalkRealtimeRelayTurn({ ...binding, reason: "client-stop" });
      expect(
        socket.sent.map((raw) => JSON.parse(raw)).some((event) => event.type === "response.cancel"),
      ).toBe(true);
      broadcastToConnIds.mockClear();
      output("old", [3, 4]);
      emit({
        type: "response.output_audio_transcript.done",
        response_id: "response-old",
        item_id: "item-old",
        transcript: "retired answer",
      });
      emit({ type: "response.done", response: { id: "response-old" } });
      input(1600);
      emit({ type: "response.created", response: { id: "response-new" } });
      output("new", [5, 6]);
      output("old", [7, 8]);
      emit({ type: "response.audio.done", response_id: "response-old", item_id: "item-old" });
      output("new", [9, 10]);
      emit({
        type: "response.output_audio_transcript.done",
        response_id: "response-new",
        item_id: "item-new",
        transcript: "complete next answer",
      });
      emit({ type: "response.audio.done", response_id: "response-new", item_id: "item-new" });
      const events = broadcastToConnIds.mock.calls.map((call) => call[1]);
      expect(
        events
          .filter((event) => event.type === "audio")
          .map((event) => ({
            response: event.responseId,
            item: event.itemId,
            bytes: Buffer.from(event.audioBase64, "base64"),
          })),
      ).toEqual([
        { response: "response-new", item: "item-new", bytes: Buffer.from([5, 6]) },
        { response: "response-new", item: "item-new", bytes: Buffer.from([9, 10]) },
      ]);
      expect(
        events.filter((event) => event.type === "transcript").map((event) => event.text),
      ).toEqual(["complete next answer"]);
      expect(
        events.filter((event) => event.type === "audioDone" && event.responseId === "response-new"),
      ).toHaveLength(1);
      expect(
        events.filter((event) => event.type === "audio").map((event) => event.talkEvent.turnId),
      ).toEqual(["turn-2", "turn-2"]);
      expect(events.every((event) => event.relaySessionId === session.relaySessionId)).toBe(true);
      stopTalkRealtimeRelaySession(binding);
    },
  );
  it.each([
    ["response.function_call_arguments.done", true],
    ["response.function_call_arguments.done", false],
    ["conversation.item.done", true],
    ["conversation.item.done", false],
  ])(
    "rejects interrupted tool completion (%s, explicit response=%s)",
    async (lateType, explicitResponse) => {
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
      const socket = FakeWebSocket.instances[0];
      socket.readyState = FakeWebSocket.OPEN;
      socket.emit("open");
      const emit = (event: Record<string, unknown>) =>
        socket.emit("message", Buffer.from(JSON.stringify(event)));
      emit({ type: "session.updated" });
      await Promise.resolve();
      const binding = { relaySessionId: session.relaySessionId, connId: "fixture-owner" };
      emit({ type: "response.created", response: { id: "response-old-tool" } });
      emit({
        type: "response.function_call_arguments.delta",
        response_id: "response-old-tool",
        item_id: "item-old-tool",
        call_id: "call-old-tool",
        name: "fixture_read",
        delta: "{}",
      });
      cancelTalkRealtimeRelayTurn({ ...binding, reason: "fixture-client-stop" });
      emit({ type: "response.cancelled", response: { id: "response-old-tool" } });
      emit({ type: "response.created", response: { id: "response-new-tool" } });
      broadcastToConnIds.mockClear();
      const lateCompletion = {
        type: lateType,
        ...(explicitResponse ? { response_id: "response-old-tool" } : {}),
        item_id: "item-old-tool",
        call_id: "call-old-tool",
        name: "fixture_read",
        arguments: "{}",
        ...(lateType === "conversation.item.done"
          ? {
              item: {
                type: "function_call",
                id: "item-old-tool",
                call_id: "call-old-tool",
                name: "fixture_read",
                arguments: "{}",
              },
            }
          : {}),
      };
      emit(lateCompletion);
      // A delayed argument chunk must not resurrect the retired buffered item either.
      emit({
        type: "response.function_call_arguments.delta",
        response_id: "response-old-tool",
        item_id: "item-old-tool",
        call_id: "call-old-tool",
        name: "fixture_read",
        delta: "{}",
      });
      emit(lateCompletion);
      expect(broadcastToConnIds.mock.calls.filter((call) => call[1].type === "toolCall")).toEqual(
        [],
      );
      emit({
        type: "response.function_call_arguments.done",
        response_id: "response-new-tool",
        item_id: "item-new-tool",
        call_id: "call-new-tool",
        name: "fixture_read",
        arguments: "{}",
      });
      expect(
        broadcastToConnIds.mock.calls
          .filter((call) => call[1].type === "toolCall")
          .map((call) => call[1].callId),
      ).toEqual(["call-new-tool"]);
      stopTalkRealtimeRelaySession(binding);
    },
  );
});
