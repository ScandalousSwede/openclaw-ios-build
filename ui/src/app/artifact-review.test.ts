// @vitest-environment node
import { afterEach, describe, expect, it, vi } from "vitest";
import { parseArtifactReviewPending } from "./artifact-review-parser.ts";
import {
  clearExecApprovalTimers,
  refreshPendingApprovalQueue,
  resolveApprovalRequest,
  type ExecApprovalPromptState,
} from "./exec-approval.ts";

const pending = () => ({
  id: "review-technical-result",
  binding: { operation_id: "operation", event_id: "event", artifact_sha256: ["a".repeat(64)] },
  created_at_ms: 1000,
  expires_at_ms: Date.now() + 60_000,
});
afterEach(() => vi.restoreAllMocks());

describe("artifact review in the current approval owner", () => {
  it("keeps a bounded exact binding distinct from execution permission", () => {
    const input = pending();
    const parsed = parseArtifactReviewPending(input)!;
    expect(parsed.kind).toBe("artifact_review");
    expect(parsed.request.allowedDecisions).toBeUndefined();
    expect(parsed.artifactReview?.binding).toEqual(input.binding);
    input.binding.artifact_sha256[0] = "b".repeat(64);
    expect(parsed.artifactReview?.binding.artifact_sha256).toEqual(["a".repeat(64)]);
    expect(
      parseArtifactReviewPending({
        ...pending(),
        binding: { ...pending().binding, artifact_sha256: ["bad"] },
      }),
    ).toBeNull();
    expect(
      parseArtifactReviewPending({
        ...pending(),
        binding: { ...pending().binding, artifact_sha256: ["a".repeat(64), "a".repeat(64)] },
      }),
    ).toBeNull();
  });

  it("reads the dedicated kind alongside ordinary and system-agent queues", async () => {
    const request = vi.fn(async (method: string, params?: unknown): Promise<unknown> => {
      if (
        method === "plugin.approval.list" &&
        (params as { kind?: string })?.kind === "artifact_review"
      ) {
        return { available: true, items: [pending()] };
      }
      return [];
    });
    const state: ExecApprovalPromptState = {
      client: { request },
      execApprovalQueue: [],
      execApprovalBusy: false,
      execApprovalErrors: new Map(),
    };
    try {
      expect(await refreshPendingApprovalQueue(state)).toBe(true);
      expect(state.artifactReviewAvailable).toBe(true);
      expect(state.execApprovalQueue.map((row) => row.kind)).toEqual(["artifact_review"]);
      expect(request).toHaveBeenCalledWith("plugin.approval.list", {});
      expect(request).toHaveBeenCalledWith("openclaw.approval.list", {});
      request.mockImplementation(async () => ({
        available: true,
        items: [pending(), { id: "malformed" }],
      }));
      await refreshPendingApprovalQueue(state);
      expect(state.artifactReviewAvailable).toBe(false);
    } finally {
      clearExecApprovalTimers(state);
    }
  });

  it("does not apply a pending-list result after its connection owner retires", async () => {
    let current = true;
    const state: ExecApprovalPromptState = {
      client: {
        request: async () => {
          current = false;
          return { available: true, items: [pending()] };
        },
      },
      execApprovalQueue: [],
      execApprovalBusy: false,
      execApprovalErrors: new Map(),
    };
    expect(await refreshPendingApprovalQueue(state, { isCurrentClient: () => current })).toBe(
      false,
    );
    expect(state.execApprovalQueue).toEqual([]);
    expect(state.artifactReviewAvailable).not.toBe(true);
  });

  it("submits the exact binding through the existing plugin resolver and stable retry key", async () => {
    const request = vi.fn().mockResolvedValue({});
    const approval = parseArtifactReviewPending(pending())!;
    await resolveApprovalRequest({ request }, approval, "accept_artifact", {
      isCurrent: () => true,
    });
    await resolveApprovalRequest({ request }, approval, "accept_artifact", {
      isCurrent: () => true,
    });
    expect(request).toHaveBeenCalledTimes(2);
    expect(request.mock.calls[0]).toEqual(request.mock.calls[1]);
    expect(request.mock.calls[0]).toEqual([
      "plugin.approval.resolve",
      {
        kind: "artifact_review",
        id: approval.id,
        decision: "accept_artifact",
        binding: approval.artifactReview!.binding,
        idempotency_key: expect.stringMatching(/^artifact-review:[a-f0-9]{64}$/),
      },
    ]);
  });

  it("requires live authority after asynchronous key preparation", async () => {
    let finish!: (value: ArrayBuffer) => void;
    const digest = vi.spyOn(crypto.subtle, "digest").mockImplementation(
      () =>
        new Promise((resolve) => {
          finish = resolve;
        }),
    );
    let current = true;
    const request = vi.fn();
    const result = resolveApprovalRequest(
      { request },
      parseArtifactReviewPending(pending())!,
      "accept_artifact",
      { isCurrent: () => current },
    );
    expect(digest).toHaveBeenCalledOnce();
    current = false;
    finish(new ArrayBuffer(32));
    await expect(result).rejects.toThrow(/authority|current/i);
    expect(request).not.toHaveBeenCalled();
  });

  it("requires an authority owner and refuses execution vocabulary for artifact review", async () => {
    const request = vi.fn();
    const approval = parseArtifactReviewPending(pending())!;
    await expect(
      resolveApprovalRequest({ request }, approval, "accept_artifact"),
    ).rejects.toThrow();
    await expect(
      resolveApprovalRequest({ request }, approval, "allow-always", { isCurrent: () => true }),
    ).rejects.toThrow();
    const expired = { ...approval, expiresAtMs: Date.now() - 1 };
    await expect(
      resolveApprovalRequest({ request }, expired, "accept_artifact", { isCurrent: () => true }),
    ).rejects.toThrow();
    expect(request).not.toHaveBeenCalled();
  });

  it("does not send an artifact decision through an ordinary approval route", async () => {
    const request = vi.fn();
    const approval = { ...parseArtifactReviewPending(pending())!, kind: "exec" as const };
    await expect(
      resolveApprovalRequest({ request }, approval, "reject_artifact", { isCurrent: () => true }),
    ).rejects.toThrow();
    expect(request).not.toHaveBeenCalled();
    await resolveApprovalRequest({ request }, approval, "deny");
    expect(request).toHaveBeenCalledWith("exec.approval.resolve", {
      id: approval.id,
      decision: "deny",
    });
  });
});
