import { describe, expect, it } from "vitest";
import { parseHandoffPage } from "./handoff-contract.ts";
export const receipt = {
  handoff_id: "synthetic-handoff",
  summary: "Inspect a technical regression",
  binding: { thread_id: "thread-1", workspace: "/synthetic/work", agent_id: "main" },
  content_sha256: "a".repeat(64),
  state: "acknowledged",
  operation_id: "harness-handoff:synthetic-handoff",
  request_event_id: "event-1",
  canonical_event_id: "event-2",
  queued_at: "2026-09-07T06:00:00Z",
  updated_at: "2026-09-07T06:01:00Z",
  submission_sequence: 20,
  owner_accepted: false,
};
export const page = {
  items: [receipt],
  has_more: false,
  next_before_sequence: null,
  order: "newest_submitted_first",
  automatic_wake_enabled: false,
};
describe("handoff receipt contract", () => {
  it("preserves bounded receipt identity and strips unrelated payloads", () => {
    expect(
      parseHandoffPage({ ...page, items: [{ ...receipt, request: "not UI data" }] }).items[0],
    ).toEqual(receipt);
  });
  it.each([
    { ...page, items: [{ ...receipt, owner_accepted: true }] },
    { ...page, items: [{ ...receipt, state: "completed" }] },
    { ...page, automatic_wake_enabled: true },
    { ...page, items: [{ ...receipt, content_sha256: "invalid" }] },
    { ...page, items: [{ ...receipt, operation_id: "harness-handoff:foreign" }] },
    { ...page, has_more: true },
    { ...page, has_more: true, next_before_sequence: 21 },
    { ...page, items: [receipt, receipt] },
  ])("rejects unsupported or inconsistent receipt responses", (value) => {
    expect(() => parseHandoffPage(value)).toThrow();
  });
  it("requires descending continuation within its requested boundary", () => {
    expect(() => parseHandoffPage(page, 20)).toThrow();
    expect(parseHandoffPage(page, 21).items).toHaveLength(1);
  });
  it("accepts the maximum backend handoff identity with its operation prefix", () => {
    const handoff_id = "a".repeat(256);
    expect(
      parseHandoffPage({
        ...page,
        items: [{ ...receipt, handoff_id, operation_id: `harness-handoff:${handoff_id}` }],
      }).items[0].handoff_id,
    ).toHaveLength(256);
  });
});
