import { expect, it } from "vitest";
import { isArtifactReviewActorAuthorized } from "./artifact-review-policy.js";
const request = {
  id: "synthetic-review",
  requested_by_device_id: "requester",
  reviewer_device_ids: ["assigned"],
};
const actor = (device_id: string, scopes = ["operator.approvals"]) => ({
  device_id,
  scopes,
  connection_id: "connection",
});
it("preserves incumbent admin, explicit reviewer and bound requester authorization", () => {
  expect(isArtifactReviewActorAuthorized(actor("admin", ["operator.admin"]), request)).toBe(true);
  expect(isArtifactReviewActorAuthorized(actor("assigned"), request)).toBe(true);
  expect(isArtifactReviewActorAuthorized(actor("requester"), request)).toBe(true);
  expect(isArtifactReviewActorAuthorized(actor("unrelated"), request)).toBe(false);
});
it("does not inherit legacy unbound, connection-only or read-only approval access", () => {
  expect(isArtifactReviewActorAuthorized(actor("requester", ["operator.read"]), request)).toBe(
    false,
  );
  expect(isArtifactReviewActorAuthorized(actor("assigned", []), request)).toBe(false);
  expect(isArtifactReviewActorAuthorized(actor(""), request)).toBe(false);
  expect(
    isArtifactReviewActorAuthorized(actor("admin", ["operator.admin"]), {
      ...request,
      requested_by_device_id: "",
    }),
  ).toBe(false);
  expect(isArtifactReviewActorAuthorized(actor("connection"), request)).toBe(false);
});
it("retains device binding across reconnects without mutating durable metadata", () => {
  const bound = Object.freeze({ ...request, reviewer_device_ids: Object.freeze(["assigned"]) });
  expect(
    isArtifactReviewActorAuthorized(
      { ...actor("requester"), connection_id: "new-connection" },
      bound,
    ),
  ).toBe(true);
  expect(bound.reviewer_device_ids).toEqual(["assigned"]);
});
