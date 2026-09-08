import { describe, expect, it } from "vitest";
import type { OpenClawConfig } from "../config/config.js";
import { bindScheduledSenderChannel, resolveCommandAuthorization } from "./command-auth.js";
import { finalizeInboundContext } from "./reply/inbound-context.js";
import type { MsgContext } from "./templating.js";
import { installDiscordRegistryHooks } from "./test-helpers/command-auth-registry-fixture.js";

installDiscordRegistryHooks();
const cfg: OpenClawConfig = {
  channels: { discord: { allowFrom: ["123"] }, whatsapp: { allowFrom: ["+15555550100"] } },
  commands: { ownerAllowFrom: ["discord:123"] },
};
const context = (sender = "123"): MsgContext => ({
  InternalTurnSource: "cron",
  From: sender,
  To: sender,
});
const owner = (ctx: MsgContext, config = cfg) =>
  resolveCommandAuthorization({ ctx, cfg: config, commandAuthorized: true }).senderIsOwner;

describe("process-local scheduled sender authorization", () => {
  it.each(["cron", "heartbeat", "exec"] as const)(
    "resolves explicit owners for %s without adding a delivery route",
    (source) => {
      const ctx = { ...context(), InternalTurnSource: source };
      const before = JSON.stringify(ctx);
      expect(owner(ctx)).toBe(false);
      bindScheduledSenderChannel(ctx, "discord");
      expect(owner(finalizeInboundContext(ctx))).toBe(true);
      expect(ctx).not.toHaveProperty("OriginatingChannel");
      expect(ctx).not.toHaveProperty("Surface");
      expect(
        JSON.stringify({ InternalTurnSource: ctx.InternalTurnSource, From: ctx.From, To: ctx.To }),
      ).toBe(before);
    },
  );
  it("rejects non-owners and preserves existing channel owner rules", () => {
    const ctx = context("456");
    bindScheduledSenderChannel(ctx, "discord");
    expect(owner(ctx)).toBe(false);
    const allowed = context();
    bindScheduledSenderChannel(allowed, "discord");
    const channelPolicyOnly = { channels: cfg.channels };
    expect(owner(allowed, channelPolicyOnly)).toBe(
      owner({ ...context(), Provider: "discord" }, channelPolicyOnly),
    );
    expect(owner(allowed, { channels: { discord: {} } })).toBe(false);
  });
  it("does not carry the attachment through object copies or JSON replay", () => {
    const ctx = context();
    bindScheduledSenderChannel(ctx, "discord");
    expect(owner(ctx)).toBe(true);
    expect(owner({ ...ctx })).toBe(false);
    const wire = JSON.stringify(ctx);
    expect(owner(JSON.parse(wire))).toBe(false);
    expect(owner(structuredClone(ctx))).toBe(false);
    expect(
      owner({
        ...context(),
        scheduledSenderChannel: "discord",
        SenderAuthorizationChannel: "discord",
      } as MsgContext),
    ).toBe(false);
  });
  it.each([
    "Provider",
    "Surface",
    "OriginatingChannel",
    "From",
    "To",
    "SenderId",
    "SenderE164",
    "AccountId",
    "SessionKey",
    "ChatType",
  ] as const)("rejects a binding after identity field %s changes", (field) => {
    const ctx = context();
    bindScheduledSenderChannel(ctx, "discord");
    ctx[field] = "changed";
    expect(owner(ctx)).toBe(false);
  });
  it.each([undefined, "", "unknown-provider"])(
    "does not bind unknown sender channel %s",
    (channel) => {
      const ctx = context();
      bindScheduledSenderChannel(ctx, channel);
      expect(owner(ctx)).toBe(false);
    },
  );
  it("cannot attach scheduled authorization to an unrelated provider", () => {
    const ctx = { ...context(), InternalTurnSource: undefined, Provider: "untrusted-event" };
    bindScheduledSenderChannel(ctx, "discord");
    expect(owner(ctx)).toBe(false);
  });
  it("preserves ordinary direct-message ownership", () => {
    const ctx = {
      ...context(),
      InternalTurnSource: undefined,
      Provider: "discord",
      Surface: "discord",
      SenderId: "123",
    };
    bindScheduledSenderChannel(ctx, "whatsapp");
    expect(owner(ctx)).toBe(true);
  });
  it("invalidates changed wake source and rechecks current owner policy", () => {
    const ctx = context();
    bindScheduledSenderChannel(ctx, "discord");
    expect(owner(ctx)).toBe(true);
    expect(owner(ctx, { ...cfg, commands: { ownerAllowFrom: ["discord:456"] } })).toBe(false);
    ctx.InternalTurnSource = "exec";
    expect(owner(ctx)).toBe(false);
  });
});
