import { isRecord } from "@openclaw/normalization-core/record-coerce";
import type { ExecApprovalRequest } from "./exec-approval.ts";

export function parseArtifactReviewPending(payload: unknown): ExecApprovalRequest | null {
  if (
    !isRecord(payload) ||
    typeof payload.id !== "string" ||
    !/^[A-Za-z0-9_.:-]{1,512}$/.test(payload.id) ||
    typeof payload.created_at_ms !== "number" ||
    typeof payload.expires_at_ms !== "number" ||
    !Number.isSafeInteger(payload.created_at_ms) ||
    !Number.isSafeInteger(payload.expires_at_ms) ||
    payload.created_at_ms <= 0 ||
    payload.expires_at_ms <= payload.created_at_ms ||
    !isRecord(payload.binding)
  ) {
    return null;
  }
  const binding = payload.binding;
  if (
    typeof binding.operation_id !== "string" ||
    !/^[A-Za-z0-9_.:-]{1,512}$/.test(binding.operation_id) ||
    typeof binding.event_id !== "string" ||
    !/^[A-Za-z0-9_.:-]{1,512}$/.test(binding.event_id) ||
    !Array.isArray(binding.artifact_sha256) ||
    !binding.artifact_sha256.length ||
    binding.artifact_sha256.length > 64 ||
    !binding.artifact_sha256.every(
      (hash): hash is string => typeof hash === "string" && /^[a-f0-9]{64}$/.test(hash),
    ) ||
    new Set(binding.artifact_sha256).size !== binding.artifact_sha256.length
  ) {
    return null;
  }
  const copied = {
    operation_id: binding.operation_id,
    event_id: binding.event_id,
    artifact_sha256: [...binding.artifact_sha256],
  };
  return {
    id: payload.id,
    kind: "artifact_review",
    request: { command: "Review current artifact" },
    pluginTitle: "Review current artifact",
    pluginDescription: `Operation: ${copied.operation_id}\nEvent: ${copied.event_id}\nSHA-256: ${copied.artifact_sha256.join(", ")}\nThis records your authenticated operator disposition; it does not approve execution or establish scientific correctness.`,
    createdAtMs: payload.created_at_ms,
    expiresAtMs: payload.expires_at_ms,
    artifactReview: { binding: copied },
  };
}
