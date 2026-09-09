/* @vitest-environment jsdom */
import { assert, afterEach, describe, expect, it, vi } from "vitest";
import { item, page, mount, setupOperationalViewTests } from "./operational-view.test-helpers.ts";
import { OperationalView } from "./operational-view.ts";

setupOperationalViewTests();
describe("earlier observation artifacts", () => {
  const digest = "0".repeat(64);
  const artifact = { sha256: digest, bytes: 3, display_name: "Prior report" };
  const earlier = { ...item, artifacts: [artifact] };
  const current = {
    ...item,
    operation_id: "active-next-turn",
    event_id: "event-active",
    state: "active",
    title: "Reader correction continues",
  };
  const response = {
    operation_id: earlier.operation_id,
    event_id: earlier.event_id,
    sha256: digest,
    bytes: 3,
    mime_type: "text/plain",
    content_base64: "YWJj",
  };
  async function setup(inTimeline: boolean, reply: () => Promise<unknown>) {
    const create = vi.fn().mockReturnValue("blob:earlier-observation");
    vi.stubGlobal(
      "URL",
      class extends URL {
        static override createObjectURL = create;
        static override revokeObjectURL = vi.fn();
      },
    );
    vi.stubGlobal("crypto", {
      subtle: { digest: vi.fn().mockResolvedValue(new Uint8Array(32).buffer) },
    });
    const request = vi.fn().mockImplementation(async (method) => {
      if (method === "argus.operations.list") {
        return page;
      }
      if (method === "argus.operations.detail") {
        return {
          item: current,
          requested: earlier,
          timeline: inTimeline ? [current, earlier] : [current],
          coverage: { complete: inTimeline, has_more: !inTimeline },
        };
      }
      return reply();
    });
    const mounted = await mount(request, true, true);
    mounted.element.querySelector<HTMLButtonElement>(".argus-work-row")!.click();
    await vi.waitFor(() => expect(mounted.element.textContent).toContain("Earlier artifacts"));
    return { ...mounted, create };
  }
  afterEach(() => vi.unstubAllGlobals());
  it.each([true, false])(
    "opens the requested earlier result with its own identity (in timeline: %s)",
    async (inTimeline) => {
      const { element, request, create } = await setup(inTimeline, async () => response);
      const section = element.querySelector(".argus-earlier-artifacts")!;
      expect(section.querySelectorAll("section")).toHaveLength(1);
      expect(section.textContent?.replace(/\s+/g, " ")).toContain(
        "do not establish a result for the current work",
      );
      expect(element.querySelector(".argus-detail > p")?.textContent).toContain("active");
      expect(element.textContent).not.toContain("Request operator review");
      section.querySelector<HTMLButtonElement>("button")!.click();
      await vi.waitFor(() => expect(element.querySelector('a[href^="blob:"]')).not.toBeNull());
      expect(request).toHaveBeenLastCalledWith("argus.operations.artifact", {
        operation_id: earlier.operation_id,
        event_id: earlier.event_id,
        sha256: digest,
      });
      expect(element.querySelector('a[href^="blob:"]')?.textContent).toContain(
        "Open verified earlier-observation artifact",
      );
      expect(create).toHaveBeenCalledTimes(1);
    },
  );
  it.each([
    { ...response, operation_id: current.operation_id },
    { ...response, event_id: current.event_id },
    { ...response, sha256: "1".repeat(64) },
  ])("refuses a mismatched earlier artifact response", async (reply) => {
    const { element, create } = await setup(true, async () => reply);
    element.querySelector<HTMLButtonElement>(".argus-earlier-artifacts button")!.click();
    await vi.waitFor(() => expect(element.textContent).toContain("No file was opened"));
    expect(create).not.toHaveBeenCalled();
    expect(element.querySelector('a[href^="blob:"]')).toBeNull();
  });
  it("opens a corrected operation's earlier event and preserves its exact deep link", async () => {
    const prior = {
      ...earlier,
      evidence_scope: "admitted_canonical_technical_operation",
      kind: "codex.completion.artifact_produced",
    };
    const latest = {
      ...current,
      operation_id: prior.operation_id,
      artifacts: [{ sha256: "1".repeat(64), bytes: 3 }],
    };
    const create = vi.fn().mockReturnValue("blob:historical-event");
    vi.stubGlobal(
      "URL",
      class extends URL {
        static override createObjectURL = create;
        static override revokeObjectURL = vi.fn();
      },
    );
    vi.stubGlobal("crypto", {
      subtle: { digest: vi.fn().mockResolvedValue(new Uint8Array(32).buffer) },
    });
    window.history.replaceState(
      {},
      "",
      `/overview?argus_operation=${prior.operation_id}&argus_event=${prior.event_id}`,
    );
    const request = vi.fn().mockImplementation(async (method) => {
      if (method === "argus.operations.list") {
        return { ...page, items: [latest] };
      }
      if (method === "argus.operations.detail") {
        return {
          item: latest,
          requested: prior,
          timeline: [latest, prior],
          coverage: { complete: true, has_more: false },
        };
      }
      return response;
    });
    const { element } = await mount(request);
    await vi.waitFor(() =>
      expect(element.querySelector(".argus-earlier-artifacts button")).not.toBeNull(),
    );
    expect(request).toHaveBeenCalledWith("argus.operations.detail", {
      operation_id: prior.operation_id,
      event_id: prior.event_id,
    });
    const historicalLink = element.querySelector<HTMLAnchorElement>(".argus-earlier-artifacts a")!;
    expect(new URL(historicalLink.href).searchParams.get("argus_event")).toBe(prior.event_id);
    expect(element.querySelector(".argus-work-row")?.getAttribute("aria-current")).toBe("false");
    element.querySelector<HTMLButtonElement>(".argus-earlier-artifacts button")!.click();
    await vi.waitFor(() => expect(create).toHaveBeenCalledTimes(1));
    expect(request).toHaveBeenLastCalledWith("argus.operations.artifact", {
      operation_id: prior.operation_id,
      event_id: prior.event_id,
      sha256: digest,
    });
    expect(element.querySelector(".argus-detail h3")?.textContent).toContain(latest.title);
    expect(element.querySelector('a[href^="blob:"]')?.textContent).toContain(
      "earlier-observation artifact Prior report",
    );
  });
  it("ignores an earlier artifact response after disconnect and recovers on reconnect", async () => {
    let release!: (value: unknown) => void;
    let delayed = true;
    const { element, create, setConnected } = await setup(true, () =>
      delayed
        ? new Promise((resolve) => {
            release = resolve;
          })
        : Promise.resolve(response),
    );
    element.querySelector<HTMLButtonElement>(".argus-earlier-artifacts button")!.click();
    await vi.waitFor(() => expect(release).toBeTypeOf("function"));
    setConnected(false);
    release(response);
    await element.updateComplete;
    expect(create).not.toHaveBeenCalled();
    expect(element.querySelector('a[href^="blob:"]')).toBeNull();
    delayed = false;
    setConnected(true);
    await vi.waitFor(() =>
      expect(element.querySelector(".argus-earlier-artifacts button")).not.toBeNull(),
    );
    element.querySelector<HTMLButtonElement>(".argus-earlier-artifacts button")!.click();
    await vi.waitFor(() => expect(create).toHaveBeenCalledTimes(1));
  });
});
describe("operational evidence overview", () => {
  it("keeps partial scope and owner acceptance separate from verified execution", async () => {
    const { element } = await mount();
    expect(element.textContent).toContain("Partial coverage");
    expect(element.textContent).not.toContain("Owner approval required");
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
        event_id: item.event_id,
      }),
    );
    await element.updateComplete;
    expect(element.textContent).toContain("Operation: external-held-out");
  });
  it("uses compact accessible rows and marks only the requested observation selected", async () => {
    const other = { ...item, operation_id: "other-observation", title: "Another result" };
    const request = vi.fn().mockImplementation(async (method, params) => {
      if (method === "argus.operations.list") {
        return { ...page, items: [item, other] };
      }
      const selected = params.operation_id === item.operation_id ? item : other;
      return {
        item: selected,
        requested: selected,
        timeline: [selected],
        coverage: { complete: true, has_more: false },
      };
    });
    const { element } = await mount(request);
    const list = element.querySelector('ul[aria-label="Work observations"]')!;
    expect(list.querySelectorAll("h3")).toHaveLength(0);
    const rows = [...list.querySelectorAll<HTMLButtonElement>("button")];
    expect(rows).toHaveLength(2);
    const [firstRow, secondRow] = rows;
    assert.isDefined(firstRow);
    assert.isDefined(secondRow);
    expect(firstRow.textContent).toContain("Reader correction");
    expect(firstRow.textContent).toContain("Recorded state: verified");
    expect(firstRow.textContent).toContain("Observed");
    firstRow.click();
    await vi.waitFor(() =>
      expect(element.querySelector(".argus-detail h3")?.textContent).toContain("Reader correction"),
    );
    expect(firstRow.getAttribute("aria-current")).toBe("true");
    expect(firstRow.textContent).toContain("Selected");
    expect(document.activeElement).toBe(element.querySelector(".argus-detail h3"));
    secondRow.click();
    await vi.waitFor(() =>
      expect(element.querySelector(".argus-detail h3")?.textContent).toContain("Another result"),
    );
    expect(list.querySelectorAll('[aria-current="true"]')).toHaveLength(1);
    expect(firstRow.getAttribute("aria-current")).toBe("false");
    expect(secondRow.getAttribute("aria-current")).toBe("true");
  });
  it("keeps the selected producer summary complete while bounding only the list row", async () => {
    const title =
      "Reader correction · Synthetic workflow repository and run receipt " +
      "long source identity ".repeat(12);
    const long = { ...item, title };
    const request = vi
      .fn()
      .mockResolvedValueOnce({ ...page, items: [long] })
      .mockResolvedValueOnce({
        item: long,
        requested: long,
        timeline: [long],
        coverage: { complete: true, has_more: false },
      });
    const { element } = await mount(request);
    const row = element.querySelector<HTMLButtonElement>(".argus-work-row")!;
    const rowTitle = row.querySelector(".argus-work-title")!;
    expect(rowTitle.textContent).toBe(title);
    expect(rowTitle.getAttribute("title")).toBe(title);
    row.click();
    await vi.waitFor(() => expect(element.querySelector(".argus-detail h3")).not.toBeNull());
    const heading = element.querySelector(".argus-detail h3")!;
    expect(heading.textContent!.trim()).toBe(title.trim());
    expect(heading.textContent).not.toContain("…");
    expect(element.querySelector(".argus-detail > details")?.textContent).toContain(title);
    expect(element.querySelector(".argus-detail")?.textContent).toContain(
      "Recorded state: verified",
    );
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
    const inputs = [...element.querySelectorAll<HTMLInputElement>("form input")];
    const values = [
      "unfamiliar-task",
      "external-new",
      "2026-09-06T18:00:00.000001Z",
      "2026-09-07T00:00:00+02:00",
    ];
    inputs.forEach((input, index) => {
      const value = values[index];
      assert.isDefined(value);
      input.value = value;
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
    await vi.waitFor(() =>
      expect(element.textContent?.replace(/\s+/gu, " ")).toContain("Requested: Earlier evidence"),
    );
    expect(request).toHaveBeenLastCalledWith("argus.operations.detail", {
      operation_id: "external-unlisted",
    });
    const links = [...element.querySelectorAll(".argus-detail a")];
    expect(links).toHaveLength(2);
    const [requestedLink, currentLink] = links;
    assert.isDefined(requestedLink);
    assert.isDefined(currentLink);
    expect(requestedLink.getAttribute("href")).toContain("argus_operation=external-unlisted");
    expect(currentLink.getAttribute("href")).toContain("argus_operation=current-observation");
    for (const link of links) {
      expect(link.getAttribute("href")).not.toMatch(
        /private-placeholder|secret-placeholder|token=/,
      );
    }
    expect(element.textContent).toContain("Partial history");
    expect(element.textContent?.replace(/\s+/gu, " ")).toContain("does not dispatch work");
  });

  it("refuses invalid URL scope before any request", async () => {
    window.history.replaceState({}, "", "/overview?argus_project=Other");
    const request = vi.fn();
    const element = new OperationalView();
    Object.assign(element, {
      context: {
        gateway: {
          snapshot: { phase: "connected", client: { request } },
          subscribe: () => () => {},
        },
      },
    });
    document.body.append(element);
    await element.updateComplete;
    expect(request).not.toHaveBeenCalled();
    expect(element.textContent).toContain("Choose a supported project");
  });

  it("rejects timezone-free filters without replacing loaded evidence", async () => {
    const { element, request } = await mount();
    const input = element.querySelectorAll<HTMLInputElement>("form input")[2] as HTMLInputElement;
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

describe("visible operational evidence refresh", () => {
  it("refreshes a visible view without stealing focus and stops while hidden or removed", async () => {
    vi.useFakeTimers();
    const visibility = vi.spyOn(document, "visibilityState", "get").mockReturnValue("visible");
    const request = vi
      .fn()
      .mockResolvedValueOnce(page)
      .mockResolvedValue({ ...page, items: [{ ...item, title: "Fresh observed work" }] });
    const { element, setConnected } = await mount(request);
    const search = element.querySelector<HTMLInputElement>('input[type="search"]')!;
    search.focus();
    await vi.advanceTimersByTimeAsync(60_000);
    expect(request).toHaveBeenCalledTimes(2);
    expect(element.textContent).toContain("Fresh observed work");
    expect(element.textContent).toContain("Evidence last checked");
    expect(document.activeElement).toBe(search);
    visibility.mockReturnValue("hidden");
    await vi.advanceTimersByTimeAsync(60_000);
    expect(request).toHaveBeenCalledTimes(2);
    setConnected(false);
    visibility.mockReturnValue("visible");
    await vi.advanceTimersByTimeAsync(60_000);
    expect(request).toHaveBeenCalledTimes(2);
    element.remove();
    await vi.advanceTimersByTimeAsync(120_000);
    expect(request).toHaveBeenCalledTimes(2);
  });
  it("does not overlap visible refresh requests", async () => {
    vi.useFakeTimers();
    vi.spyOn(document, "visibilityState", "get").mockReturnValue("visible");
    let release!: (value: typeof page) => void;
    const request = vi
      .fn()
      .mockResolvedValueOnce(page)
      .mockImplementation(
        () =>
          new Promise((resolve) => {
            release = resolve;
          }),
      );
    const { element } = await mount(request);
    await vi.advanceTimersByTimeAsync(60_000);
    await vi.advanceTimersByTimeAsync(180_000);
    expect(request).toHaveBeenCalledTimes(2);
    release(page);
    await vi.advanceTimersByTimeAsync(0);
    expect(element.querySelector(".argus-evidence")?.getAttribute("aria-busy")).toBe("false");
  });
  it("retains a verified artifact only while current event and artifact identity remain unchanged", async () => {
    vi.useFakeTimers();
    vi.spyOn(document, "visibilityState", "get").mockReturnValue("visible");
    const digest = "0".repeat(64);
    const artifact = { sha256: digest, bytes: 3 };
    let current = { ...item, artifacts: [artifact] };
    const create = vi.fn().mockReturnValue("blob:verified-poll-fixture");
    const revoke = vi.fn();
    vi.stubGlobal(
      "URL",
      class extends URL {
        static override createObjectURL = create;
        static override revokeObjectURL = revoke;
      },
    );
    vi.stubGlobal("crypto", {
      subtle: { digest: vi.fn().mockResolvedValue(new Uint8Array(32).buffer) },
    });
    try {
      const request = vi.fn().mockImplementation(async (method) => {
        if (method === "argus.operations.list") {
          return { ...page, items: [current] };
        }
        if (method === "argus.operations.detail") {
          return {
            item: current,
            requested: current,
            timeline: [current],
            coverage: { complete: true, has_more: false },
          };
        }
        return {
          sha256: digest,
          event_id: item.event_id,
          bytes: 3,
          mime_type: "text/plain",
          content_base64: "YWJj",
        };
      });
      const { element } = await mount(request);
      element.querySelector<HTMLButtonElement>(".argus-work-row")!.click();
      await vi.waitFor(() => expect(element.textContent).toContain("Verify artifact"));
      [...element.querySelectorAll("button")]
        .find((node) => node.textContent?.includes("Verify artifact"))!
        .click();
      await vi.waitFor(() => expect(element.querySelector('a[href^="blob:"]')).not.toBeNull());
      const search = element.querySelector<HTMLInputElement>('input[type="search"]')!;
      search.focus();
      await vi.advanceTimersByTimeAsync(60_000);
      expect(element.querySelector('a[href^="blob:"]')).not.toBeNull();
      expect(create).toHaveBeenCalledTimes(1);
      expect(revoke).not.toHaveBeenCalled();
      expect(document.activeElement).toBe(search);
      current = { ...current, event_id: "new-current-event" };
      await vi.advanceTimersByTimeAsync(60_000);
      expect(element.querySelector('a[href^="blob:"]')).toBeNull();
      expect(revoke).toHaveBeenCalledTimes(1);
    } finally {
      vi.unstubAllGlobals();
    }
  });
  it("clears current detail on a failed refresh instead of presenting stale evidence as current", async () => {
    vi.useFakeTimers();
    vi.spyOn(document, "visibilityState", "get").mockReturnValue("visible");
    const request = vi
      .fn()
      .mockResolvedValueOnce(page)
      .mockResolvedValueOnce({
        item,
        requested: item,
        timeline: [item],
        coverage: { complete: true, has_more: false },
      })
      .mockRejectedValue(new Error("synthetic unavailable"));
    const { element } = await mount(request);
    element.querySelector<HTMLButtonElement>(".argus-work-row")!.click();
    await vi.waitFor(() => expect(element.querySelector(".argus-detail")).not.toBeNull());
    await vi.advanceTimersByTimeAsync(60_000);
    expect(element.querySelector(".argus-detail")).toBeNull();
    expect(element.querySelector('[role="status"]')?.textContent).toContain("Evidence unavailable");
    expect(request).toHaveBeenCalledTimes(4);
  });
});

it("retires loaded work and a pending response when the same client loses read access", async () => {
  const { element, request, setScopes } = await mount();
  let finish!: (value: unknown) => void;
  request.mockImplementationOnce(
    () =>
      new Promise((resolve) => {
        finish = resolve;
      }),
  );
  element.querySelector<HTMLButtonElement>(".argus-toolbar button")!.click();
  await vi.waitFor(() => expect(request).toHaveBeenCalledTimes(2));
  setScopes([]);
  await element.updateComplete;
  expect(element.textContent).toContain("Read permission required");
  expect(element.textContent).not.toContain("Reader correction");
  finish({ ...page, items: [{ ...item, title: "Retired response" }] });
  await Promise.resolve();
  await element.updateComplete;
  expect(element.textContent).not.toContain("Retired response");
  element.querySelector<HTMLButtonElement>(".argus-toolbar button")!.click();
  expect(request).toHaveBeenCalledTimes(2);
  setScopes(["operator.read"]);
  await vi.waitFor(() => expect(element.textContent).toContain("Reader correction"));
  expect(request).toHaveBeenCalledTimes(3);
});

it("clears retained disconnected work when read authorization is revoked", async () => {
  const { element, setConnected, setScopes, request } = await mount();
  setConnected(false);
  await element.updateComplete;
  setScopes([]);
  await element.updateComplete;
  expect(element.textContent).not.toContain("Reader correction");
  expect(request).toHaveBeenCalledTimes(1);
});
