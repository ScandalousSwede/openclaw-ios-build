import { consume } from "@lit/context";
import { html, LitElement, nothing } from "lit";
import { state } from "lit/decorators.js";
import {
  applicationContext,
  type ApplicationContext,
  type ApplicationGatewaySnapshot,
} from "../../app/context.ts";
import { hasOperatorReadAccess } from "../../app/operator-access.ts";
import { parseHandoffPage, type HandoffPage, type HandoffReceipt } from "./handoff-contract.ts";

const refreshInterval = 60_000;
const unavailable =
  "Handoff receipts are unavailable. Reconnect or refresh. Previously loaded receipts are not current.";
const lifecycleLabels = {
  queued: "Queued for receiver",
  delivered: "Delivered to receiver",
  acknowledged: "Acknowledged by receiver",
} satisfies Record<HandoffReceipt["state"], string>;
function lifecycle(receiptState: HandoffReceipt["state"]) {
  return lifecycleLabels[receiptState];
}
function time(value: string) {
  return new Date(value).toLocaleString(undefined, { timeZoneName: "short" });
}
export class HandoffView extends LitElement {
  @consume({ context: applicationContext, subscribe: false }) private context!: ApplicationContext;
  @state() private page: HandoffPage | null = null;
  @state() private busy = false;
  @state() private error: string | null = null;
  @state() private checkedAt: string | null = null;
  private client: unknown = null;
  private ready = false;
  private allowed = false;
  private generation = 0;
  private lastAttempt = 0;
  private viewingOlder = false;
  private unsubscribe?: () => void;
  private timer?: number;
  private readonly onReturn = () => {
    if (
      !this.viewingOlder &&
      document.visibilityState !== "hidden" &&
      Date.now() - this.lastAttempt >= refreshInterval
    ) {
      void this.load();
    }
  };
  override createRenderRoot() {
    return this;
  }
  override connectedCallback() {
    super.connectedCallback();
    this.unsubscribe = this.context.gateway.subscribe((snapshot) => this.updateGateway(snapshot));
    this.updateGateway(this.context.gateway.snapshot);
    document.addEventListener("visibilitychange", this.onReturn);
    window.addEventListener("focus", this.onReturn);
    this.timer = window.setInterval(this.onReturn, refreshInterval);
  }
  private updateGateway(snapshot: ApplicationGatewaySnapshot) {
    const changed = snapshot.client !== this.client;
    const allowed = hasOperatorReadAccess(snapshot.hello?.auth ?? null);
    const ready = Boolean(snapshot.phase === "connected" && snapshot.client && allowed);
    // Authorization can change while both old and new snapshots are offline.
    // Readiness alone must not retain receipts across that scope downgrade.
    if (changed || ready !== this.ready || allowed !== this.allowed) {
      this.generation++;
      this.busy = false;
      this.ready = ready;
      this.allowed = allowed;
      this.client = snapshot.client;
      if (changed || !allowed) {
        this.page = null;
        this.checkedAt = null;
        this.error = null;
        this.viewingOlder = false;
      }
      if (ready) {
        void this.load();
      }
    }
    this.requestUpdate();
  }
  override disconnectedCallback() {
    this.unsubscribe?.();
    this.unsubscribe = undefined;
    if (this.timer !== undefined) {
      window.clearInterval(this.timer);
    }
    this.timer = undefined;
    document.removeEventListener("visibilitychange", this.onReturn);
    window.removeEventListener("focus", this.onReturn);
    this.generation++;
    this.ready = false;
    this.busy = false;
    super.disconnectedCallback();
  }
  private async load(older = false) {
    const { client, phase, hello } = this.context.gateway.snapshot;
    const connected = phase === "connected";
    if (
      !this.isConnected ||
      !client ||
      !connected ||
      !hasOperatorReadAccess(hello?.auth ?? null) ||
      this.busy
    ) {
      return;
    }
    const before = older ? this.page?.next_before_sequence : undefined;
    if (older && (!before || this.error)) {
      return;
    }
    const generation = this.generation;
    this.lastAttempt = Date.now();
    this.busy = true;
    this.error = null;
    try {
      const page = parseHandoffPage(
        await client.request("argus.handoffs.list", {
          limit: 5,
          ...(before ? { before_sequence: before } : {}),
        }),
        before ?? undefined,
      );
      if (
        generation !== this.generation ||
        !hasOperatorReadAccess(this.context.gateway.snapshot.hello?.auth ?? null)
      ) {
        return;
      }
      if (page.items.length > 5) {
        throw new Error("Invalid handoff page");
      }
      // Replace each bounded page so all older submissions remain reachable.
      this.page = page;
      this.viewingOlder = older;
      this.checkedAt = new Date().toISOString();
    } catch {
      if (generation === this.generation) {
        this.error = unavailable;
      }
    } finally {
      if (generation === this.generation) {
        this.busy = false;
      }
    }
  }
  private receipt(item: HandoffReceipt) {
    return html`<li
      style="padding:12px 0; border-top:1px solid var(--border); overflow-wrap:anywhere"
    >
      <div style="font-weight:600">${item.summary}</div>
      <p class="muted" style="margin:4px 0">${lifecycle(item.state)} · ${time(item.updated_at)}</p>
      <details>
        <summary>Receipt and binding</summary>
        <dl style="margin:8px 0; overflow-wrap:anywhere">
          <dt>Handoff</dt>
          <dd>${item.handoff_id}</dd>
          <dt>Receiver thread</dt>
          <dd>${item.binding.thread_id}</dd>
          <dt>Receiver workspace</dt>
          <dd>${item.binding.workspace}</dd>
          <dt>Receiver agent</dt>
          <dd>${item.binding.agent_id}</dd>
          <dt>Canonical operation</dt>
          <dd>${item.operation_id}</dd>
          <dt>Request event</dt>
          <dd>${item.request_event_id}</dd>
          <dt>Latest receipt event</dt>
          <dd>${item.canonical_event_id}</dd>
          <dt>Content SHA-256</dt>
          <dd>${item.content_sha256}</dd>
          <dt>Queued</dt>
          <dd>${time(item.queued_at)}</dd>
          <dt>Submission sequence</dt>
          <dd>${item.submission_sequence}</dd>
        </dl>
      </details>
    </li>`;
  }
  override render() {
    const connected = this.context.gateway.snapshot.phase === "connected";
    const allowed = hasOperatorReadAccess(this.context.gateway.snapshot.hello?.auth ?? null);
    return html`<section
      class="card argus-handoffs"
      aria-label="Engineering handoff receipts"
      aria-busy=${this.busy}
      style="margin-top:16px; min-width:0"
    >
      <div class="row" style="justify-content:space-between; flex-wrap:wrap; gap:8px">
        <h2 class="card-title" style="margin:0">Engineering handoffs</h2>
        <button
          class="btn"
          ?disabled=${!connected || !allowed || this.busy}
          @click=${() => void this.load()}
        >
          Refresh newest handoffs
        </button>
      </div>
      <p class="muted">
        Receiver receipts do not establish execution, completion or owner acceptance.
      </p>
      <div role="status" aria-live="polite">
        ${
          !connected
            ? html`<p>Disconnected. Previously loaded receipts are not current.</p>`
            : nothing
        }
        ${
          connected && !allowed
            ? html`<p>Operator read access is required to view handoff receipts.</p>`
            : nothing
        }
        ${this.error ? html`<p>${this.error}</p>` : nothing}
        ${this.busy ? html`<p>Loading handoff receipts…</p>` : nothing}
        ${
          this.checkedAt
            ? html`<p class="muted">
                Last successful read: ${time(this.checkedAt)}.
                ${
                  this.viewingOlder
                    ? "Viewing an older page; refresh to return to newest handoffs."
                    : "The newest page checks every minute while visible."
                }
              </p>`
            : nothing
        }
        ${
          connected && allowed && !this.busy && !this.error && this.page?.items.length === 0
            ? html`<p>No handoff receipts were returned in this bounded read.</p>`
            : nothing
        }
      </div>
      ${
        this.page
          ? html`<p class="muted">
              Automatic wake is disabled. Newest submissions first; five receipts per page.
            </p>`
          : nothing
      }
      <ul style="list-style:none; padding:0; margin:0">
        ${this.page?.items.map((item) => this.receipt(item)) ?? nothing}
      </ul>
      ${
        this.page?.has_more
          ? html`<button
              class="btn"
              ?disabled=${!connected || !allowed || this.busy || Boolean(this.error)}
              @click=${() => void this.load(true)}
            >
              Older handoffs
            </button>`
          : nothing
      }
    </section>`;
  }
}
if (!customElements.get("argus-handoff-view")) {
  customElements.define("argus-handoff-view", HandoffView);
}
