import { createHash } from "node:crypto";
import path from "node:path";
import { expect, it } from "vitest";
import { createControlUiE2eArtifactDir } from "../test-helpers/control-ui-e2e-artifacts.ts";
import { installMockGateway } from "../test-helpers/control-ui-e2e.ts";
import { createControlUiE2eSuite } from "./control-ui-e2e-suite.test-support.ts";

const suite = createControlUiE2eSuite({ name: "Argus existing operational evidence route" });
suite.define(() => {
  it("opens an exact technical artifact through the existing gateway from desktop and mobile views", async () => {
    const artifactDir = createControlUiE2eArtifactDir("argus-operational-evidence");
    const context = await suite.browser.newContext({ viewport: { width: 1440, height: 1000 } });
    const page = await context.newPage();
    const content = "Synthetic external technical result: parser boundary repaired.\n";
    const sha256 = createHash("sha256").update(content).digest("hex");
    const item = {
      operation_id: "external-parser-result",
      task_id: "parser-repair",
      event_id: "event-result",
      title: "Parser boundary repaired",
      source: "external-harness",
      kind: "result",
      state: "artifact_produced",
      occurred_at: "2026-09-09T06:00:00Z",
      observed_at: "2026-09-09T06:01:00Z",
      artifacts: [{ sha256, bytes: Buffer.byteLength(content), display_name: "Technical result" }],
      owner_accepted: false,
    };
    try {
      const gateway = await installMockGateway(page, {
        methodResponses: {
          "argus.operations.list": {
            items: [item],
            next_cursor: null,
            coverage: {
              scope: { corpus: "canonical_federation_observations", project: "Argus" },
              complete: true,
              has_more: false,
              snapshot_sequence: 5,
              observed_at: item.observed_at,
            },
          },
          "argus.operations.detail": {
            item,
            requested: item,
            timeline: [item],
            coverage: { complete: true, has_more: false },
          },
          "argus.operations.artifact": {
            sha256,
            bytes: Buffer.byteLength(content),
            mime_type: "text/plain",
            content_base64: Buffer.from(content).toString("base64"),
            operation_id: item.operation_id,
            event_id: item.event_id,
          },
          "argus.handoffs.list": {
            items: [],
            has_more: false,
            next_before_sequence: null,
            order: "newest_submitted_first",
            automatic_wake_enabled: false,
          },
        },
      });
      await page.goto(`${suite.server.baseUrl}overview`);
      const view = page.locator("argus-operational-view");
      await view.getByRole("button", { name: /Parser boundary repaired/ }).click();
      await view.getByRole("button", { name: /Verify artifact Technical result/ }).waitFor();
      expect((await gateway.getRequests("argus.operations.detail")).at(-1)?.params).toMatchObject({
        operation_id: item.operation_id,
      });
      await page.screenshot({ path: path.join(artifactDir, "desktop.png"), fullPage: true });
      await view.getByRole("button", { name: /Verify artifact Technical result/ }).click();
      const link = view.locator('a[href^="blob:"]');
      await link.waitFor();
      const href = await link.getAttribute("href");
      expect(await page.evaluate(async (url) => await (await fetch(url!)).text(), href)).toBe(
        content,
      );
      expect((await gateway.getRequests("argus.operations.artifact")).at(-1)?.params).toMatchObject(
        { operation_id: item.operation_id, event_id: item.event_id, sha256 },
      );
      await page.setViewportSize({ width: 390, height: 844 });
      await view
        .getByRole("button", { name: /Verify artifact Technical result/ })
        .scrollIntoViewIfNeeded();
      await page.screenshot({ path: path.join(artifactDir, "mobile.png"), fullPage: true });
      const bounds = await link.boundingBox();
      expect(bounds).not.toBeNull();
      expect(bounds!.width).toBeGreaterThan(10);
      expect(bounds!.x).toBeGreaterThanOrEqual(0);
      expect(bounds!.x + bounds!.width).toBeLessThanOrEqual(390);
      expect(await link.evaluate((element) => element.scrollWidth <= element.clientWidth + 1)).toBe(
        true,
      );
      expect(await gateway.getRequests("plugin.approval.resolve")).toEqual([]);
      expect(await gateway.getRequests("chat.send")).toEqual([]);
    } finally {
      await context.close();
    }
  });
});
