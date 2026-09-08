// Covers heartbeat sender selection when delivery target differs.
import { describe, expect, it, vi } from "vitest";
import { resolveCommandAuthorization } from "../auto-reply/command-auth.js";
import type { OpenClawConfig } from "../config/config.js";
import { runHeartbeatOnce } from "./heartbeat-runner.js";
import { installHeartbeatRunnerTestRuntime } from "./heartbeat-runner.test-harness.js";
import { seedMainSessionStore, withTempHeartbeatSandbox } from "./heartbeat-runner.test-utils.js";

installHeartbeatRunnerTestRuntime({ includeSlack: true });

describe("runHeartbeatOnce", () => {
  it("uses the delivery target as sender when lastTo differs", async () => {
    await withTempHeartbeatSandbox(
      async ({ tmpDir, storePath, replySpy }) => {
        const cfg: OpenClawConfig = {
          agents: {
            defaults: {
              workspace: tmpDir,
              heartbeat: {
                every: "5m",
                target: "slack",
                to: "C0A9P2N8QHY",
              },
            },
          },
          session: { store: storePath },
        };

        await seedMainSessionStore(storePath, cfg, {
          lastChannel: "telegram",
          lastProvider: "telegram",
          lastTo: "1644620762",
        });

        replySpy.mockImplementation(async (ctx: { To?: string; From?: string }) => {
          expect(ctx.To).toBe("C0A9P2N8QHY");
          expect(ctx.From).toBe("C0A9P2N8QHY");
          return { text: "ok" };
        });

        const sendSlack = vi.fn().mockResolvedValue({
          messageId: "m1",
          channelId: "C0A9P2N8QHY",
        });

        await runHeartbeatOnce({
          cfg,
          deps: {
            getReplyFromConfig: replySpy,
            slack: sendSlack,
            getQueueSize: () => 0,
            nowMs: () => 0,
          },
        });

        expect(sendSlack).toHaveBeenCalled();
      },
      { prefix: "openclaw-hb-" },
    );
  });
  it.each([true, false])(
    "preserves explicit owner identity with blocked direct delivery (owner=%s)",
    async (isOwner) => {
      await withTempHeartbeatSandbox(async ({ tmpDir, storePath, replySpy }) => {
        const cfg: OpenClawConfig = {
          agents: {
            defaults: {
              workspace: tmpDir,
              heartbeat: {
                every: "5m",
                target: "last",
                directPolicy: "block",
              },
            },
          },
          channels: {
            telegram: { allowFrom: ["123"] },
            whatsapp: { allowFrom: ["+15555550100"] },
          },
          commands: { ownerAllowFrom: [`telegram:${isOwner ? "123" : "456"}`] },
          session: { store: storePath },
        };
        await seedMainSessionStore(storePath, cfg, {
          lastChannel: "telegram",
          lastProvider: "telegram",
          lastTo: "123",
        });
        const sendTelegram = vi.fn();
        replySpy.mockResolvedValue({ text: "checked" });
        await runHeartbeatOnce({
          cfg,
          deps: {
            getReplyFromConfig: replySpy,
            telegram: sendTelegram,
            getQueueSize: () => 0,
            nowMs: () => 0,
          },
        });
        expect(replySpy).toHaveBeenCalledTimes(1);
        const ctx = replySpy.mock.calls[0]![0];
        expect(ctx.InternalTurnSource).toBe("heartbeat");
        expect(ctx.OriginatingChannel).toBeUndefined();
        expect(ctx.OriginatingTo).toBeUndefined();
        const auth = resolveCommandAuthorization({ ctx, cfg, commandAuthorized: true });
        expect(auth.providerId).toBe("telegram");
        expect(auth.senderIsOwner).toBe(isOwner);
        expect(sendTelegram).not.toHaveBeenCalled();
      });
    },
  );
});
