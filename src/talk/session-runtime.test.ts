// Talk session runtime tests cover provider lifecycle and session events.
import { describe, expect, it, vi } from "vitest";
import type { RealtimeVoiceProviderPlugin } from "../plugins/types.js";
import {
  REALTIME_VOICE_AUDIO_FORMAT_PCM16_24KHZ,
  type RealtimeVoiceBridge,
} from "./provider-types.js";
import { createRealtimeVoiceBridgeSession } from "./session-runtime.js";

function makeBridge(overrides: Partial<RealtimeVoiceBridge> = {}): RealtimeVoiceBridge {
  return {
    acknowledgeMark: vi.fn(),
    close: vi.fn(),
    connect: vi.fn(async () => {}),
    isConnected: vi.fn(() => true),
    sendAudio: vi.fn(),
    setMediaTimestamp: vi.fn(),
    submitToolResult: vi.fn(),
    triggerGreeting: vi.fn(),
    ...overrides,
  };
}

function expectBridgeRequest(
  request: Parameters<RealtimeVoiceProviderPlugin["createBridge"]>[0] | undefined,
): Parameters<RealtimeVoiceProviderPlugin["createBridge"]>[0] {
  if (!request) {
    throw new Error("Expected realtime voice provider bridge request");
  }
  return request;
}

describe("realtime voice bridge session runtime", () => {
  it.each(["local", "provider"] as const)(
    "fences callbacks after %s close and notifies once",
    (origin) => {
      let request: Parameters<RealtimeVoiceProviderPlugin["createBridge"]>[0] | undefined;
      const sendAudio = vi.fn(),
        clearAudio = vi.fn(),
        sendMark = vi.fn();
      const onTranscript = vi.fn(),
        onEvent = vi.fn(),
        onToolCall = vi.fn();
      const onReady = vi.fn(),
        onError = vi.fn(),
        onClose = vi.fn();
      const close = vi.fn(() => request?.onClose?.("completed"));
      const triggerGreeting = vi.fn();
      const bridge = makeBridge({ close, triggerGreeting });
      const session = createRealtimeVoiceBridgeSession({
        provider: {
          id: "test",
          label: "Test",
          isConfigured: () => true,
          createBridge: (next) => {
            request = next;
            return bridge;
          },
        },
        providerConfig: {},
        audioSink: { isOpen: () => true, sendAudio, clearAudio, sendMark },
        triggerGreetingOnReady: true,
        onTranscript,
        onEvent,
        onToolCall,
        onReady,
        onError,
        onClose,
      });
      const callbacks = expectBridgeRequest(request);
      callbacks.onTranscript?.("assistant", "complete suffix", true);
      if (origin === "local") {
        session.close();
        session.close();
      } else {
        callbacks.onClose?.("completed");
      }
      callbacks.onAudio(Buffer.from([1, 2]));
      callbacks.onClearAudio();
      callbacks.onMark?.("late-mark");
      callbacks.onTranscript?.("assistant", "late correction", true);
      callbacks.onEvent?.({ direction: "server", type: "response.done" });
      callbacks.onToolCall?.({
        itemId: "late-item",
        callId: "late-call",
        name: "lookup",
        args: {},
      });
      callbacks.onReady?.();
      callbacks.onError?.(new Error("late error"));
      callbacks.onClose?.("error");
      expect(onTranscript.mock.calls).toEqual([["assistant", "complete suffix", true]]);
      for (const callback of [
        sendAudio,
        clearAudio,
        sendMark,
        onEvent,
        onToolCall,
        onReady,
        onError,
        triggerGreeting,
      ]) {
        expect(callback).not.toHaveBeenCalled();
      }
      expect(onClose.mock.calls).toEqual([["completed"]]);
      expect(close).toHaveBeenCalledTimes(origin === "local" ? 1 : 0);
    },
  );

  it("routes provider output through an open audio sink", () => {
    let callbacks: Parameters<RealtimeVoiceProviderPlugin["createBridge"]>[0] | undefined;
    const bridge = makeBridge();
    const provider: RealtimeVoiceProviderPlugin = {
      id: "test",
      label: "Test",
      isConfigured: () => true,
      createBridge: (request) => {
        callbacks = request;
        return bridge;
      },
    };
    const sendAudio = vi.fn();
    const clearAudio = vi.fn();
    const sendMark = vi.fn();

    createRealtimeVoiceBridgeSession({
      provider,
      cfg: { talk: { realtime: { provider: "test" } } },
      providerConfig: {},
      audioSink: {
        isOpen: () => true,
        sendAudio,
        clearAudio,
        sendMark,
      },
    });

    callbacks?.onAudio(Buffer.from([1, 2]));
    callbacks?.onClearAudio();
    callbacks?.onMark?.("mark-1");

    expect(callbacks?.cfg).toEqual({ talk: { realtime: { provider: "test" } } });
    expect(sendAudio).toHaveBeenCalledWith(Buffer.from([1, 2]));
    expect(clearAudio).toHaveBeenCalledTimes(1);
    expect(sendMark).toHaveBeenCalledWith("mark-1");
  });

  it("passes the requested audio format to the provider bridge", () => {
    let request: Parameters<RealtimeVoiceProviderPlugin["createBridge"]>[0] | undefined;
    const provider: RealtimeVoiceProviderPlugin = {
      id: "test",
      label: "Test",
      isConfigured: () => true,
      createBridge: (nextRequest) => {
        request = nextRequest;
        return makeBridge();
      },
    };

    createRealtimeVoiceBridgeSession({
      provider,
      providerConfig: {},
      audioFormat: REALTIME_VOICE_AUDIO_FORMAT_PCM16_24KHZ,
      audioSink: { sendAudio: vi.fn() },
    });

    expect(expectBridgeRequest(request).audioFormat).toEqual(
      REALTIME_VOICE_AUDIO_FORMAT_PCM16_24KHZ,
    );
  });

  it("passes the audio auto-response preference to the provider bridge", () => {
    let request: Parameters<RealtimeVoiceProviderPlugin["createBridge"]>[0] | undefined;
    const provider: RealtimeVoiceProviderPlugin = {
      id: "test",
      label: "Test",
      isConfigured: () => true,
      createBridge: (nextRequest) => {
        request = nextRequest;
        return makeBridge();
      },
    };

    createRealtimeVoiceBridgeSession({
      provider,
      providerConfig: {},
      autoRespondToAudio: false,
      audioSink: { sendAudio: vi.fn() },
    });

    expect(expectBridgeRequest(request).autoRespondToAudio).toBe(false);
  });

  it("passes the audio interrupt preference to the provider bridge", () => {
    let request: Parameters<RealtimeVoiceProviderPlugin["createBridge"]>[0] | undefined;
    const provider: RealtimeVoiceProviderPlugin = {
      id: "test",
      label: "Test",
      isConfigured: () => true,
      createBridge: (nextRequest) => {
        request = nextRequest;
        return makeBridge();
      },
    };

    createRealtimeVoiceBridgeSession({
      provider,
      providerConfig: {},
      interruptResponseOnInputAudio: false,
      audioSink: { sendAudio: vi.fn() },
    });

    expect(expectBridgeRequest(request).interruptResponseOnInputAudio).toBe(false);
  });

  it("can acknowledge provider marks without transport mark support", () => {
    let callbacks: Parameters<RealtimeVoiceProviderPlugin["createBridge"]>[0] | undefined;
    const bridge = makeBridge();
    const provider: RealtimeVoiceProviderPlugin = {
      id: "test",
      label: "Test",
      isConfigured: () => true,
      createBridge: (request) => {
        callbacks = request;
        return bridge;
      },
    };
    const sendMark = vi.fn();

    createRealtimeVoiceBridgeSession({
      provider,
      providerConfig: {},
      audioSink: { sendAudio: vi.fn(), sendMark },
      markStrategy: "ack-immediately",
    });

    callbacks?.onMark?.("mark-1");

    expect(sendMark).not.toHaveBeenCalled();
    expect(bridge["acknowledgeMark"]).toHaveBeenCalledTimes(1);
  });

  it("can ignore provider marks", () => {
    let callbacks: Parameters<RealtimeVoiceProviderPlugin["createBridge"]>[0] | undefined;
    const bridge = makeBridge();
    const provider: RealtimeVoiceProviderPlugin = {
      id: "test",
      label: "Test",
      isConfigured: () => true,
      createBridge: (request) => {
        callbacks = request;
        return bridge;
      },
    };
    const sendMark = vi.fn();

    createRealtimeVoiceBridgeSession({
      provider,
      providerConfig: {},
      audioSink: { sendAudio: vi.fn(), sendMark },
      markStrategy: "ignore",
    });

    callbacks?.onMark?.("mark-1");

    expect(sendMark).not.toHaveBeenCalled();
    expect(bridge["acknowledgeMark"]).not.toHaveBeenCalled();
  });

  it("passes tool calls the active session and triggers initial greeting on ready", () => {
    let callbacks: Parameters<RealtimeVoiceProviderPlugin["createBridge"]>[0] | undefined;
    const bridge = makeBridge();
    const provider: RealtimeVoiceProviderPlugin = {
      id: "test",
      label: "Test",
      isConfigured: () => true,
      createBridge: (request) => {
        callbacks = request;
        return bridge;
      },
    };
    const onToolCall = vi.fn();

    const session = createRealtimeVoiceBridgeSession({
      provider,
      providerConfig: {},
      audioSink: { sendAudio: vi.fn() },
      initialGreetingInstructions: "Say hello",
      triggerGreetingOnReady: true,
      onToolCall,
    });
    const event = {
      itemId: "item-1",
      callId: "call-1",
      name: "lookup",
      args: { q: "test" },
    };

    callbacks?.onReady?.();
    callbacks?.onToolCall?.(event);

    expect(bridge["triggerGreeting"]).toHaveBeenCalledWith("Say hello");
    expect(onToolCall).toHaveBeenCalledWith(event, session);
  });

  it("forwards tool result continuation options to the provider bridge", () => {
    const bridge = makeBridge();
    const provider: RealtimeVoiceProviderPlugin = {
      id: "test",
      label: "Test",
      isConfigured: () => true,
      createBridge: () => bridge,
    };
    const session = createRealtimeVoiceBridgeSession({
      provider,
      providerConfig: {},
      audioSink: { sendAudio: vi.fn() },
    });

    session.submitToolResult("call-1", { status: "working" }, { willContinue: true });

    expect(bridge["submitToolResult"]).toHaveBeenCalledWith(
      "call-1",
      { status: "working" },
      { willContinue: true },
    );
  });

  it("does not expose session callbacks until the provider returns its bridge", () => {
    let callbacks: Parameters<RealtimeVoiceProviderPlugin["createBridge"]>[0] | undefined;
    const bridge = makeBridge();
    const onReady = vi.fn();
    const onToolCall = vi.fn();
    const event = {
      itemId: "item-1",
      callId: "call-1",
      name: "lookup",
      args: {},
    };
    const provider: RealtimeVoiceProviderPlugin = {
      id: "test",
      label: "Test",
      isConfigured: () => true,
      createBridge: (request) => {
        callbacks = request;
        request.onReady?.();
        request.onToolCall?.(event);
        return bridge;
      },
    };

    const session = createRealtimeVoiceBridgeSession({
      provider,
      providerConfig: {},
      audioSink: { sendAudio: vi.fn() },
      onReady,
      onToolCall,
    });

    expect(onReady).not.toHaveBeenCalled();
    expect(onToolCall).not.toHaveBeenCalled();

    callbacks?.onReady?.();
    callbacks?.onToolCall?.(event);

    expect(onReady).toHaveBeenCalledWith(session);
    expect(onToolCall).toHaveBeenCalledWith(event, session);
  });
});
