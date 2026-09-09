// @vitest-environment node
import { afterEach, describe, expect, it, vi } from "vitest";
import type { ApplicationGatewaySnapshot } from "./gateway.ts";
import { client, createGatewayHarness, flushMicrotasks } from "./overlays-access.test-support.ts";
import { createApplicationOverlays } from "./overlays.ts";

vi.mock("../build-info.ts", () => ({ controlUiBuildDiffersFrom: () => false }));
vi.mock("../lib/toast.ts", () => ({ showToast: vi.fn() }));
afterEach(() => vi.restoreAllMocks());

async function setup() {
  const binding = {
    operation_id: "operation",
    event_id: "event",
    artifact_sha256: ["a".repeat(64)],
  };
  const request = vi.fn(async (method: string, params?: unknown) =>
    method === "plugin.approval.list" && (params as { kind?: string })?.kind === "artifact_review"
      ? {
          available: true,
          items: [
            { id: "review", binding, created_at_ms: 1000, expires_at_ms: Date.now() + 60000 },
          ],
        }
      : [],
  );
  const harness = createGatewayHarness(client(request));
  const overlays = createApplicationOverlays(harness.gateway);
  await flushMicrotasks();
  await vi.waitFor(() => expect(overlays.snapshot.pendingArtifactReviews?.length).toBe(1));
  return { binding, request, harness, overlays };
}

describe("artifact review overlay authority", () => {
  it("finds only the exact pending binding and resolves it without execution permission", async () => {
    const { binding, request, overlays } = await setup();
    try {
      expect(await overlays.refreshApprovals?.({ ...binding, event_id: "corrected-event" })).toBe(
        false,
      );
      expect(await overlays.refreshApprovals?.(binding)).toBe(true);
      await overlays.decideApproval("accept_artifact", "review");
      expect(request).toHaveBeenCalledWith(
        "plugin.approval.resolve",
        expect.objectContaining({
          kind: "artifact_review",
          id: "review",
          decision: "accept_artifact",
          binding,
        }),
      );
      expect(overlays.snapshot.pendingArtifactReviews).toEqual([]);
    } finally {
      overlays.dispose();
    }
  });
  it.each(["disconnect", "grant-revocation", "binding-correction"])(
    "retires a prepared decision on %s",
    async (change) => {
      const { binding, request, harness, overlays } = await setup();
      try {
        let finish!: (value: ArrayBuffer) => void;
        const digest = vi.spyOn(crypto.subtle, "digest").mockImplementation(
          () =>
            new Promise((resolve) => {
              finish = resolve;
            }),
        );
        const deciding = overlays.decideApproval("accept_artifact", "review");
        expect(digest).toHaveBeenCalledOnce();
        if (change === "disconnect") {
          harness.update({ phase: "stopped" });
        }
        if (change === "grant-revocation") {
          harness.update({
            hello: {
              auth: { role: "operator", scopes: ["operator.read"] },
            } as ApplicationGatewaySnapshot["hello"],
          });
        }
        if (change === "binding-correction") {
          binding.event_id = "corrected-event";
          await overlays.refreshApprovals?.();
        }
        finish(new ArrayBuffer(32));
        await deciding;
        expect(request.mock.calls.some(([method]) => method === "plugin.approval.resolve")).toBe(
          false,
        );
      } finally {
        overlays.dispose();
      }
    },
  );
});
