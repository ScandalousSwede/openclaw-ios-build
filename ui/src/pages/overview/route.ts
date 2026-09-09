import { definePage } from "@openclaw/uirouter";
import { html } from "lit";
import { routePageSpec } from "../../app-route-paths.ts";

export const page = definePage({
  ...routePageSpec("overview"),
  component: () =>
    import("./overview-page.ts").then(() => ({
      header: true,
      render: () => html`<openclaw-overview-page></openclaw-overview-page>`,
    })),
});
