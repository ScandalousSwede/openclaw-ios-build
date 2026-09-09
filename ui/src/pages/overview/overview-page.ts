import { html } from "lit";
import { OpenClawLightDomElement } from "../../lit/openclaw-element.ts";
import "./operational-view.ts";
import "./handoff-view.ts";

// Reuse the installed Argus evidence consumers in the current application shell.
// Gateway setup, usage and cron controls retain their current owning routes.
class OverviewPage extends OpenClawLightDomElement {
  override render() {
    return html`<argus-operational-view></argus-operational-view>
      <argus-handoff-view></argus-handoff-view>`;
  }
}
if (!customElements.get("openclaw-overview-page")) {
  customElements.define("openclaw-overview-page", OverviewPage);
}
