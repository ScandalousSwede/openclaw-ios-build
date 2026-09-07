/* @vitest-environment jsdom */
import { afterEach, describe, expect, it, vi } from "vitest";
import { HandoffView } from "./handoff-view.ts";
const receipt = {
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
const page = {
  items: [receipt],
  has_more: false,
  next_before_sequence: null,
  order: "newest_submitted_first",
  automatic_wake_enabled: false,
};

async function mount(request = vi.fn().mockResolvedValue(page), connected = true) {
  const element = new HandoffView();
  const listeners = new Set<() => void>();
  const gateway = {
    snapshot: {
      connected,
      client: { request },
      hello: { auth: { role: "operator", scopes: ["operator.read"] } },
    },
    subscribe: (listener: (snapshot: unknown) => void) => {
      const notify = () => listener(gateway.snapshot);
      listeners.add(notify);
      return () => listeners.delete(notify);
    },
  };
  Object.assign(element, { context: { gateway } });
  document.body.append(element);
  await element.updateComplete;
  return {
    element,
    request,
    gateway,
    update: (next: boolean, replace = false, scopes = ["operator.read"]) => {
      gateway.snapshot = {
        connected: next,
        client: replace ? { request } : gateway.snapshot.client,
        hello: { auth: { role: "operator", scopes } },
      };
      for (const notify of listeners) notify();
    },
  };
}
afterEach(() => {
  document.body.replaceChildren();
  vi.restoreAllMocks();
  vi.useRealTimers();
});
const settled = async () => {
  await Promise.resolve();
  await Promise.resolve();
};
describe("handoff receipt panel", () => {
  it("reads existing RPC only and renders acknowledgement without execution authority", async () => {
    const { element, request } = await mount();
    await vi.waitFor(() => expect(element.textContent).toContain("Acknowledged by receiver"));
    expect(request).toHaveBeenCalledExactlyOnceWith("argus.handoffs.list", { limit: 5 });
    expect(element.textContent).toContain(
      "do not establish execution, completion or owner acceptance",
    );
    expect(element.querySelector("details")?.textContent).toContain("event-2");
    expect(element.querySelectorAll("button")).toHaveLength(1);
  });
  it("does not read disconnected and refreshes on same-client readiness edges only", async () => {
    const { element, request, update } = await mount(undefined, false);
    expect(request).not.toHaveBeenCalled();
    expect(element.textContent).toContain("Disconnected");
    update(true);
    await vi.waitFor(() => expect(request).toHaveBeenCalledTimes(1));
    await settled();
    update(true);
    expect(request).toHaveBeenCalledTimes(1);
    update(false);
    update(true);
    await vi.waitFor(() => expect(request).toHaveBeenCalledTimes(2));
  });
  it("ignores old success after a disconnect and new read", async () => {
    let resolveOld!: (value: unknown) => void;
    const request = vi
      .fn()
      .mockImplementationOnce(
        () =>
          new Promise((resolve) => {
            resolveOld = resolve;
          }),
      )
      .mockResolvedValue(page);
    const { element, update } = await mount(request);
    update(false);
    update(true);
    await vi.waitFor(() => expect(element.textContent).toContain(receipt.summary));
    resolveOld({ ...page, items: [{ ...receipt, summary: "Obsolete response" }] });
    await settled();
    await element.updateComplete;
    expect(element.textContent).not.toContain("Obsolete response");
  });
  it("clears receipt metadata and rejects late reads after scope loss", async () => {
    let finish!: (value: unknown) => void;
    const request = vi
      .fn()
      .mockResolvedValueOnce(page)
      .mockImplementationOnce(
        () =>
          new Promise((resolve) => {
            finish = resolve;
          }),
      );
    const { element, update } = await mount(request);
    await vi.waitFor(() => expect(element.textContent).toContain(receipt.summary));
    element.querySelector<HTMLButtonElement>("button")!.click();
    await settled();
    update(true, false, []);
    finish(page);
    await settled();
    await element.updateComplete;
    expect(element.textContent).not.toContain(receipt.summary);
    expect(element.textContent).toContain("Operator read access is required");
    expect(element.querySelector<HTMLButtonElement>("button")?.disabled).toBe(true);
  });
  it("does not cap access to older handoffs after twenty-five records", async () => {
    let sequence = 100;
    const request = vi.fn().mockImplementation(() => {
      const items = Array.from({ length: 5 }, () => {
        const n = sequence--;
        return {
          ...receipt,
          handoff_id: `handoff-${n}`,
          operation_id: `harness-handoff:handoff-${n}`,
          submission_sequence: n,
        };
      });
      return Promise.resolve({
        ...page,
        items,
        has_more: true,
        next_before_sequence: items.at(-1)!.submission_sequence,
      });
    });
    const { element } = await mount(request);
    for (let i = 0; i < 6; i++) {
      await vi.waitFor(() => expect(element.querySelectorAll("button")).toHaveLength(2));
      element.querySelectorAll<HTMLButtonElement>("button")[1]!.click();
      await settled();
      await element.updateComplete;
    }
    await vi.waitFor(() => expect(request).toHaveBeenCalledTimes(7));
    expect(element.querySelectorAll("li")).toHaveLength(5);
    expect(request).toHaveBeenLastCalledWith("argus.handoffs.list", {
      limit: 5,
      before_sequence: 71,
    });
  });
  it("distinguishes loading, valid empty, and sanitized read failure", async () => {
    let resolve!: (value: unknown) => void;
    const request = vi
      .fn()
      .mockImplementationOnce(
        () =>
          new Promise((done) => {
            resolve = done;
          }),
      )
      .mockRejectedValue(new Error("private raw failure"));
    const { element } = await mount(request);
    expect(element.textContent).toContain("Loading handoff receipts");
    expect(element.textContent).not.toContain("No handoff receipts");
    resolve({ ...page, items: [] });
    await vi.waitFor(() => expect(element.textContent).toContain("No handoff receipts"));
    element.querySelector<HTMLButtonElement>("button")!.click();
    await vi.waitFor(() => expect(element.textContent).toContain("unavailable"));
    expect(element.textContent).not.toContain("No handoff receipts");
    expect(element.textContent).not.toContain("private raw failure");
  });
  it("reads older pages with exact server cursor and escapes producer summary", async () => {
    const request = vi
      .fn()
      .mockResolvedValueOnce({ ...page, has_more: true, next_before_sequence: 20 })
      .mockResolvedValueOnce({
        ...page,
        items: [
          {
            ...receipt,
            handoff_id: "older",
            operation_id: "harness-handoff:older",
            submission_sequence: 19,
            summary: "<script>untrusted</script>",
          },
        ],
      });
    const { element } = await mount(request);
    await vi.waitFor(() => expect(element.querySelectorAll("button")).toHaveLength(2));
    element.querySelectorAll<HTMLButtonElement>("button")[1]!.click();
    await vi.waitFor(() => expect(element.textContent).toContain("<script>untrusted</script>"));
    expect(element.querySelector("script")).toBeNull();
    expect(request).toHaveBeenLastCalledWith("argus.handoffs.list", {
      limit: 5,
      before_sequence: 20,
    });
    expect(element.querySelectorAll("li")).toHaveLength(1);
  });
  it("refreshes only while visible and stops after removal", async () => {
    vi.useFakeTimers();
    const visibility = vi.spyOn(document, "visibilityState", "get").mockReturnValue("visible");
    const request = vi.fn().mockResolvedValue(page);
    const { element } = await mount(request);
    await settled();
    await vi.advanceTimersByTimeAsync(60_000);
    expect(request).toHaveBeenCalledTimes(2);
    visibility.mockReturnValue("hidden");
    await vi.advanceTimersByTimeAsync(60_000);
    expect(request).toHaveBeenCalledTimes(2);
    element.remove();
    visibility.mockReturnValue("visible");
    await vi.advanceTimersByTimeAsync(60_000);
    expect(request).toHaveBeenCalledTimes(2);
  });
});
