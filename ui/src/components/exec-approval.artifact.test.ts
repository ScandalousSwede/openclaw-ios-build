import { expect, it, vi } from "vitest";
import "./exec-approval.ts";
it("renders only artifact disposition actions and a non-mutating defer action", async () => {
  const element = document.createElement("openclaw-exec-approval") as HTMLElement & {
    props: unknown;
    updateComplete: Promise<void>;
  };
  const onDecision = vi.fn();
  const onDefer = vi.fn();
  element.props = {
    queue: [
      {
        id: "review",
        kind: "artifact_review",
        request: { command: "Review" },
        pluginTitle: "Review current artifact",
        createdAtMs: 1000,
        expiresAtMs: Date.now() + 60000,
      },
    ],
    busy: false,
    error: null,
    onDecision,
    onDefer,
  };
  document.body.append(element);
  await element.updateComplete;
  expect(element.textContent).toContain("Accept artifact");
  expect(element.textContent).toContain("Reject artifact");
  expect(element.textContent).not.toContain("Always allow");
  [...element.querySelectorAll("button")].find((b) => b.textContent?.includes("Not now"))!.click();
  expect(onDefer).toHaveBeenCalledOnce();
  expect(onDecision).not.toHaveBeenCalled();
  element.remove();
});
