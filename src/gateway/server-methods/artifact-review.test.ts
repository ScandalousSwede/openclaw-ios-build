import { strict as assert } from "node:assert";
import { test } from "vitest";
import { routeArtifactReview } from "./artifact-review.ts";
import type { ArtifactReviewAdapter, ArtifactReviewReceipt } from "./artifact-review.ts";
const hash = "a".repeat(64);
const binding = { operation_id: "operation:test", event_id: "event:1", artifact_sha256: [hash] };
const client = {
  connId: "connection:1",
  connect: { role: "operator", device: { id: "device:owner" }, scopes: ["operator.approvals"] },
};
const request = {
  kind: "artifact_review",
  title: "Review synthetic artifact",
  description: "Display-only synthetic evidence review",
  binding,
  idempotency_key: "request:key",
};
const resolve = {
  kind: request.kind,
  binding: request.binding,
  id: "review:1",
  idempotency_key: "resolve:key",
  decision: "accept_artifact",
};
function fixture() {
  let calls = 0;
  const adapter: ArtifactReviewAdapter = {
    async request(command, actor) {
      calls++;
      assert.ok(Object.isFrozen(actor));
      assert.ok(Object.isFrozen(actor.scopes));
      assert.ok(Object.isFrozen(command.binding.artifact_sha256));
      return {
        id: "review:1",
        binding: command.binding,
        actor_device_id: actor.device_id,
        canonical_event_id: "canonical:request",
        idempotency_key: command.idempotency_key,
        state: "pending",
      };
    },
    async resolve(command, actor) {
      calls++;
      return {
        id: command.id,
        binding: command.binding,
        actor_device_id: actor.device_id,
        canonical_event_id: "canonical:decision",
        idempotency_key: command.idempotency_key,
        state: command.decision === "accept_artifact" ? "accepted" : "rejected",
      };
    },
  };
  return { adapter, calls: () => calls };
}
const invalid = (promise: Promise<unknown>) =>
  assert.rejects(promise, /^Error: Artifact review unavailable or invalid$/);
test("legacy execution arm is untouched and never invokes adapter", async () => {
  const f = fixture();
  assert.equal(
    await routeArtifactReview({
      method: "resolve",
      input: { id: "old", decision: "allow-always" },
      client,
      adapter: f.adapter,
    }),
    undefined,
  );
  assert.equal(f.calls(), 0);
});
test("artifact arm is disabled without explicit trusted adapter", async () => {
  await invalid(routeArtifactReview({ method: "request", input: request, client }));
});
test("request uses authenticated device and copied immutable binding", async () => {
  const f = fixture();
  const result = await routeArtifactReview({
    method: "request",
    input: request,
    client,
    adapter: f.adapter,
  });
  assert.equal(result?.actor_device_id, "device:owner");
  assert.equal(result?.state, "pending");
  assert.notEqual(result?.binding, binding);
  assert.equal(Object.isFrozen(binding), false);
});
test("explicit acceptance/rejection remain distinct from execution permission", async () => {
  const f = fixture();
  for (const [decision, state] of [
    ["accept_artifact", "accepted"],
    ["reject_artifact", "rejected"],
  ]) {
    const result = await routeArtifactReview({
      method: "resolve",
      input: { ...resolve, decision },
      client,
      adapter: f.adapter,
    });
    assert.equal(result?.state, state);
  }
  for (const decision of ["allow-once", "allow-always", "deny"]) {
    await invalid(
      routeArtifactReview({
        method: "resolve",
        input: { ...resolve, decision },
        client,
        adapter: f.adapter,
      }),
    );
  }
  assert.equal(f.calls(), 2);
});
test("no caller claimed actor, owner flag or extra execution fields", async () => {
  for (const extra of [
    { actor_device_id: "spoof" },
    { senderIsOwner: true },
    { allowedDecisions: ["allow-always"] },
  ]) {
    const f = fixture();
    await invalid(
      routeArtifactReview({
        method: "request",
        input: { ...request, ...extra },
        client,
        adapter: f.adapter,
      }),
    );
    assert.equal(f.calls(), 0);
  }
});
test("missing device, missing scope and nonoperator rejected before callback", async () => {
  const f = fixture();
  for (const connect of [
    { ...client.connect, device: undefined },
    { ...client.connect, scopes: ["operator.read"] },
    { ...client.connect, role: "node" },
  ]) {
    await invalid(
      routeArtifactReview({
        method: "request",
        input: request,
        client: { ...client, connect },
        adapter: f.adapter,
      }),
    );
  }
  assert.equal(f.calls(), 0);
});
test("empty, duplicate or malformed artifact identity rejected", async () => {
  const f = fixture();
  for (const artifact_sha256 of [[], [hash, hash], ["invalid"], Array(65).fill(hash)]) {
    await invalid(
      routeArtifactReview({
        method: "request",
        input: { ...request, binding: { ...binding, artifact_sha256 } },
        client,
        adapter: f.adapter,
      }),
    );
  }
  assert.equal(f.calls(), 0);
});
test("adapter exceptions never leak private text", async () => {
  const f = fixture();
  f.adapter.resolve = async () => {
    throw new Error("synthetic-private-provider-credential");
  };
  await invalid(
    routeArtifactReview({ method: "resolve", input: resolve, client, adapter: f.adapter }),
  );
});
test("unbound or mismatched canonical receipt is refused", async () => {
  for (const extra of [
    { actor_device_id: "other" },
    { state: "pending" },
    { id: "other" },
    { canonical_event_id: "" },
    { binding: { ...binding, event_id: "stale" } },
    { idempotency_key: "other" },
  ]) {
    const f = fixture();
    const original = f.adapter.resolve.bind(f.adapter);
    f.adapter.resolve = async (c, a) =>
      ({ ...(await original(c, a)), ...extra }) as ArtifactReviewReceipt;
    await invalid(
      routeArtifactReview({ method: "resolve", input: resolve, client, adapter: f.adapter }),
    );
  }
});
test("durable adapter can reject stale attempt and conflicting retry without false receipt", async () => {
  const f = fixture();
  let current = binding.event_id;
  let stored: ArtifactReviewReceipt | undefined;
  f.adapter.resolve = async (c, a) => {
    if (
      c.binding.event_id !== current ||
      (stored &&
        (stored.idempotency_key !== c.idempotency_key ||
          stored.state !== (c.decision === "accept_artifact" ? "accepted" : "rejected")))
    ) {
      throw new Error("conflict");
    }
    return (stored ??= {
      id: c.id,
      binding: c.binding,
      actor_device_id: a.device_id,
      canonical_event_id: "decision:1",
      idempotency_key: c.idempotency_key,
      state: c.decision === "accept_artifact" ? "accepted" : "rejected",
    });
  };
  const first = await routeArtifactReview({
    method: "resolve",
    input: resolve,
    client,
    adapter: f.adapter,
  });
  assert.deepEqual(
    await routeArtifactReview({ method: "resolve", input: resolve, client, adapter: f.adapter }),
    first,
  );
  await invalid(
    routeArtifactReview({
      method: "resolve",
      input: { ...resolve, decision: "reject_artifact" },
      client,
      adapter: f.adapter,
    }),
  );
  current = "event:2";
  await invalid(
    routeArtifactReview({ method: "resolve", input: resolve, client, adapter: f.adapter }),
  );
});

test("receipt validation uses frozen command while caller mutates input during await", async () => {
  const f = fixture();
  const mutable = {
    ...resolve,
    binding: { ...binding, artifact_sha256: [...binding.artifact_sha256] },
  };
  let resume!: () => void;
  const suspended = new Promise<void>((done) => {
    resume = done;
  });
  const original = f.adapter.resolve.bind(f.adapter);
  f.adapter.resolve = async (command, actor) => {
    await suspended;
    assert.equal(command.id, "review:1");
    assert.equal(command.decision, "accept_artifact");
    return original(command, actor);
  };
  const pending = routeArtifactReview({
    method: "resolve",
    input: mutable,
    client,
    adapter: f.adapter,
  });
  mutable.id = "spoofed:review";
  mutable.decision = "reject_artifact";
  mutable.binding.event_id = "changed:event";
  mutable.binding.artifact_sha256[0] = "b".repeat(64);
  resume();
  const receipt = await pending;
  assert.equal(receipt?.id, "review:1");
  assert.equal(receipt?.state, "accepted");
  assert.equal(receipt?.binding.event_id, binding.event_id);
  assert.deepEqual(receipt?.binding.artifact_sha256, [hash]);
});
