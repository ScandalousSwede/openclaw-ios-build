import { expectDefined } from "@openclaw/normalization-core";
import { expect, it, vi } from "vitest";
import { createPluginApprovalHandlers } from "./plugin-approval.js";
import {
  createApprovalContext,
  createClient,
  createManager,
  createMockOptions,
} from "./plugin-approval.test-support.js";
it("keeps artifact pending lists opt-in and binds list authorization to the authenticated client", async (t) => {
  const list = vi.fn().mockResolvedValue([]);
  const handlers = createPluginApprovalHandlers(createManager(t), {
    artifactReview: { request: vi.fn(), resolve: vi.fn(), list },
  });
  const client = createClient({ deviceId: "device-owner", scopes: ["operator.approvals"] })!;
  client.connect.role = "operator";
  const legacy = createMockOptions("plugin.approval.list", {}, { client });
  await expectDefined(
    handlers["plugin.approval.list"],
    "expected registered approval handler",
  )(legacy);
  expect(legacy.respond).toHaveBeenCalledWith(true, [], undefined);
  expect(list).not.toHaveBeenCalled();
  const selected = createMockOptions(
    "plugin.approval.list",
    { kind: "artifact_review" },
    { client },
  );
  await expectDefined(
    handlers["plugin.approval.list"],
    "expected registered approval handler",
  )(selected);
  expect(list).toHaveBeenCalledWith(
    expect.objectContaining({ device_id: "device-owner", connection_id: "conn-test-client" }),
  );
  expect(selected.respond).toHaveBeenCalledWith(true, { available: true, items: [] }, undefined);
  const spoofed = createMockOptions(
    "plugin.approval.list",
    { kind: "artifact_review", actor: "other" },
    { client },
  );
  await expectDefined(
    handlers["plugin.approval.list"],
    "expected registered approval handler",
  )(spoofed);
  expect(spoofed.respond).toHaveBeenCalledWith(
    false,
    undefined,
    expect.objectContaining({ message: "Artifact review unavailable or invalid" }),
  );
  const unbound = createMockOptions("plugin.approval.list", { kind: "artifact_review" });
  await expectDefined(
    handlers["plugin.approval.list"],
    "expected registered approval handler",
  )(unbound);
  expect(list).toHaveBeenCalledTimes(1);
});

it("routes artifact request and resolution through canonical receipts without execution records", async (t) => {
  const binding = {
    operation_id: "operation:test",
    event_id: "event:current",
    artifact_sha256: ["a".repeat(64)],
  };
  const manager = createManager(t);
  const request = vi.fn(async (command, actor) => ({
    id: "review:test",
    binding: command.binding,
    actor_device_id: actor.device_id,
    canonical_event_id: "canonical:request",
    idempotency_key: command.idempotency_key,
    state: "pending" as const,
  }));
  const resolve = vi.fn(async (command, actor) => ({
    id: command.id,
    binding: command.binding,
    actor_device_id: actor.device_id,
    canonical_event_id: "canonical:resolve",
    idempotency_key: command.idempotency_key,
    state: "accepted" as const,
  }));
  const handlers = createPluginApprovalHandlers(manager, { artifactReview: { request, resolve } });
  const client = createClient({ deviceId: "device-owner", scopes: ["operator.approvals"] })!;
  client.connect.role = "operator";
  const requested = createMockOptions(
    "plugin.approval.request",
    {
      kind: "artifact_review",
      binding,
      idempotency_key: "request:key",
      title: "Review",
      description: "Technical artifact",
    },
    { client },
  );
  await expectDefined(
    handlers["plugin.approval.request"],
    "expected registered approval handler",
  )(requested);
  expect(requested.respond).toHaveBeenCalledWith(
    true,
    expect.objectContaining({ state: "pending", actor_device_id: "device-owner" }),
    undefined,
  );
  const resolved = createMockOptions(
    "plugin.approval.resolve",
    {
      kind: "artifact_review",
      binding,
      idempotency_key: "resolve:key",
      id: "review:test",
      decision: "accept_artifact",
    },
    { client },
  );
  await expectDefined(
    handlers["plugin.approval.resolve"],
    "expected registered approval handler",
  )(resolved);
  expect(resolved.respond).toHaveBeenCalledWith(
    true,
    expect.objectContaining({ state: "accepted", canonical_event_id: "canonical:resolve" }),
    undefined,
  );
  expect(manager.listPendingRecords()).toEqual([]);
  expect(requested.context.broadcast).not.toHaveBeenCalled();
});

it.for(["profile", "internal operator"] as const)(
  "preserves current profile isolation for sessionless artifact review via %s",
  async (identity, t) => {
    const list = vi.fn().mockResolvedValue([]);
    const request = vi.fn();
    const resolve = vi.fn();
    const handlers = createPluginApprovalHandlers(createManager(t), {
      artifactReview: { list, request, resolve },
    });
    const client = createClient({ deviceId: "device-profile", scopes: ["operator.approvals"] })!;
    client.connect.role = "operator";
    client.authenticatedUserProfile = {
      profileId: "profile-artifact-isolated",
      displayName: "Synthetic",
      hasAvatar: false,
      updatedAt: 1,
    };
    if (identity === "internal operator") {
      client.authenticatedUserProfile = undefined;
      client.internal = {
        operatorRoleActor: { kind: "operator", profileId: "profile-artifact-isolated" },
      };
    }
    const context = createApprovalContext();
    context.getRuntimeConfig = () => ({
      gateway: {
        roles: {
          default: "isolated",
          definitions: {
            isolated: { sessions: { others: "none" }, agents: "*", scopes: ["operator.approvals"] },
          },
        },
      },
    });
    const binding = {
      operation_id: "operation:test",
      event_id: "event:current",
      artifact_sha256: ["a".repeat(64)],
    };
    for (const [method, params] of [
      ["plugin.approval.list", { kind: "artifact_review" }],
      [
        "plugin.approval.request",
        {
          kind: "artifact_review",
          binding,
          idempotency_key: "request:key",
          title: "Review",
          description: "Technical artifact",
        },
      ],
      [
        "plugin.approval.resolve",
        {
          kind: "artifact_review",
          binding,
          idempotency_key: "resolve:key",
          id: "review:test",
          decision: "accept_artifact",
        },
      ],
    ] as const) {
      const options = createMockOptions(method, params, { client, context });
      await expectDefined(handlers[method], "expected registered approval handler")(options);
      expect(options.respond).toHaveBeenCalledWith(
        false,
        undefined,
        expect.objectContaining({ message: "Artifact review unavailable or invalid" }),
      );
    }
    expect(list).not.toHaveBeenCalled();
    expect(request).not.toHaveBeenCalled();
    expect(resolve).not.toHaveBeenCalled();
    client.connect.scopes = ["operator.admin"];
    const admin = createMockOptions(
      "plugin.approval.list",
      { kind: "artifact_review" },
      { client, context },
    );
    await expectDefined(
      handlers["plugin.approval.list"],
      "expected registered approval handler",
    )(admin);
    expect(admin.respond).toHaveBeenCalledWith(true, { available: true, items: [] }, undefined);
  },
);
