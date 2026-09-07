import { isApprovalRecordVisibleToClient } from "./approval-shared.js";
import type { ArtifactReviewActor } from "./artifact-review.js";

/** Loaded from the incumbent durable request, never from a resolve RPC payload. */
export type ArtifactReviewApprovalIdentity = Readonly<{
  id: string;
  requested_by_device_id: string;
  reviewer_device_ids: readonly string[];
}>;

/**
 * Reuse operator approval visibility policy with a mandatory durable requester binding.
 * This authorizes an authenticated operator disposition, never a named person's acceptance.
 * The canonical adapter must recheck this identity, expiry, current artifact binding and
 * idempotency atomically before committing. No pending request is stored here.
 */
export function isArtifactReviewActorAuthorized(
  actor: ArtifactReviewActor,
  request: ArtifactReviewApprovalIdentity,
): boolean {
  if (
    !actor.device_id ||
    !request.requested_by_device_id ||
    !actor.scopes.some((scope) => scope === "operator.admin" || scope === "operator.approvals")
  ) {
    return false;
  }
  return isApprovalRecordVisibleToClient({
    record: {
      id: request.id,
      request: {},
      createdAtMs: 0,
      expiresAtMs: 0,
      requestedByDeviceId: request.requested_by_device_id,
      approvalReviewerDeviceIds: [...request.reviewer_device_ids],
    },
    client: {
      connId: actor.connection_id,
      connect: { scopes: actor.scopes, device: { id: actor.device_id } },
    },
  });
}
