/* @vitest-environment jsdom */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
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
beforeEach(() => {
  window.history.replaceState({}, "", "/overview");
});
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

describe("server filters and observation links", () => {
  it("applies server filters with a fresh cursor and preserves explicit timezone precision", async () => {
    const { element, request } = await mount();
    const inputs = [...element.querySelectorAll("form input")];
    const values = [
      "unfamiliar-task",
      "external-new",
      "2026-09-06T18:00:00.000001Z",
      "2026-09-07T00:00:00+02:00",
    ];
    inputs.forEach((input, index) => {
      (input as HTMLInputElement).value = values[index];
      input.dispatchEvent(new Event("input"));
    });
    const project = element.querySelector("select")!;
    project.value = "MiKobots";
    project.dispatchEvent(new Event("change"));
    element.querySelector("form")!.dispatchEvent(new Event("submit", { cancelable: true }));
    await vi.waitFor(() =>
      expect(request).toHaveBeenLastCalledWith("argus.operations.list", {
        project: "MiKobots",
        task_id: "unfamiliar-task",
        source: "external-new",
        recorded_from: values[2],
        recorded_before: values[3],
        limit: 30,
      }),
    );
    expect(window.location.search).toContain("argus_project=MiKobots");
    expect(window.location.search).not.toContain("argus_operation");
  });

  it("loads an unfamiliar linked observation independently of list membership and excludes auth from links", async () => {
    window.history.replaceState(
      {},
      "",
      "/overview?argus_operation=external-unlisted&token=private-placeholder#secret-placeholder",
    );
    const requested = { ...item, operation_id: "external-unlisted", title: "Earlier evidence" };
    const current = { ...item, operation_id: "current-observation", title: "Current evidence" };
    const request = vi
      .fn()
      .mockResolvedValueOnce(page)
      .mockResolvedValueOnce({
        item: current,
        requested,
        timeline: [current, requested],
        coverage: { complete: false, has_more: true },
      });
    const { element } = await mount(request);
    await vi.waitFor(() => expect(element.textContent).toContain("Requested: Earlier evidence"));
    expect(request).toHaveBeenLastCalledWith("argus.operations.detail", {
      operation_id: "external-unlisted",
    });
    const links = [...element.querySelectorAll(".argus-detail a")];
    expect(links).toHaveLength(2);
    expect(links[0].getAttribute("href")).toContain("argus_operation=external-unlisted");
    expect(links[1].getAttribute("href")).toContain("argus_operation=current-observation");
    for (const link of links) {
      expect(link.getAttribute("href")).not.toMatch(
        /private-placeholder|secret-placeholder|token=/,
      );
    }
    expect(element.textContent).toContain("Partial history");
    expect(element.textContent).toContain("does not dispatch work");
  });

  it("refuses invalid URL scope before any request", async () => {
    window.history.replaceState({}, "", "/overview?argus_project=Other");
    const request = vi.fn();
    const element = new OperationalView();
    Object.assign(element, {
      context: {
        gateway: { snapshot: { connected: true, client: { request } }, subscribe: () => () => {} },
      },
    });
    document.body.append(element);
    await element.updateComplete;
    expect(request).not.toHaveBeenCalled();
    expect(element.textContent).toContain("Choose a supported project");
  });

  it("rejects timezone-free filters without replacing loaded evidence", async () => {
    const { element, request } = await mount();
    const input = element.querySelectorAll("form input")[2] as HTMLInputElement;
    input.value = "2026-09-06T18:00";
    input.dispatchEvent(new Event("input"));
    element.querySelector("form")!.dispatchEvent(new Event("submit", { cancelable: true }));
    await element.updateComplete;
    expect(request).toHaveBeenCalledTimes(1);
    expect(element.textContent).toContain("Use an ISO observation time with a timezone");
    expect(element.textContent).toContain("Reader correction");
  });

  it("refreshes once on return after a minute without a polling timer", async () => {
    const { request } = await mount();
    const clock = vi.spyOn(Date, "now");
    const now = Date.now();
    clock.mockReturnValue(now + 61_000);
    window.dispatchEvent(new Event("focus"));
    await vi.waitFor(() => expect(request).toHaveBeenCalledTimes(2));
    window.dispatchEvent(new Event("focus"));
    expect(request).toHaveBeenCalledTimes(2);
  });

  it("reconciles browser history scope and ignores a late previous page", async () => {
    const { element, request } = await mount();
    let release!: (value: typeof page) => void;
    request.mockImplementationOnce(
      () =>
        new Promise((resolve) => {
          release = resolve;
        }),
    );
    window.history.pushState({}, "", "/overview?argus_source=older");
    window.dispatchEvent(new PopStateEvent("popstate"));
    await vi.waitFor(() => expect(request).toHaveBeenCalledTimes(2));
    request.mockResolvedValueOnce({ ...page, items: [{ ...item, title: "New scope evidence" }] });
    window.history.pushState({}, "", "/overview?argus_source=newer");
    window.dispatchEvent(new PopStateEvent("popstate"));
    await vi.waitFor(() => expect(element.textContent).toContain("New scope evidence"));
    release({ ...page, items: [{ ...item, title: "Stale scope evidence" }] });
    await element.updateComplete;
    expect(element.textContent).not.toContain("Stale scope evidence");
  });
});

it("does not mark a failed list current when linked detail succeeds", async () => {
  const { element, request } = await mount();
  request.mockRejectedValueOnce(new Error("Unavailable")).mockResolvedValueOnce({
    item,
    requested: item,
    timeline: [item],
    coverage: { complete: true, has_more: false },
  });
  window.history.pushState({}, "", "/overview?argus_operation=external-held-out");
  window.dispatchEvent(new PopStateEvent("popstate"));
  await vi.waitFor(() => expect(element.querySelector(".argus-detail")).not.toBeNull());
  expect(element.querySelector('[role="status"]')?.textContent).toContain("Evidence unavailable");
});

it("displays and submits a non-default project loaded from a deep link", async () => {
  window.history.replaceState({}, "", "/overview?argus_project=MiKobots");
  const { element, request } = await mount();
  expect(element.querySelector("select")?.value).toBe("MiKobots");
  expect(request).toHaveBeenLastCalledWith("argus.operations.list", {
    project: "MiKobots",
    limit: 30,
  });
  const task = element.querySelector("form input") as HTMLInputElement;
  task.value = "new-task";
  task.dispatchEvent(new Event("input"));
  element.querySelector("form")!.dispatchEvent(new Event("submit", { cancelable: true }));
  await vi.waitFor(() =>
    expect(request).toHaveBeenLastCalledWith("argus.operations.list", {
      project: "MiKobots",
      task_id: "new-task",
      limit: 30,
    }),
  );
});

it("restores a user-edited project selection when browser history changes", async () => {
  const { element, request } = await mount();
  const select = element.querySelector("select")!;
  select.value = "MiKobots";
  select.dispatchEvent(new Event("change"));
  await element.updateComplete;
  select.value = "EPC";
  select.dispatchEvent(new Event("change"));
  await element.updateComplete;
  expect(select.value).toBe("EPC");
  window.history.pushState({}, "", "/overview?argus_project=MiKobots");
  window.dispatchEvent(new PopStateEvent("popstate"));
  await vi.waitFor(() =>
    expect(request).toHaveBeenLastCalledWith("argus.operations.list", {
      project: "MiKobots",
      limit: 30,
    }),
  );
  await element.updateComplete;
  expect(select.value).toBe("MiKobots");
});
