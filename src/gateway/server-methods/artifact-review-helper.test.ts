import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, it, vi } from "vitest";
import { createArtifactReviewHelperAdapter } from "./artifact-review-helper.js";
import { routeArtifactReview } from "./artifact-review.js";
const actor = { device_id: "device", connection_id: "connection", scopes: ["operator.approvals"] };
const binding = { operation_id: "operation", event_id: "event", artifact_sha256: ["a".repeat(64)] };
const client = {
  connId: "connection",
  connect: { role: "operator", scopes: ["operator.approvals"], device: { id: "device" } },
};
const helper = (source: string, timeoutMs = 1000) =>
  createArtifactReviewHelperAdapter({
    command: process.execPath,
    args: ["-e", source],
    timeoutMs,
  })!;
it("passes only JSON stdin through fixed executable and validates the existing receipt route", async () => {
  const adapter = helper(
    `let input='';process.stdin.on('data',c=>input+=c);process.stdin.on('end',()=>{const r=JSON.parse(input);console.log(JSON.stringify({id:'review',binding:r.command.binding,actor_device_id:r.actor.device_id,canonical_event_id:'canonical',idempotency_key:r.command.idempotency_key,state:'pending'}))});`,
  );
  const receipt = await routeArtifactReview({
    method: "request",
    adapter,
    client,
    input: {
      kind: "artifact_review",
      binding,
      idempotency_key: "request-key",
      title: "Review",
      description: "Current artifact",
    },
  });
  expect(receipt?.actor_device_id).toBe("device");
  expect(receipt?.state).toBe("pending");
});
it("filters pending records using incumbent authenticated device policy", async () => {
  const row = {
    id: "review",
    binding,
    created_at_ms: Date.now() - 1000,
    expires_at_ms: Date.now() + 60000,
    requested_by_device_id: "device",
    reviewer_device_ids: [],
  };
  const adapter = helper(
    `process.stdin.resume();process.stdin.on('end',()=>console.log(${JSON.stringify(JSON.stringify({ items: [row] }))}));`,
  );
  expect(await adapter.list!(actor)).toHaveLength(1);
  expect(await adapter.list!({ ...actor, device_id: "unrelated" })).toHaveLength(0);
});
it("remains absent by default and rejects untrusted command shapes or excessive timeout", () => {
  expect(createArtifactReviewHelperAdapter(undefined)).toBeUndefined();
  for (const config of [
    { command: "relative" },
    { command: process.execPath, timeoutMs: 15001 },
    { command: process.execPath, args: ["bad\0arg"] },
  ]) {
    expect(() => createArtifactReviewHelperAdapter(config)).toThrow("unavailable");
  }
});
it("sanitizes process errors, invalid UTF8, malformed JSON and bounded output", async () => {
  for (const source of [
    "process.stdout.write('SECRET');process.exit(1)",
    "process.stdout.write(Buffer.from([255]))",
    "process.stdout.write('SECRET')",
    "process.stdout.write('x'.repeat(65537))",
  ]) {
    await expect(helper(source).list!(actor)).rejects.toThrow(
      /^Artifact review unavailable or invalid$/,
    );
  }
});
it("terminates a bounded timed-out child without exposing its command", async () => {
  await expect(helper("setInterval(()=>{},1000)", 100).list!(actor)).rejects.toThrow(
    /^Artifact review unavailable or invalid$/,
  );
});

it("force-terminates a timed-out helper that ignores SIGTERM", async () => {
  const path = join(mkdtempSync(join(tmpdir(), "artifact-helper-test-")), "pid");
  const source = `process.on('SIGTERM',()=>{});require('node:fs').writeFileSync(${JSON.stringify(path)},String(process.pid));setInterval(()=>{},1000);`;
  await expect(helper(source, 300).list!(actor)).rejects.toThrow(
    /^Artifact review unavailable or invalid$/,
  );
  const pid = Number(readFileSync(path, "utf8"));
  await vi.waitFor(() => expect(() => process.kill(pid, 0)).toThrow(), { timeout: 1500 });
});
