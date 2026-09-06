import { consume } from "@lit/context";
import { html, LitElement, nothing } from "lit";
import { state } from "lit/decorators.js";
import {
  applicationContext,
  type ApplicationContext,
  type ApplicationGatewaySnapshot,
} from "../../app/context.ts";

type Artifact = { sha256: string; bytes: number };
type Operation = {
  operation_id: string;
  task_id: string;
  event_id: string;
  title: string;
  source: string;
  kind: string;
  state: string;
  occurred_at: string;
  observed_at: string;
  artifacts: Artifact[];
  owner_accepted: boolean;
};
type Page = {
  items: Operation[];
  coverage: {
    scope: { corpus: string; project: string; task_id?: string | null; source?: string | null };
    complete: boolean;
    has_more: boolean;
    snapshot_sequence: number;
    observed_at: string;
  };
  next_cursor: string | null;
};
type DetailResponse = {
  item: Operation;
  requested: Operation;
  timeline: Operation[];
  coverage: { complete: boolean; has_more: boolean };
};
type Detail = Operation & {
  timeline: Operation[];
  newerObservation: boolean;
  historyComplete: boolean;
};

function operationTime(value: string): string {
  const date = new Date(value);
  return Number.isNaN(date.valueOf())
    ? "Observation time unavailable"
    : date.toLocaleString(undefined, { timeZoneName: "short" });
}

export class OperationalView extends LitElement {
  @consume({ context: applicationContext, subscribe: false })
  private context!: ApplicationContext;
  @state() private page: Page | null = null;
  @state() private detail: Detail | null = null;
  @state() private busy = false;
  @state() private error: string | null = null;
  @state() private filter = "";
  @state() private artifactUrl: string | null = null;
  private unsubscribe?: () => void;
  private generation = 0;
  private connectionClient: unknown = null;
  private connectionReady = false;

  override createRenderRoot() {
    return this;
  }
  override connectedCallback() {
    super.connectedCallback();
    this.unsubscribe = this.context.gateway.subscribe((snapshot) => this.updateGateway(snapshot));
    this.updateGateway(this.context.gateway.snapshot);
  }
  private updateGateway(snapshot: ApplicationGatewaySnapshot) {
    const clientChanged = snapshot.client !== this.connectionClient;
    const ready = snapshot.connected && snapshot.client !== null;
    const readinessChanged = ready !== this.connectionReady;
    this.connectionClient = snapshot.client;
    this.connectionReady = ready;
    if (clientChanged || readinessChanged) {
      // A reconnect reuses its client. Invalidate pending reads at readiness
      // edges so late responses cannot replace the next connection's evidence.
      this.generation++;
      this.busy = false;
      this.clearArtifact();
      this.detail = null;
      if (clientChanged) this.page = null;
      if (ready) void this.load();
    }
    this.requestUpdate();
  }
  override disconnectedCallback() {
    this.unsubscribe?.();
    this.generation++;
    this.connectionReady = false;
    this.busy = false;
    this.clearArtifact();
    super.disconnectedCallback();
  }
  private clearArtifact() {
    if (this.artifactUrl) URL.revokeObjectURL(this.artifactUrl);
    this.artifactUrl = null;
  }
  private async load(more = false) {
    const { client, connected } = this.context.gateway.snapshot;
    if (!client || !connected || this.busy) return;
    const generation = this.generation;
    this.busy = true;
    this.error = null;
    try {
      const page = await client.request<Page>("argus.operations.list", {
        project: "Argus",
        limit: 30,
        ...(more && this.page?.next_cursor ? { cursor: this.page.next_cursor } : {}),
      });
      if (generation !== this.generation) return;
      const previous = more ? (this.page?.items ?? []) : [];
      const items = new Map(previous.map((item) => [item.operation_id, item]));
      for (const item of page.items) items.set(item.operation_id, item);
      this.page = { ...page, items: [...items.values()] };
      if (!more) {
        this.detail = null;
        this.clearArtifact();
      }
    } catch {
      if (generation === this.generation)
        this.error =
          "Operational evidence is unavailable. Reconnect or try Refresh. Previously loaded records are not current.";
    } finally {
      if (generation === this.generation) this.busy = false;
    }
  }
  private async openDetail(operation: Operation) {
    const { client, connected } = this.context.gateway.snapshot;
    if (!client || !connected || this.busy) return;
    const generation = this.generation;
    this.busy = true;
    this.error = null;
    this.clearArtifact();
    this.detail = null;
    try {
      const detail = await client.request<DetailResponse>("argus.operations.detail", {
        operation_id: operation.operation_id,
      });
      if (detail.requested.operation_id !== operation.operation_id)
        throw new Error("Operation identity mismatch");
      if (generation === this.generation) {
        this.detail = {
          ...detail.item,
          timeline: detail.timeline,
          newerObservation: detail.item.operation_id !== detail.requested.operation_id,
          historyComplete: detail.coverage.complete,
        };
        await this.updateComplete;
        this.querySelector<HTMLElement>(".argus-detail h3")?.focus();
      }
    } catch {
      if (generation === this.generation)
        this.error = "Work detail is unavailable. Refresh and retry.";
    } finally {
      if (generation === this.generation) this.busy = false;
    }
  }
  private async openArtifact(artifact: Artifact) {
    const { client, connected } = this.context.gateway.snapshot;
    if (!client || !connected || !this.detail || this.busy) return;
    const generation = this.generation;
    this.busy = true;
    this.error = null;
    this.clearArtifact();
    try {
      const result = await client.request<{
        sha256: string;
        bytes: number;
        mime_type: string;
        content_base64: string;
      }>("argus.operations.artifact", {
        operation_id: this.detail.operation_id,
        sha256: artifact.sha256,
      });
      if (generation !== this.generation) return;
      if (
        result.sha256 !== artifact.sha256 ||
        result.content_base64.length > 1_398_104 ||
        !["text/plain", "text/markdown", "application/pdf", "image/png", "image/jpeg"].includes(
          result.mime_type.split(";")[0].trim(),
        )
      )
        throw new Error("Artifact refused");
      const bytes = Uint8Array.from(atob(result.content_base64), (char) => char.charCodeAt(0));
      const hash = [...new Uint8Array(await crypto.subtle.digest("SHA-256", bytes))]
        .map((byte) => byte.toString(16).padStart(2, "0"))
        .join("");
      if (
        hash !== artifact.sha256 ||
        bytes.length !== result.bytes ||
        bytes.length !== artifact.bytes
      )
        throw new Error("Artifact integrity failed");
      if (generation === this.generation)
        this.artifactUrl = URL.createObjectURL(new Blob([bytes], { type: result.mime_type }));
    } catch {
      if (generation === this.generation)
        this.error = "Artifact could not be verified or is unavailable. No file was opened.";
    } finally {
      if (generation === this.generation) this.busy = false;
    }
  }
  override render() {
    const connected = this.context.gateway.snapshot.connected;
    const items =
      this.page?.items.filter((item) =>
        `${item.title} ${item.task_id} ${item.source}`
          .toLocaleLowerCase()
          .includes(this.filter.toLocaleLowerCase()),
      ) ?? [];
    return html`<style>
        .argus-evidence {
          background: var(--card, #101c29);
          border: 1px solid color-mix(in srgb, currentColor 45%, transparent);
          border-radius: 16px;
          padding: clamp(18px, 3vw, 32px);
          margin-bottom: 24px;
          font-size: 18px;
          line-height: 1.6;
          overflow-wrap: anywhere;
        }
        .argus-evidence h2 {
          font-size: clamp(26px, 3vw, 38px);
          margin: 0 0 12px;
          line-height: 1.25;
        }
        .argus-evidence h3 {
          font-size: 22px;
          margin: 12px 0;
        }
        .argus-evidence p {
          margin: 8px 0;
        }
        .argus-evidence .argus-toolbar {
          display: flex;
          flex-wrap: wrap;
          align-items: center;
          gap: 16px;
          margin: 20px 0;
        }
        .argus-evidence button,
        .argus-evidence input,
        .argus-evidence a {
          font: inherit;
          min-height: 48px;
        }
        .argus-evidence button {
          padding: 10px 18px;
          border: 1px solid color-mix(in srgb, currentColor 55%, transparent);
          white-space: normal;
        }
        .argus-evidence input {
          width: 100%;
          max-width: 36rem;
          padding: 10px;
          box-sizing: border-box;
        }
        .argus-evidence :focus-visible {
          outline: 3px solid #39d9eb;
          outline-offset: 4px;
        }
        .argus-evidence ul {
          padding: 0;
          list-style: none;
          display: grid;
          gap: 16px;
        }
        .argus-evidence li {
          border: 1px solid color-mix(in srgb, currentColor 45%, transparent);
          border-radius: 10px;
          padding: 18px;
        }
        .argus-evidence details {
          margin-top: 16px;
        }
        .argus-evidence summary {
          cursor: pointer;
          min-height: 44px;
        }
        .argus-evidence .argus-detail {
          border-top: 2px solid var(--border, #466075);
          margin-top: 24px;
          padding-top: 16px;
        }
      </style>
      <section
        class="argus-evidence"
        aria-labelledby="argus-evidence-heading"
        aria-busy=${this.busy}
      >
        <p>ARGUS · Technical evidence</p>
        <h2 id="argus-evidence-heading">Here's what matters now.</h2>
        <p>
          External technical work captured through federation. This view does not cover every Argus
          task.
        </p>
        <p role="status">
          ${!connected
            ? "Disconnected — reconnect to verify current work."
            : this.busy
              ? "Loading operational evidence…"
              : this.error
                ? "Evidence unavailable; verify freshness before acting on loaded records."
                : this.page
                  ? `${this.page.items.length} loaded ${this.page.items.length === 1 ? "record" : "records"}. ${this.page.coverage.complete ? "Complete within the declared scope." : "Partial coverage."}`
                  : "Coverage unavailable."}
        </p>
        ${this.page
          ? html`<p>
              Observed ${operationTime(this.page.coverage.observed_at)} · Federated technical
              evidence ·
              ${this.page.coverage.scope.project}${this.page.coverage.scope.task_id
                ? ` · Task ${this.page.coverage.scope.task_id}`
                : ""}${this.page.coverage.scope.source
                ? ` · Source ${this.page.coverage.scope.source}`
                : ""}
            </p>`
          : nothing}
        ${this.error ? html`<p role="alert">${this.error}</p>` : nothing}
        <div class="argus-toolbar">
          <button class="btn" ?disabled=${!connected || this.busy} @click=${() => this.load()}>
            Refresh evidence
          </button>
          <label
            >Find in loaded work<input
              type="search"
              .value=${this.filter}
              @input=${(event: Event) => {
                this.filter = (event.target as HTMLInputElement).value;
              }}
          /></label>
        </div>
        <ul>
          ${items.map(
            (item) =>
              html`<li>
                <h3>${item.title}</h3>
                <p>${item.state} · ${item.kind} · ${item.source}</p>
                <p>Observed ${operationTime(item.observed_at)}</p>
                <p>
                  ${item.artifacts.length} artifact references ·
                  ${item.owner_accepted
                    ? "Owner acceptance recorded"
                    : "Owner acceptance not recorded"}
                </p>
                <button
                  class="btn"
                  ?disabled=${!connected || this.busy}
                  @click=${() => this.openDetail(item)}
                >
                  Open work details
                </button>
              </li>`,
          )}
        </ul>
        ${this.page && !items.length
          ? html`<p>
              ${this.filter
                ? "No loaded work matches this search."
                : "No technical work returned within this scope."}
            </p>`
          : nothing}
        ${this.page?.next_cursor
          ? html`<button
              class="btn"
              ?disabled=${!connected || this.busy}
              @click=${() => this.load(true)}
            >
              Load more evidence
            </button>`
          : nothing}
        ${this.detail
          ? html`<section class="argus-detail" aria-label="Work details">
              <h3 tabindex="-1">${this.detail.title}</h3>
              ${this.detail.newerObservation
                ? html`<p>
                    A newer observation is available for this task. Its evidence and artifacts are
                    shown below.
                  </p>`
                : nothing}
              <p>${this.detail.state} · ${this.detail.source}</p>
              <p>
                Event ${operationTime(this.detail.occurred_at)} · observed
                ${operationTime(this.detail.observed_at)}
              </p>
              <p>Owner acceptance ${this.detail.owner_accepted ? "recorded" : "not recorded"}.</p>
              <h3>Artifacts</h3>
              ${this.detail.artifacts.map(
                (artifact) =>
                  html`<p>
                    <button
                      class="btn"
                      ?disabled=${!connected || this.busy}
                      @click=${() => this.openArtifact(artifact)}
                    >
                      Verify artifact ${artifact.sha256.slice(0, 12)} (${artifact.bytes} bytes)
                    </button>
                  </p>`,
              )}${this.artifactUrl
                ? html`<a class="btn" href=${this.artifactUrl} target="_blank" rel="noopener"
                    >Open verified artifact</a
                  >`
                : nothing}
              <details>
                <summary>Evidence references and timeline</summary>
                <p>
                  ${this.detail.historyComplete
                    ? "Complete returned history within this task and producer."
                    : "Partial history; additional evidence exists."}
                </p>
                <p>Operation: ${this.detail.operation_id}</p>
                <p>Event: ${this.detail.event_id}</p>
                <ol>
                  ${this.detail.timeline.map(
                    (event) =>
                      html`<li>
                        ${event.state} · ${event.kind} · ${operationTime(event.occurred_at)}
                      </li>`,
                  )}
                </ol>
              </details>
            </section>`
          : nothing}
      </section>`;
  }
}
if (!customElements.get("argus-operational-view"))
  customElements.define("argus-operational-view", OperationalView);
