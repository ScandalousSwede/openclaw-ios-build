/* @vitest-environment jsdom */
import { afterEach, beforeEach, expect, vi } from "vitest";
import { OperationalView } from "./operational-view.ts";

export const item = {
  operation_id: "external-held-out",
  task_id: "repair",
  event_id: "event-a",
  title: "Reader correction",
  source: "external-harness",
  kind: "result",
  state: "verified",
  occurred_at: "2026-09-06T18:00:00Z",
  observed_at: "2026-09-06T18:01:00Z",
  artifacts: [],
  owner_accepted: false,
};
export const page = {
  items: [item],
  coverage: {
    scope: { corpus: "canonical_federation_observations", project: "Argus" },
    complete: false,
    has_more: true,
    snapshot_sequence: 3,
    observed_at: item.observed_at,
  },
  next_cursor: "next",
};
export async function mount(
  request = vi.fn().mockResolvedValue(page),
  connected = true,
  reviewAvailable = false,
  pendingReviews: unknown[] = [],
) {
  const element = new OperationalView();
  type Snapshot = {
    phase: string;
    client: { request: typeof request };
    hello: { auth: { role: string; scopes: string[] } };
  };
  const listeners = new Set<(snapshot: Snapshot) => void>();
  const gateway = {
    snapshot: {
      phase: connected ? "connected" : "stopped",
      client: { request },
      hello: { auth: { role: "operator", scopes: ["operator.read"] } },
    },
    subscribe: vi.fn((listener: (snapshot: Snapshot) => void) => {
      listeners.add(listener);
      return () => listeners.delete(listener);
    }),
  };
  const overlays = {
    snapshot: { artifactReviewAvailable: reviewAvailable, pendingArtifactReviews: pendingReviews },
    subscribe: () => () => {},
    refreshApprovals: vi.fn().mockResolvedValue(false),
  };
  Object.assign(element, { context: { gateway, overlays } });
  document.body.append(element);
  await vi.waitFor(() =>
    expect(element.textContent).toContain(connected ? "Reader correction" : "Disconnected"),
  );
  await element.updateComplete;
  return {
    element,
    gateway,
    overlays,
    request,
    setScopes: (scopes: string[]) => {
      gateway.snapshot = { ...gateway.snapshot, hello: { auth: { role: "operator", scopes } } };
      for (const listener of listeners) {
        listener(gateway.snapshot);
      }
    },
    setConnected: (next: boolean) => {
      gateway.snapshot = { ...gateway.snapshot, phase: next ? "connected" : "stopped" };
      for (const listener of listeners) {
        listener(gateway.snapshot);
      }
    },
  };
}
export function setupOperationalViewTests() {
  beforeEach(() => {
    window.history.replaceState({}, "", "/overview");
  });
  afterEach(() => {
    document.body.replaceChildren();
    vi.restoreAllMocks();
    vi.useRealTimers();
  });
}
