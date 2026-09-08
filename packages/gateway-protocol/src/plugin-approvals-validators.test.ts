import { describe, expect, it } from "vitest";
import {
  validatePluginApprovalRequestParams,
  validatePluginApprovalResolveParams,
} from "./index.js";

const nullableMetadataFields = [
  "pluginId",
  "detail",
  "severity",
  "scope",
  "toolName",
  "toolCallId",
  "allowedDecisions",
  "agentId",
  "sessionKey",
  "approvalReviewerDeviceIds",
  "turnSourceChannel",
  "turnSourceTo",
  "turnSourceAccountId",
  "turnSourceThreadId",
] as const;

describe("plugin approval protocol validators", () => {
  it("validates bounded reviewer-only detail independently from the description", () => {
    const request = {
      title: "Apply workspace skill proposal",
      description: "d".repeat(512),
    };

    expect(validatePluginApprovalRequestParams(request)).toBe(true);
    expect(validatePluginApprovalRequestParams({ ...request, detail: "full tool input" })).toBe(
      true,
    );
    expect(validatePluginApprovalRequestParams({ ...request, detail: "" })).toBe(false);
    expect(validatePluginApprovalRequestParams({ ...request, detail: "x".repeat(16_385) })).toBe(
      false,
    );
    expect(validatePluginApprovalRequestParams({ ...request, description: "d".repeat(513) })).toBe(
      false,
    );
  });

  it.each(nullableMetadataFields)("accepts explicit null for optional %s metadata", (field) => {
    expect(
      validatePluginApprovalRequestParams({
        title: "Apply workspace skill proposal",
        description: "Apply the pending proposal",
        [field]: null,
      }),
    ).toBe(true);
  });
});

describe("artifact review protocol compatibility", () => {
  const binding = {
    operation_id: "operation:test",
    event_id: "event:current",
    artifact_sha256: ["a".repeat(64)],
  };
  const request = {
    kind: "artifact_review",
    binding,
    idempotency_key: "request:key",
    title: "Review",
    description: "Technical artifact",
  };
  it("admits the existing artifact request and explicit disposition without execution fields", () => {
    expect(validatePluginApprovalRequestParams(request)).toBe(true);
    for (const decision of ["accept_artifact", "reject_artifact"]) {
      expect(
        validatePluginApprovalResolveParams({
          kind: "artifact_review",
          binding,
          idempotency_key: "decision:key",
          id: "review:test",
          decision,
        }),
      ).toBe(true);
    }
    expect(
      validatePluginApprovalRequestParams({ ...request, allowedDecisions: ["allow-always"] }),
    ).toBe(false);
    expect(
      validatePluginApprovalResolveParams({
        kind: "artifact_review",
        binding,
        idempotency_key: "decision:key",
        id: "review:test",
        decision: "allow-once",
      }),
    ).toBe(false);
    expect(
      validatePluginApprovalRequestParams({
        title: "Review",
        description: "Technical artifact",
        binding,
      }),
    ).toBe(false);
  });
  it("rejects spoofed identity, duplicate artifacts and mixed channel-reviewer authority", () => {
    expect(validatePluginApprovalRequestParams({ ...request, actor_device_id: "spoofed" })).toBe(
      false,
    );
    expect(
      validatePluginApprovalRequestParams({
        ...request,
        binding: { ...binding, artifact_sha256: ["a".repeat(64), "a".repeat(64)] },
      }),
    ).toBe(false);
    expect(
      validatePluginApprovalResolveParams({
        kind: "artifact_review",
        binding,
        idempotency_key: "decision:key",
        id: "review:test",
        decision: "accept_artifact",
        reviewer: {},
      }),
    ).toBe(false);
  });
});
