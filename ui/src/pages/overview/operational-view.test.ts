/* @vitest-environment jsdom */
import { afterEach, describe, expect, it, vi } from "vitest";
import { OperationalView } from "./operational-view.ts";

const item = {
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
const page = {
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
async function mount(request = vi.fn().mockResolvedValue(page), connected = true) {
  const element = new OperationalView();
  type Snapshot = { connected: boolean; client: { request: typeof request } };
  const listeners = new Set<(snapshot: Snapshot) => void>();
  const gateway = {
    snapshot: { connected, client: { request } },
    subscribe: vi.fn((listener: (snapshot: Snapshot) => void) => {
      listeners.add(listener);
      return () => listeners.delete(listener);
    }),
  };
  Object.assign(element, { context: { gateway } });
  document.body.append(element);
  await vi.waitFor(() =>
    expect(element.textContent).toContain(connected ? "Reader correction" : "Disconnected"),
  );
  await element.updateComplete;
  return {
    element,
    gateway,
    request,
    setConnected: (next: boolean) => {
      gateway.snapshot = { ...gateway.snapshot, connected: next };
      for (const listener of listeners) listener(gateway.snapshot);
    },
  };
}
afterEach(() => {
  document.body.replaceChildren();
  vi.restoreAllMocks();
});
describe("operational evidence overview", () => {
  it("keeps partial scope and owner acceptance separate from verified execution", async () => {
    const { element } = await mount();
    expect(element.textContent).toContain("Partial coverage");
    expect(element.textContent).toContain("Owner acceptance not recorded");
    expect(element.textContent).not.toContain("all systems nominal");
    expect(element.querySelector('input[type="search"]')).not.toBeNull();
  });
  it("uses the returned continuation and deduplicates repeated operations", async () => {
    const { element, request } = await mount();
    const button = [...element.querySelectorAll("button")].find((node) =>
      node.textContent?.includes("Load more"),
    );
    button?.click();
    await vi.waitFor(() =>
      expect(request).toHaveBeenCalledWith("argus.operations.list", {
        project: "Argus",
        limit: 30,
        cursor: "next",
      }),
    );
    await element.updateComplete;
    expect(element.querySelectorAll("ul > li")).toHaveLength(1);
  });
  it("does not fetch while disconnected or mistake unavailable coverage for zero", async () => {
    const { element, request } = await mount(vi.fn(), false);
    expect(request).not.toHaveBeenCalled();
    expect(element.textContent).not.toContain("0 loaded records");
    expect(element.querySelector("button")?.disabled).toBe(true);
  });
  it("requests the selected operation detail rather than a fixture id", async () => {
    const request = vi
      .fn()
      .mockResolvedValueOnce(page)
      .mockResolvedValueOnce({
        item,
        requested: item,
        timeline: [item],
        coverage: { complete: true, has_more: false },
      });
    const { element } = await mount(request);
    [...element.querySelectorAll("button")]
      .find((node) => node.textContent?.includes("Open work"))
      ?.click();
    await vi.waitFor(() =>
      expect(request).toHaveBeenCalledWith("argus.operations.detail", {
        operation_id: item.operation_id,
      }),
    );
    await element.updateComplete;
    expect(element.textContent).toContain("Operation: external-held-out");
  });
  it("shows a newer observation without inferring supersession or acceptance", async () => {
    const corrected = {
      ...item,
      operation_id: "correction-b",
      title: "Corrected reader result",
      kind: "correction",
    };
    const request = vi
      .fn()
      .mockResolvedValueOnce(page)
      .mockResolvedValueOnce({
        item: corrected,
        requested: item,
        timeline: [corrected, item],
        coverage: { complete: true, has_more: false },
      });
    const { element } = await mount(request);
    [...element.querySelectorAll("button")]
      .find((node) => node.textContent?.includes("Open work"))
      ?.click();
    await vi.waitFor(() =>
      expect(element.textContent).toContain("A newer observation is available for this task."),
    );
    expect(element.querySelector(".argus-detail")?.textContent).toContain(
      "Corrected reader result",
    );
    expect(element.querySelector(".argus-detail")?.textContent).toContain(
      "Owner acceptance not recorded",
    );
  });
  it("refuses an artifact whose returned digest differs from the selected identity", async () => {
    const artifact = { sha256: "a".repeat(64), bytes: 3 };
    const withArtifact = { ...item, artifacts: [artifact] };
    const request = vi
      .fn()
      .mockResolvedValueOnce(page)
      .mockResolvedValueOnce({
        item: withArtifact,
        requested: item,
        timeline: [item],
        coverage: { complete: true, has_more: false },
      })
      .mockResolvedValueOnce({
        sha256: "b".repeat(64),
        bytes: 3,
        mime_type: "text/plain; charset=utf-8",
        content_base64: "YWJj",
      });
    const { element } = await mount(request);
    [...element.querySelectorAll("button")]
      .find((node) => node.textContent?.includes("Open work"))
      ?.click();
    await vi.waitFor(() => expect(element.textContent).toContain("Verify artifact"));
    [...element.querySelectorAll("button")]
      .find((node) => node.textContent?.includes("Verify artifact"))
      ?.click();
    await vi.waitFor(() => expect(element.textContent).toContain("No file was opened"));
    expect(element.querySelector('a[href^="blob:"]')).toBeNull();
  });
  it("loads when the initial connecting client becomes ready without changing identity", async () => {
    const { element, gateway, request, setConnected } = await mount(
      vi.fn().mockResolvedValue(page),
      false,
    );
    const client = gateway.snapshot.client;
    expect(request).not.toHaveBeenCalled();
    setConnected(true);
    await vi.waitFor(() => expect(element.textContent).toContain("Reader correction"));
    expect(gateway.snapshot.client).toBe(client);
    expect(request).toHaveBeenCalledTimes(1);
  });
  it("refreshes after a same-client reconnect and ignores repeated ready snapshots", async () => {
    const newer = { ...page, items: [{ ...item, title: "New evidence after reconnect" }] };
    const request = vi.fn().mockResolvedValueOnce(page).mockResolvedValueOnce(newer);
    const { element, gateway, setConnected } = await mount(request);
    const client = gateway.snapshot.client;
    setConnected(false);
    await element.updateComplete;
    expect(element.textContent).toContain("Disconnected");
    expect(element.textContent).toContain("Reader correction");
    setConnected(true);
    await vi.waitFor(() => expect(element.textContent).toContain("New evidence after reconnect"));
    expect(gateway.snapshot.client).toBe(client);
    expect(request).toHaveBeenCalledTimes(2);
    setConnected(true);
    await element.updateComplete;
    expect(request).toHaveBeenCalledTimes(2);
  });
});
