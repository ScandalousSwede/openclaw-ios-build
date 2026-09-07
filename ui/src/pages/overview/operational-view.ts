import { consume } from "@lit/context";
import { html, LitElement, nothing } from "lit";
import { state } from "lit/decorators.js";
import {
  applicationContext,
  type ApplicationContext,
  type ApplicationGatewaySnapshot,
} from "../../app/context.ts";

type EvidenceFilters = {
  project: string;
  task: string;
  source: string;
  from: string;
  before: string;
};
const defaultFilters = (): EvidenceFilters => ({
  project: "Argus",
  task: "",
  source: "",
  from: "",
  before: "",
});
const queryKeys = {
  project: "argus_project",
  task: "argus_task",
  source: "argus_source",
  from: "argus_from",
  before: "argus_before",
} as const;
const operationKey = "argus_operation";
const freshnessIntervalMs = 60_000;

function validateFilters(filters: EvidenceFilters): string | null {
  if (!["Argus", "MiKobots", "EPC"].includes(filters.project)) return "Choose a supported project.";
  if (filters.task.length > 160 || filters.source.length > 160)
    return "Task and source must be at most 160 characters.";
  for (const value of [filters.from, filters.before]) {
    if (
      value &&
      (value.length > 80 ||
        !/^\d{4}-\d{2}-\d{2}T.+(?:Z|[+-]\d{2}:\d{2})$/i.test(value) ||
        !Number.isFinite(Date.parse(value)))
    )
      return "Use an ISO observation time with a timezone, such as 2026-09-06T18:00:00Z.";
  }
  return null;
}

type Artifact = { sha256: string; bytes: number | null };
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
  evidence_scope?: string;
  executor_id?: string | null;
  capability_id?: string | null;
};
type Page = {
  items: Operation[];
  coverage: {
    scope: {
      corpus: string;
      project: string;
      task_id?: string | null;
      source?: string | null;
      recorded_from?: string | null;
      recorded_before?: string | null;
    };
    complete: boolean;
    has_more: boolean;
    snapshot_sequence: number;
    observed_at: string;
  };
  next_cursor: string | null;
};
type WorkContract = {
  schema: "argus.work.read-contract.v1";
  operation_id: string;
  requested_operation_id: string;
  requested_event_id: string;
  latest_event_id: string;
  native_observations: { event_id: string; adapter: string | null; outcome: string | null }[];
  structural_verification: {
    status: "not_established" | "passed_recorded" | "failed_recorded";
    semantic_correctness_established: false;
  };
  independent_verification: {
    semantic_correctness_established?: boolean;
    artifacts: {
      event_id: string;
      outcome: "PASS" | "FAIL";
      artifact_sha256: string;
      verifier_report_sha256: string;
      verification_kind?: string;
      semantic_correctness_established?: boolean;
    }[];
    covers_all_current_artifacts: boolean;
  };
  owner_disposition: { status: "not_established" };
  owner_accepted: false;
  pending_owner_feedback: { event_id: string; owner: string | null; reason: string | null }[];
  continuation: {
    mode: "read_only";
    action: "inspect_current_evidence";
    operation_id: string;
    event_id: string;
    artifact_sha256: string[];
    dispatch_enabled: false;
  };
  coverage: {
    scope: "canonical_operation_trace" | "canonical_federation_observation";
    complete: boolean;
    cross_scope_absence_established: false;
  };
  is_state_transition: false;
};
type DetailResponse = {
  work_contract?: WorkContract;
  item: Operation;
  requested: Operation;
  timeline: Operation[];
  coverage: { complete: boolean; has_more: boolean };
};
type Detail = Operation & {
  workContract: WorkContract | null;
  timeline: Operation[];
  newerObservation: boolean;
  historyComplete: boolean;
  requestedOperation: Operation;
};

function conciseTitle(value: string): string {
  const text = value.replace(/\s+/g, " ").trim();
  return text.length > 140 ? `${text.slice(0, 137).trimEnd()}…` : text;
}

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
  @state() private listUnavailable = false;
  @state() private detail: Detail | null = null;
  @state() private busy = false;
  @state() private error: string | null = null;
  @state() private filter = "";
  @state() private draftFilters: EvidenceFilters = defaultFilters();
  private appliedFilters: EvidenceFilters = defaultFilters();
  private selectedOperation: string | null = null;
  private lastRefreshAttempt = 0;
  private readonly onPopState = () => {
    this.generation++;
    this.busy = false;
    this.page = null;
    this.detail = null;
    this.clearArtifact();
    this.readLocation();
    void this.refresh();
  };
  private readonly onReturn = () => {
    if (
      document.visibilityState !== "hidden" &&
      Date.now() - this.lastRefreshAttempt >= freshnessIntervalMs
    )
      void this.refresh();
  };
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
    this.readLocation();
    window.addEventListener("popstate", this.onPopState);
    window.addEventListener("focus", this.onReturn);
    document.addEventListener("visibilitychange", this.onReturn);
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
      if (ready) void this.refresh();
    }
    this.requestUpdate();
  }
  override disconnectedCallback() {
    this.unsubscribe?.();
    window.removeEventListener("popstate", this.onPopState);
    window.removeEventListener("focus", this.onReturn);
    document.removeEventListener("visibilitychange", this.onReturn);
    this.generation++;
    this.connectionReady = false;
    this.busy = false;
    this.clearArtifact();
    super.disconnectedCallback();
  }
  private readLocation() {
    const query = new URLSearchParams(window.location.search);
    const filters = defaultFilters();
    for (const key of Object.keys(queryKeys) as (keyof EvidenceFilters)[]) {
      filters[key] = query.get(queryKeys[key]) ?? filters[key];
    }
    this.draftFilters = filters;
    this.appliedFilters = { ...filters };
    this.selectedOperation = query.get(operationKey);
    this.error =
      validateFilters(filters) ??
      (this.selectedOperation !== null &&
      (!this.selectedOperation.trim() || this.selectedOperation.length > 300)
        ? "The observation link has an invalid identity."
        : null);
  }
  private observationLink(operationId: string): string {
    // Only explicitly owned query fields travel in an evidence link; never auth hashes or other app query values.
    const url = new URL(window.location.pathname, window.location.origin);
    for (const key of Object.keys(queryKeys) as (keyof EvidenceFilters)[]) {
      if (this.appliedFilters[key]) url.searchParams.set(queryKeys[key], this.appliedFilters[key]);
    }
    url.searchParams.set(operationKey, operationId);
    return url.pathname + url.search;
  }
  private writeLocation() {
    const url = new URL(window.location.href);
    for (const key of Object.keys(queryKeys) as (keyof EvidenceFilters)[]) {
      if (this.appliedFilters[key]) url.searchParams.set(queryKeys[key], this.appliedFilters[key]);
      else url.searchParams.delete(queryKeys[key]);
    }
    if (this.selectedOperation) url.searchParams.set(operationKey, this.selectedOperation);
    else url.searchParams.delete(operationKey);
    window.history.replaceState(window.history.state, "", url);
  }
  private applyFilters(event: Event) {
    event.preventDefault();
    const filters = Object.fromEntries(
      Object.entries(this.draftFilters).map(([key, value]) => [key, value.trim()]),
    ) as EvidenceFilters;
    const invalid = validateFilters(filters);
    if (invalid) {
      this.error = invalid;
      return;
    }
    this.appliedFilters = filters;
    this.draftFilters = { ...filters };
    this.selectedOperation = null;
    this.filter = "";
    this.page = null;
    this.detail = null;
    this.clearArtifact();
    this.writeLocation();
    void this.refresh();
  }
  private async refresh() {
    if (this.busy || !this.context.gateway.snapshot.connected) return;
    const invalid = validateFilters(this.appliedFilters);
    if (
      invalid ||
      (this.selectedOperation !== null &&
        (!this.selectedOperation.trim() || this.selectedOperation.length > 300))
    ) {
      this.error = invalid ?? "The observation link has an invalid identity.";
      return;
    }
    this.lastRefreshAttempt = Date.now();
    const generation = this.generation;
    const selected = this.selectedOperation;
    await this.load();
    if (generation === this.generation && selected) await this.openDetailId(selected, false);
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
        project: this.appliedFilters.project,
        ...(this.appliedFilters.task ? { task_id: this.appliedFilters.task } : {}),
        ...(this.appliedFilters.source ? { source: this.appliedFilters.source } : {}),
        ...(this.appliedFilters.from ? { recorded_from: this.appliedFilters.from } : {}),
        ...(this.appliedFilters.before ? { recorded_before: this.appliedFilters.before } : {}),
        limit: 30,
        ...(more && this.page?.next_cursor ? { cursor: this.page.next_cursor } : {}),
      });
      if (generation !== this.generation) return;
      const previous = more ? (this.page?.items ?? []) : [];
      const items = new Map(previous.map((item) => [item.operation_id, item]));
      for (const item of page.items) items.set(item.operation_id, item);
      this.page = { ...page, items: [...items.values()] };
      this.listUnavailable = false;
      if (!more) {
        this.detail = null;
        this.clearArtifact();
      }
    } catch {
      if (generation === this.generation) {
        this.listUnavailable = true;
        this.error =
          "Operational evidence is unavailable. Reconnect or try Refresh. Previously loaded records are not current.";
      }
    } finally {
      if (generation === this.generation) this.busy = false;
    }
  }
  private async openDetail(operation: Operation) {
    await this.openDetailId(operation.operation_id, true);
  }
  private async openDetailId(operationId: string, updateLocation: boolean) {
    const { client, connected } = this.context.gateway.snapshot;
    if (!client || !connected || this.busy) return;
    const generation = this.generation;
    this.busy = true;
    this.error = null;
    this.clearArtifact();
    this.detail = null;
    if (updateLocation) {
      this.selectedOperation = operationId;
      this.writeLocation();
    }
    try {
      const detail = await client.request<DetailResponse>("argus.operations.detail", {
        operation_id: operationId,
      });
      if (detail.requested.operation_id !== operationId)
        throw new Error("Operation identity mismatch");
      const contract = detail.work_contract;
      const currentArtifacts = new Set(detail.item.artifacts.map((artifact) => artifact.sha256));
      // The read model must describe this exact requested/current pair. Never
      // attach verification or continuation from another observation to its artifacts.
      if (
        contract &&
        (contract.schema !== "argus.work.read-contract.v1" ||
          contract.operation_id !== detail.item.operation_id ||
          contract.latest_event_id !== detail.item.event_id ||
          contract.requested_operation_id !== detail.requested.operation_id ||
          contract.requested_event_id !== detail.requested.event_id ||
          contract.continuation.operation_id !== detail.item.operation_id ||
          contract.continuation.event_id !== detail.item.event_id ||
          contract.continuation.mode !== "read_only" ||
          contract.continuation.action !== "inspect_current_evidence" ||
          contract.continuation.dispatch_enabled !== false ||
          contract.continuation.artifact_sha256.some((digest) => !currentArtifacts.has(digest)) ||
          contract.independent_verification.artifacts.some(
            (verification) => !currentArtifacts.has(verification.artifact_sha256),
          ) ||
          contract.is_state_transition !== false ||
          contract.owner_accepted !== false)
      )
        throw new Error("Work contract identity or authority mismatch");
      if (generation === this.generation) {
        this.detail = {
          ...detail.item,
          workContract: contract ?? null,
          timeline: detail.timeline,
          newerObservation: detail.item.operation_id !== detail.requested.operation_id,
          historyComplete: detail.coverage.complete,
          requestedOperation: detail.requested,
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
        !Number.isSafeInteger(result.bytes) ||
        result.bytes < 0 ||
        result.bytes > 1_048_576 ||
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
        (artifact.bytes !== null && bytes.length !== artifact.bytes)
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
  private renderWorkContract(detail: Detail) {
    const contract = detail.workContract;
    if (!contract)
      return html`<p>Owner acceptance ${detail.owner_accepted ? "recorded" : "not recorded"}.</p>
        <p>
          Evidence basis is unavailable from this gateway. Verification and owner disposition are
          not inferred.
        </p>`;
    const structural = {
      not_established: "Not established in returned evidence",
      passed_recorded: "Passed structural check recorded",
      failed_recorded: "Failed structural check recorded",
    }[contract.structural_verification.status];
    const independent = contract.independent_verification;
    return html`<section class="argus-work-contract" aria-label="Evidence basis and continuation">
      <h3>Evidence basis</h3>
      <dl class="argus-evidence-basis">
        <dt>Native observation</dt>
        <dd>
          ${contract.native_observations.length
            ? html`<ul>
                ${contract.native_observations.map(
                  (observation) =>
                    html`<li>
                      ${observation.adapter ?? "Unknown producer"}:
                      ${observation.outcome ?? "outcome not recorded"} · producer observation
                    </li>`,
                )}
              </ul>`
            : "No native outcome included in this scope"}
        </dd>
        <dt>Structural verification</dt>
        <dd>
          ${structural ?? "Status unavailable"}. Semantic correctness is not established by this
          check.
        </dd>
        <dt>Independent verification</dt>
        <dd>
          ${independent.artifacts.length
            ? html`<p>
                  ${independent.covers_all_current_artifacts
                    ? "PASS receipts cover all current artifacts."
                    : "Returned receipts do not establish a pass for all current artifacts."}
                </p>
                <ul>
                  ${independent.artifacts.map(
                    (verification) =>
                      html`<li>
                        ${verification.outcome} · artifact ${verification.artifact_sha256}<br />Verifier
                        report ${verification.verifier_report_sha256}
                      </li>`,
                  )}
                </ul>`
            : "Not established in returned evidence"}
        </dd>
        <dt>Owner disposition</dt>
        <dd>Unknown in this reader. Owner acceptance not recorded.</dd>
      </dl>
      <p>
        ${contract.coverage.complete ? "Complete returned scope" : "Partial returned scope"} ·
        ${contract.coverage.scope === "canonical_federation_observation"
          ? "this federation observation"
          : "this canonical operation trace"}.
        Evidence outside this scope has not been ruled out.
      </p>
      <h3>Read-only continuation</h3>
      <p>
        <a href=${this.observationLink(contract.continuation.operation_id)}
          >Inspect current evidence</a
        >. Use the verified artifact controls above. Continuing execution requires the owning
        workflow; this view does not dispatch work or record a state transition.
      </p>
    </section>`;
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
        .argus-evidence-basis {
          display: grid;
          grid-template-columns: minmax(130px, 1fr) minmax(0, 3fr);
          gap: 12px 20px;
        }
        .argus-evidence-basis dt {
          font-weight: 650;
        }
        .argus-evidence-basis dd {
          margin: 0;
          overflow-wrap: anywhere;
        }
        .argus-evidence-basis ul,
        .argus-evidence-basis p {
          margin: 0;
        }
        @media (max-width: 640px) {
          .argus-evidence-basis {
            grid-template-columns: minmax(0, 1fr);
            gap: 4px;
          }
          .argus-evidence-basis dd {
            margin-bottom: 12px;
          }
        }
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
        .argus-evidence a {
          color: inherit;
          text-decoration: underline;
        }
        .argus-evidence button {
          padding: 10px 18px;
          border: 1px solid color-mix(in srgb, currentColor 55%, transparent);
          white-space: normal;
        }
        .argus-evidence .argus-scope-fields {
          display: grid;
          grid-template-columns: repeat(auto-fit, minmax(min(100%, 16rem), 1fr));
          gap: 16px;
          margin: 16px 0;
        }
        .argus-evidence select {
          font: inherit;
          min-height: 48px;
          width: 100%;
          padding: 10px;
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
        <p>Recorded technical work and its artifacts. Coverage is limited to admitted evidence.</p>
        <p role="status">
          ${!connected
            ? "Disconnected — reconnect to verify current work."
            : this.busy
              ? "Loading operational evidence…"
              : this.error || this.listUnavailable
                ? "Evidence unavailable; verify freshness before acting on loaded records."
                : this.page
                  ? `${this.page.items.length} loaded ${this.page.items.length === 1 ? "record" : "records"}. ${this.page.coverage.complete ? "Complete within the declared scope." : "Partial coverage."}`
                  : "Coverage unavailable."}
        </p>
        ${this.page
          ? html`<details>
              <summary>Evidence scope and freshness</summary>
              <p>
                Observed ${operationTime(this.page.coverage.observed_at)} · Technical evidence ·
                ${this.page.coverage.scope.project}${this.page.coverage.scope.task_id
                  ? ` · Task ${this.page.coverage.scope.task_id}`
                  : ""}${this.page.coverage.scope.source
                  ? ` · Source ${this.page.coverage.scope.source}`
                  : ""}
                ${this.page.coverage.scope.recorded_from
                  ? ` · From ${this.page.coverage.scope.recorded_from} (inclusive)`
                  : ""}
                ${this.page.coverage.scope.recorded_before
                  ? ` · Before ${this.page.coverage.scope.recorded_before} (exclusive)`
                  : ""}
              </p>
              <p>
                Snapshot evidence, not a live activity feed. Refreshes on reconnect and when
                returning after a minute.
              </p>
              <p>Corpus: ${this.page.coverage.scope.corpus}</p>
            </details>`
          : nothing}
        ${this.error ? html`<p role="alert">${this.error}</p>` : nothing}
        <details>
          <summary>Filter evidence by project, task, source or time</summary>
          <form @submit=${(event: Event) => this.applyFilters(event)}>
            <fieldset ?disabled=${this.busy}>
              <legend>Find evidence on the server</legend>
              <div class="argus-scope-fields">
                <label
                  >Project<select
                    @change=${(event: Event) => {
                      this.draftFilters = {
                        ...this.draftFilters,
                        project: (event.target as HTMLSelectElement).value,
                      };
                    }}
                  >
                    ${["Argus", "MiKobots", "EPC"].map(
                      (project) =>
                        html`<option
                          value=${project}
                          .selected=${project === this.draftFilters.project}
                        >
                          ${project}
                        </option>`,
                    )}
                  </select></label
                >
                ${(
                  [
                    ["task", "Exact task ID", 160],
                    ["source", "Exact source", 160],
                    ["from", "Observed from (inclusive, ISO time)", 80],
                    ["before", "Observed before (exclusive, ISO time)", 80],
                  ] as const
                ).map(
                  ([key, label, max]) => html`
                    <label
                      >${label}<input
                        type="text"
                        maxlength=${max}
                        .value=${this.draftFilters[key]}
                        placeholder=${key === "from" || key === "before"
                          ? "2026-09-06T18:00:00Z"
                          : "Any"}
                        @input=${(event: Event) => {
                          this.draftFilters = {
                            ...this.draftFilters,
                            [key]: (event.target as HTMLInputElement).value,
                          };
                        }}
                    /></label>
                  `,
                )}
              </div>
              <button class="btn" type="submit" ?disabled=${!connected || this.busy}>
                Apply evidence filters
              </button>
            </fieldset>
          </form>
        </details>
        <div class="argus-toolbar">
          <button class="btn" ?disabled=${!connected || this.busy} @click=${() => this.refresh()}>
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
                <h3>${conciseTitle(item.title)}</h3>
                <p>Recorded state: ${item.state}</p>
                <p>Observed ${operationTime(item.observed_at)}</p>
                <p>${item.artifacts.length} artifact references</p>
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
              <h3 tabindex="-1">${conciseTitle(this.detail.title)}</h3>
              <p>Recorded state: ${this.detail.state}</p>
              <p class="argus-disposition">
                ${this.detail.workContract?.independent_verification.covers_all_current_artifacts
                  ? this.detail.workContract.independent_verification
                      .semantic_correctness_established === false &&
                    this.detail.workContract.independent_verification.artifacts.length > 0 &&
                    this.detail.workContract.independent_verification.artifacts.every(
                      (entry) => entry.verification_kind === "structural_artifact_contract",
                    )
                    ? "Structural verification passed for the current artifacts. Semantic correctness is not established by this receipt."
                    : "Independent PASS receipts cover the current artifacts."
                  : this.detail.workContract?.independent_verification.artifacts.some(
                        (entry) => entry.outcome === "FAIL",
                      )
                    ? "An independent check reported a failure. Inspect the evidence."
                    : "Independent verification is not established for all current artifacts."}
              </p>
              ${this.detail.newerObservation
                ? html`<p>
                    A newer observation is available for this task. Showing current evidence; the
                    requested observation remains in provenance.
                  </p>`
                : nothing}
              ${this.detail.workContract?.pending_owner_feedback.length
                ? html`<section class="argus-owner-request" aria-label="Requested owner feedback">
                    <h4>Requested owner feedback</h4>
                    <ul>
                      ${this.detail.workContract.pending_owner_feedback.map(
                        (feedback) =>
                          html`<li>
                            ${feedback.owner ?? "Owner unspecified"}:
                            ${feedback.reason ?? "Reason not included"}
                          </li>`,
                      )}
                    </ul>
                  </section>`
                : nothing}
              <h3>Inspect the result</h3>
              ${!this.detail.artifacts.length
                ? html`<p>
                    No artifact references were returned. Inspect provenance for the recorded
                    evidence.
                  </p>`
                : nothing}
              ${this.detail.artifacts.map(
                (artifact) =>
                  html`<p>
                    <button
                      class="btn"
                      ?disabled=${!connected || this.busy}
                      @click=${() => this.openArtifact(artifact)}
                    >
                      Verify artifact ${artifact.sha256.slice(0, 12)}
                      (${artifact.bytes === null
                        ? "size checked on open"
                        : `${artifact.bytes} bytes`})
                    </button>
                  </p>`,
              )}${this.artifactUrl
                ? html`<a class="btn" href=${this.artifactUrl} target="_blank" rel="noopener"
                    >Open verified artifact</a
                  >`
                : nothing}
              <details>
                <summary>Provenance, verification and history</summary>
                <h4>Producer narrative</h4>
                <p>${this.detail.title}</p>
                <p>${this.detail.kind} · ${this.detail.source}</p>
                <p>Task: ${this.detail.task_id}</p>
                <p>Scope: ${this.detail.evidence_scope ?? "canonical_federation_observation"}</p>
                ${this.detail.executor_id
                  ? html`<p>Executor: ${this.detail.executor_id}</p>`
                  : nothing}
                ${this.detail.capability_id
                  ? html`<p>Capability: ${this.detail.capability_id}</p>`
                  : nothing}
                <p>
                  Event ${operationTime(this.detail.occurred_at)} · observed
                  ${operationTime(this.detail.observed_at)}
                </p>
                <p>
                  Detail follows this task and producer, including newer observations outside the
                  list's time window.
                </p>
                <p>
                  Read-only evidence. Continuing work requires the owning workflow; opening this
                  view does not dispatch work.
                </p>
                ${this.detail.newerObservation
                  ? html`<p>
                      This does not establish that the earlier observation was superseded.
                      Requested: ${this.detail.requestedOperation.title}
                      (${operationTime(this.detail.requestedOperation.observed_at)}).
                    </p>`
                  : nothing}
                <p>
                  <a href=${this.observationLink(this.detail.requestedOperation.operation_id)}
                    >Link to requested observation</a
                  >${this.detail.newerObservation
                    ? html` ·
                        <a href=${this.observationLink(this.detail.operation_id)}
                          >Link to current observation</a
                        >`
                    : nothing}
                </p>
                ${this.renderWorkContract(this.detail)}
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
