import { consume } from "@lit/context";
import { html, LitElement, nothing } from "lit";
import { state } from "lit/decorators.js";
import {
  applicationContext,
  type ApplicationContext,
  type ApplicationGatewaySnapshot,
} from "../../app/context.ts";
import {
  sameArtifactReviewBinding,
  type ArtifactReviewBinding,
  type ExecApprovalRequest,
} from "../../app/exec-approval.ts";
import { I18nController, t } from "../../i18n/index.ts";
import {
  parsePage,
  parseDetail,
  parseArtifactResponse,
  type Artifact,
  type Operation,
  type Page,
  type WorkContract,
  type ReviewHistory,
} from "./operational-contract.ts";
import { operationHeading } from "./operational-heading.ts";

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
const eventKey = "argus_event";
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

type Detail = Operation & {
  workContract: WorkContract | null;
  reviewHistory: ReviewHistory | null;
  timeline: Operation[];
  newerObservation: boolean;
  historyComplete: boolean;
  requestedOperation: Operation;
};

function operationTime(value: string): string {
  const date = new Date(value);
  return Number.isNaN(date.valueOf())
    ? "Observation time unavailable"
    : date.toLocaleString(undefined, { timeZoneName: "short" });
}

export class OperationalView extends LitElement {
  readonly i18nController = new I18nController(this);
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
  private selectedEvent: string | null = null;
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
      void this.refresh(true);
  };
  @state() private lastCheckedAt: string | null = null;
  private refreshTimer?: number;
  @state() private verifiedArtifact: { url: string; label: string } | null = null;
  @state() private reviewAvailable = false;
  @state() private pendingArtifactReviews: readonly ExecApprovalRequest[] = [];
  @state() private reviewBusy = false;
  @state() private reviewMessage: string | null = null;
  private unsubscribeOverlays?: () => void;
  private reviewRequestIdentity: { binding: string; key: string } | null = null;
  private unsubscribe?: () => void;
  private generation = 0;
  private connectionClient: unknown = null;
  private connectionReady = false;

  override createRenderRoot() {
    return this;
  }
  override connectedCallback() {
    super.connectedCallback();
    this.reviewAvailable = this.context.overlays?.snapshot.artifactReviewAvailable === true;
    this.pendingArtifactReviews = this.context.overlays?.snapshot.pendingArtifactReviews ?? [];
    this.unsubscribeOverlays = this.context.overlays?.subscribe((snapshot) => {
      this.reviewAvailable = snapshot.artifactReviewAvailable === true;
      this.pendingArtifactReviews = snapshot.pendingArtifactReviews ?? [];
    });
    this.readLocation();
    window.addEventListener("popstate", this.onPopState);
    window.addEventListener("focus", this.onReturn);
    document.addEventListener("visibilitychange", this.onReturn);
    this.unsubscribe = this.context.gateway.subscribe((snapshot) => this.updateGateway(snapshot));
    this.updateGateway(this.context.gateway.snapshot);
    this.refreshTimer = window.setInterval(this.onReturn, freshnessIntervalMs);
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
    this.unsubscribeOverlays?.();
    if (this.refreshTimer !== undefined) window.clearInterval(this.refreshTimer);
    this.refreshTimer = undefined;
    window.removeEventListener("popstate", this.onPopState);
    window.removeEventListener("focus", this.onReturn);
    document.removeEventListener("visibilitychange", this.onReturn);
    this.generation++;
    this.connectionReady = false;
    this.busy = false;
    this.clearArtifact();
    super.disconnectedCallback();
    this.unsubscribeOverlays?.();
    this.unsubscribeOverlays = undefined;
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
    this.selectedEvent = query.get(eventKey);
    this.error = validateFilters(filters) ?? this.invalidSelection();
  }
  private invalidSelection() {
    return [this.selectedOperation, this.selectedEvent].some(
      (id) => id !== null && (!id.trim() || id.length > 300),
    ) ||
      (this.selectedEvent !== null && this.selectedOperation === null)
      ? "The observation link has an invalid identity."
      : null;
  }
  private observationLink(operationId: string, eventId?: string): string {
    // Only explicitly owned query fields travel in an evidence link; never auth hashes or other app query values.
    const url = new URL(window.location.pathname, window.location.origin);
    for (const key of Object.keys(queryKeys) as (keyof EvidenceFilters)[]) {
      if (this.appliedFilters[key]) url.searchParams.set(queryKeys[key], this.appliedFilters[key]);
    }
    url.searchParams.set(operationKey, operationId);
    if (eventId) url.searchParams.set(eventKey, eventId);
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
    if (this.selectedEvent) url.searchParams.set(eventKey, this.selectedEvent);
    else url.searchParams.delete(eventKey);
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
    this.selectedEvent = null;
    this.filter = "";
    this.page = null;
    this.detail = null;
    this.clearArtifact();
    this.writeLocation();
    void this.refresh();
  }
  private async refresh(background = false) {
    if (this.busy || !this.context.gateway.snapshot.connected) return;
    const invalid = validateFilters(this.appliedFilters) ?? this.invalidSelection();
    if (invalid) {
      this.error = invalid;
      return;
    }
    this.lastRefreshAttempt = Date.now();
    const generation = this.generation;
    const selected = this.selectedOperation;
    await this.load(false, background);
    // Detail is an independent read: a failed list must not block a known observation link.
    if (generation === this.generation && selected)
      await this.openDetailId(selected, false, background, this.selectedEvent ?? undefined);
  }
  private clearArtifact() {
    if (this.verifiedArtifact) URL.revokeObjectURL(this.verifiedArtifact.url);
    this.verifiedArtifact = null;
  }
  private async load(more = false, preserveDetail = false) {
    const { client, connected } = this.context.gateway.snapshot;
    if (!client || !connected || this.busy) return;
    const generation = this.generation;
    this.busy = true;
    this.error = null;
    try {
      const page = parsePage(
        await client.request<unknown>("argus.operations.list", {
          project: this.appliedFilters.project,
          ...(this.appliedFilters.task ? { task_id: this.appliedFilters.task } : {}),
          ...(this.appliedFilters.source ? { source: this.appliedFilters.source } : {}),
          ...(this.appliedFilters.from ? { recorded_from: this.appliedFilters.from } : {}),
          ...(this.appliedFilters.before ? { recorded_before: this.appliedFilters.before } : {}),
          limit: 30,
          ...(more && this.page?.next_cursor ? { cursor: this.page.next_cursor } : {}),
        }),
      );
      if (generation !== this.generation) return;
      const previous = more ? (this.page?.items ?? []) : [];
      const items = new Map(previous.map((item) => [item.operation_id, item]));
      for (const item of page.items) items.set(item.operation_id, item);
      this.page = { ...page, items: [...items.values()] };
      this.listUnavailable = false;
      this.lastCheckedAt = new Date().toISOString();
      if (!more && !preserveDetail) {
        this.detail = null;
        this.clearArtifact();
      }
    } catch {
      if (generation === this.generation) {
        this.clearArtifact();
        this.detail = null;
        this.listUnavailable = true;
        this.error =
          "Operational evidence is unavailable. Reconnect or try Refresh. Previously loaded records are not current.";
      }
    } finally {
      if (generation === this.generation) this.busy = false;
    }
  }
  private async openDetail(operation: Operation) {
    await this.openDetailId(operation.operation_id, true, false, operation.event_id);
  }
  private async openDetailId(
    operationId: string,
    updateLocation: boolean,
    background = false,
    eventId?: string,
  ) {
    const { client, connected } = this.context.gateway.snapshot;
    if (!client || !connected || this.busy) return;
    const generation = this.generation;
    this.busy = true;
    this.error = null;
    const previousDetail = this.detail;
    if (!background) {
      this.clearArtifact();
      this.detail = null;
    }
    if (updateLocation) {
      this.selectedOperation = operationId;
      this.selectedEvent = eventId ?? null;
      this.writeLocation();
    }
    try {
      const detail = parseDetail(
        await client.request<unknown>("argus.operations.detail", {
          operation_id: operationId,
          ...(eventId ? { event_id: eventId } : {}),
        }),
        operationId,
        eventId,
      );
      if (generation === this.generation) {
        if (
          background &&
          (!previousDetail ||
            previousDetail.operation_id !== detail.item.operation_id ||
            previousDetail.event_id !== detail.item.event_id ||
            JSON.stringify(previousDetail.artifact_context ?? null) !==
              JSON.stringify(detail.item.artifact_context ?? null) ||
            JSON.stringify(previousDetail.artifacts) !== JSON.stringify(detail.item.artifacts) ||
            JSON.stringify(previousDetail.timeline) !== JSON.stringify(detail.timeline) ||
            JSON.stringify(previousDetail.requestedOperation) !== JSON.stringify(detail.requested))
        )
          this.clearArtifact();
        if (
          this.detail?.event_id !== detail.item.event_id ||
          this.detail?.operation_id !== detail.item.operation_id
        )
          this.reviewMessage = null;
        this.detail = {
          ...detail.item,
          workContract: detail.work_contract ?? null,
          reviewHistory: detail.review_history ?? null,
          timeline: detail.timeline,
          newerObservation:
            detail.item.operation_id !== detail.requested.operation_id ||
            detail.item.event_id !== detail.requested.event_id,
          historyComplete: detail.coverage.complete,
          requestedOperation: detail.requested,
        };
        await this.updateComplete;
        if (!background) this.querySelector<HTMLElement>(".argus-detail h3")?.focus();
      }
    } catch {
      if (generation === this.generation) {
        this.clearArtifact();
        this.detail = null;
        this.error = "Work detail is unavailable. Refresh and retry.";
      }
    } finally {
      if (generation === this.generation) this.busy = false;
    }
  }
  private async openArtifact(operation: Operation, artifact: Artifact, label: string) {
    const { client, connected } = this.context.gateway.snapshot;
    if (!client || !connected || !this.detail || this.busy) return;
    const generation = this.generation;
    this.busy = true;
    this.error = null;
    this.clearArtifact();
    try {
      const result = parseArtifactResponse(
        await client.request<unknown>("argus.operations.artifact", {
          operation_id: operation.operation_id,
          event_id: operation.event_id,
          sha256: artifact.sha256,
        }),
      );
      if (generation !== this.generation) return;
      if (
        result.sha256 !== artifact.sha256 ||
        (result.operation_id !== undefined && result.operation_id !== operation.operation_id) ||
        result.event_id !== operation.event_id ||
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
        this.verifiedArtifact = {
          url: URL.createObjectURL(new Blob([bytes], { type: result.mime_type })),
          label: `${label} ${artifact.display_name ? `${artifact.display_name} · ` : ""}${artifact.sha256.slice(0, 12)}`,
        };
    } catch {
      if (generation === this.generation)
        this.error = "Artifact could not be verified or is unavailable. No file was opened.";
    } finally {
      if (generation === this.generation) this.busy = false;
    }
  }
  private renderArtifacts(operation: Operation, earlier = false) {
    const label = earlier
      ? "earlier-observation artifact"
      : operation.artifact_context?.relation === "previous_attempt"
        ? "previous-attempt artifact"
        : "artifact";
    return operation.artifacts.map(
      (artifact) => html`<p>
        <button
          class="btn"
          ?disabled=${!this.connectionReady || this.busy}
          @click=${() => this.openArtifact(operation, artifact, label)}
        >
          ${`Verify ${label} ${artifact.display_name ? `${artifact.display_name} · ` : ""}${artifact.sha256.slice(0, 12)} (${artifact.bytes === null ? "size checked on open" : `${artifact.bytes} bytes`})`}
        </button>
      </p>`,
    );
  }
  private renderEarlierArtifacts(detail: Detail) {
    // A requested observation can fall outside the bounded timeline.
    const observations = new Map(
      detail.timeline.map((operation) => [operation.event_id, operation]),
    );
    observations.set(detail.requestedOperation.event_id, detail.requestedOperation);
    const earlier = [...observations.values()].filter(
      (operation) =>
        operation.event_id !== detail.event_id &&
        operation.artifacts.length > 0 &&
        (operation.operation_id !== detail.operation_id ||
          operation.kind === "codex.completion.artifact_produced" ||
          operation.event_id === detail.requestedOperation.event_id),
    );
    if (!earlier.length) return nothing;
    return html`<details class="argus-earlier-artifacts">
      <summary>
        Earlier artifacts (${earlier.length}
        ${earlier.length === 1 ? "observation" : "observations"})
      </summary>
      <p>
        These artifacts belong to earlier observations. They do not establish a result for the
        current work.
      </p>
      ${earlier.map(
        (operation) => html`<section aria-label="Earlier observation">
          <h4>${operationHeading(operation)}</h4>
          <p>
            <span title=${operation.state}
              >Recorded state: ${operation.state.replaceAll("_", " ")}</span
            >
            · Observed ${operationTime(operation.observed_at)}
          </p>
          <a href=${this.observationLink(operation.operation_id, operation.event_id)}
            >Link to this earlier observation</a
          >
          ${this.renderArtifacts(operation, true)}
        </section>`,
      )}
    </details>`;
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
        <a
          href=${this.observationLink(
            contract.continuation.operation_id,
            contract.continuation.event_id,
          )}
          >Inspect current evidence</a
        >. Use the verified artifact controls above. Continuing execution requires the owning
        workflow; this view does not dispatch work or record a state transition.
      </p>
    </section>`;
  }
  private renderReviewHistory() {
    const history = this.detail?.reviewHistory;
    const time = (value: number) => {
      const date = new Date(value);
      return Number.isNaN(date.valueOf())
        ? "Time unavailable"
        : date.toLocaleString(undefined, { timeZoneName: "short" });
    };
    return html`<section class="argus-review-history" aria-label="Recorded operator reviews">
      <details>
        <summary>Recorded operator reviews${history ? ` (${history.items.length})` : ""}</summary>
        ${!history
          ? html`<p>Operator review history was not supplied by this reader.</p>`
          : html`
              <p>
                Receipt-qualified operator records in the admitted review corpus at snapshot
                ${history.coverage.snapshot_sequence}.
                ${history.coverage.complete && !history.coverage.has_more
                  ? "Complete within this returned scope."
                  : "Partial coverage; additional records may exist."}
              </p>
              <p>
                This history does not establish a currently actionable review, owner acceptance,
                scientific correctness or independent verification.
              </p>
              ${history.items.length === 0
                ? html`<p>No qualified review records were returned in this scope.</p>`
                : html`<ol>
                    ${history.items.map(
                      (review) => html`<li>
                        <p>
                          <strong
                            >${review.state === "pending"
                              ? "Review requested"
                              : review.state === "accepted"
                                ? "Operator accepted the bound artifact"
                                : "Operator rejected the bound artifact"}</strong
                          >
                          ·
                          ${review.binding_relation === "current"
                            ? "Current artifact binding"
                            : "Earlier evidence binding"}
                        </p>
                        ${review.state === "pending"
                          ? html`<p>No qualified disposition recorded.</p>`
                          : html`<p>
                              Authenticated operator disposition recorded
                              ${time(review.disposition!.recorded_at_ms)}.
                            </p>`}
                        <p>
                          Requested ${time(review.requested_at_ms)}. Request expiry
                          ${time(review.expires_at_ms)}${review.expires_at_ms <= Date.now()
                            ? " (passed)"
                            : ""}.
                        </p>
                        <p>
                          Review <code>${review.id}</code> · Request event
                          <code>${review.request_event_id}</code>${review.disposition
                            ? html` · Disposition event <code>${review.disposition.event_id}</code>`
                            : nothing}
                        </p>
                        <p>Bound event <code>${review.binding.event_id}</code></p>
                        <p>
                          Artifact SHA-256:
                          ${review.binding.artifact_sha256.map(
                            (hash) => html`<code>${hash}</code> `,
                          )}
                        </p>
                      </li>`,
                    )}
                  </ol>`}
            `}
      </details>
    </section>`;
  }
  private currentReviewBinding(): ArtifactReviewBinding | null {
    return this.detail
      ? {
          operation_id: this.detail.operation_id,
          event_id: this.detail.event_id,
          artifact_sha256: this.detail.artifacts.map((a) => a.sha256).sort(),
        }
      : null;
  }
  private hasPendingArtifactReview(): boolean {
    const binding = this.currentReviewBinding();
    return Boolean(
      binding &&
      this.pendingArtifactReviews.some(
        (entry) =>
          entry.expiresAtMs > Date.now() &&
          entry.artifactReview &&
          sameArtifactReviewBinding(entry.artifactReview.binding, binding),
      ),
    );
  }
  private canRequestArtifactReview(): boolean {
    return (
      this.reviewAvailable &&
      this.detail?.evidence_scope === "admitted_canonical_technical_operation" &&
      this.detail.capability_id === "codex.completion" &&
      this.detail.artifact_context?.relation === "current_attempt" &&
      this.detail.artifacts.length > 0 &&
      this.detail.artifacts.length <= 64
    );
  }

  private async requestArtifactReview() {
    const client = this.context.gateway.snapshot.client;
    if (
      !client ||
      !this.context.gateway.snapshot.connected ||
      !this.detail ||
      !this.canRequestArtifactReview() ||
      this.reviewBusy
    )
      return;
    const generation = this.generation;
    const binding = {
      operation_id: this.detail.operation_id,
      event_id: this.detail.event_id,
      artifact_sha256: this.detail.artifacts.map((a) => a.sha256).sort(),
    };
    const identity = JSON.stringify(binding);
    if (this.reviewRequestIdentity?.binding !== identity)
      this.reviewRequestIdentity = {
        binding: identity,
        key: `artifact-review:${crypto.randomUUID()}`,
      };
    this.reviewBusy = true;
    this.reviewMessage = null;
    try {
      const opened = await this.context.overlays.refreshApprovals?.(
        binding,
        () =>
          generation === this.generation &&
          this.context.gateway.snapshot.client === client &&
          Boolean(
            this.currentReviewBinding() &&
            sameArtifactReviewBinding(this.currentReviewBinding()!, binding),
          ),
      );
      if (
        generation !== this.generation ||
        this.context.gateway.snapshot.client !== client ||
        !this.currentReviewBinding() ||
        !sameArtifactReviewBinding(this.currentReviewBinding()!, binding)
      )
        return;
      if (!this.reviewAvailable) throw new Error("Review list unavailable");
      if (opened) {
        this.reviewMessage =
          "Opened the current pending review. No new request or decision was submitted.";
        return;
      }
      await client.request("plugin.approval.request", {
        kind: "artifact_review",
        binding,
        idempotency_key: this.reviewRequestIdentity.key,
        title: "Review current artifact",
        description:
          "Record an authenticated operator disposition for this exact current artifact.",
      });
      if (
        generation !== this.generation ||
        this.context.gateway.snapshot.client !== client ||
        this.detail?.event_id !== binding.event_id
      )
        return;
      this.reviewMessage =
        "Review request recorded. This action does not submit an artifact decision.";
      await this.context.overlays.refreshApprovals?.();
    } catch {
      if (generation === this.generation && this.detail?.event_id === binding.event_id)
        this.reviewMessage =
          "Artifact review unavailable or evidence changed. Refresh evidence and try again.";
    } finally {
      this.reviewBusy = false;
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
        .argus-selected-title {
          overflow-wrap: anywhere;
          white-space: normal;
          font-size: 1.05rem;
          line-height: 1.5;
        }
        .argus-review-history code {
          overflow-wrap: anywhere;
        }
        .argus-review-history li {
          margin-block: 1rem;
        }
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
          .argus-selected-title {
            overflow-wrap: anywhere;
            white-space: normal;
            font-size: 1.05rem;
            line-height: 1.5;
          }
          .argus-review-history code {
            overflow-wrap: anywhere;
          }
          .argus-review-history li {
            margin-block: 1rem;
          }
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
          gap: 12px;
          margin: 12px 0;
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
        .argus-evidence .argus-work-list {
          gap: 8px;
          max-height: 20rem;
          overflow-y: auto;
          padding: 4px;
          margin: 8px -4px;
        }
        .argus-evidence .argus-work-list > li {
          border: 0;
          padding: 0;
        }
        .argus-evidence .argus-work-row {
          display: grid;
          grid-template-columns: minmax(0, 1fr) auto;
          align-items: center;
          gap: 4px 12px;
          width: 100%;
          text-align: left;
          border: 1px solid var(--border);
          border-radius: var(--radius-md, 8px);
          background: var(--card);
          color: inherit;
          padding: 10px 12px;
          line-height: 1.4;
        }
        .argus-evidence .argus-work-row[aria-current="true"] {
          border-color: var(--accent);
          box-shadow: inset 3px 0 0 var(--accent);
          background: color-mix(in srgb, var(--accent) 8%, var(--card));
        }
        .argus-work-title {
          display: -webkit-box;
          -webkit-box-orient: vertical;
          -webkit-line-clamp: 2;
          overflow: hidden;
          font-size: 1rem;
          font-weight: 650;
        }
        .argus-work-context {
          grid-column: 1 / -1;
          font-size: 0.875rem;
        }
        .argus-work-action {
          font-size: 0.875rem;
          font-weight: 600;
        }
        @media (max-width: 640px) {
          .argus-evidence .argus-work-list {
            max-height: 14rem;
          }
          .argus-evidence .argus-work-row {
            grid-template-columns: minmax(0, 1fr);
            gap: 4px;
          }
          .argus-work-action {
            grid-row: 4;
          }
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
          margin-top: 16px;
          padding-top: 12px;
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
                  ? `${t(this.page.items.length === 1 ? "argusEvidence.loadedRecord" : "argusEvidence.loadedRecords", { count: String(this.page.items.length) })} ${t(this.page.coverage.complete ? "argusEvidence.allRecordsLoaded" : "argusEvidence.partialRecords")}`
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
        ${this.lastCheckedAt
          ? html`<p>
              Evidence last checked ${operationTime(this.lastCheckedAt)}.
              ${this.page?._authority_read?.snapshot_age_seconds !== undefined
                ? html`Snapshot age at that check:
                  ${Math.max(0, Math.round(this.page._authority_read.snapshot_age_seconds))}
                  seconds.`
                : html`Snapshot age is unavailable.`}
              This visible view checks every 60 seconds; the evidence projection normally updates
              every 5 minutes.
            </p>`
          : nothing}
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
        <ul class="argus-work-list" aria-label="Work observations">
          ${items.map(
            (item) => html`<li>
              <button
                class="argus-work-row"
                aria-current=${this.selectedOperation === item.operation_id &&
                (!this.selectedEvent || this.selectedEvent === item.event_id)
                  ? "true"
                  : "false"}
                ?disabled=${!connected || this.busy}
                @click=${() => this.openDetail(item)}
              >
                <span class="argus-work-title" title=${item.display?.label ?? item.title}
                  >${operationHeading(item)}</span
                >
                <span class="argus-work-action">
                  ${this.selectedOperation === item.operation_id &&
                  (!this.selectedEvent || this.selectedEvent === item.event_id)
                    ? "Selected"
                    : "Open work details"}
                </span>
                <span class="argus-work-context">
                  <span title=${item.state}
                    >Recorded state: ${item.state.replaceAll("_", " ")}</span
                  >
                  ·
                  ${t(
                    item.artifacts.length === 1
                      ? "argusEvidence.artifactReference"
                      : "argusEvidence.artifactReferences",
                    { count: String(item.artifacts.length) },
                  )}
                  ${item.artifact_context?.relation === "previous_attempt"
                    ? " · Previous-attempt evidence"
                    : item.artifact_context?.relation === "current_attempt"
                      ? " · Current-attempt evidence"
                      : ""}
                </span>
                <span class="argus-work-context">Observed ${operationTime(item.observed_at)}</span>
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
              <h3 class="argus-selected-title" tabindex="-1">${operationHeading(this.detail)}</h3>
              <p>
                <span title=${this.detail.state}
                  >Recorded state: ${this.detail.state.replaceAll("_", " ")}</span
                >
              </p>
              ${operationHeading(this.detail) !== (this.detail.display?.label ?? this.detail.title)
                ? html`<p class="argus-source-summary">${this.detail.title}</p>`
                : nothing}
              ${this.detail.display?.change_summary
                ? html`<p>${this.detail.display.change_summary}</p>`
                : nothing}
              ${this.detail.display?.artifact_label && this.detail.artifacts.length
                ? html`<p>Artifact: ${this.detail.display.artifact_label}</p>`
                : nothing}
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
              ${this.detail.artifact_context?.relation === "previous_attempt"
                ? html`<p class="argus-artifact-attempt">
                    No artifact from the current attempt is available. The evidence below belongs to
                    a previous attempt.
                  </p>`
                : nothing}
              <h3>
                ${this.detail.artifact_context?.relation === "previous_attempt"
                  ? "Inspect previous-attempt evidence"
                  : this.detail.artifact_context?.relation === "current_attempt" ||
                      this.detail.artifact_context?.relation === "federation_observation"
                    ? this.detail.artifacts.length
                      ? "Inspect the result"
                      : "Inspect recorded evidence"
                    : "Inspect available evidence"}
              </h3>
              ${!this.detail.artifacts.length
                ? html`<p>
                    No artifact references were returned for the current observation. Earlier
                    artifacts, when available, are listed below.
                  </p>`
                : nothing}
              ${this.renderArtifacts(this.detail)} ${this.renderEarlierArtifacts(this.detail)}
              ${this.verifiedArtifact
                ? html`<a
                    class="btn"
                    href=${this.verifiedArtifact.url}
                    target="_blank"
                    rel="noopener"
                    >Open verified ${this.verifiedArtifact.label}</a
                  >`
                : nothing}
              ${this.detail.display?.continuation_label
                ? html`<p>${this.detail.display.continuation_label}</p>`
                : nothing}
              ${this.canRequestArtifactReview()
                ? html`<p>
                    <button
                      class="btn"
                      ?disabled=${this.reviewBusy || this.busy}
                      @click=${() => this.requestArtifactReview()}
                    >
                      ${this.hasPendingArtifactReview()
                        ? "Open pending review"
                        : "Request operator review"}
                    </button>
                  </p>`
                : nothing}
              ${this.reviewMessage ? html`<p role="status">${this.reviewMessage}</p>` : nothing}
              ${this.renderReviewHistory()}
              <details>
                <summary>Provenance, verification and history</summary>
                <p>Recorded state value: ${this.detail.state}</p>
                <h4>Producer narrative</h4>
                <p>${this.detail.title}</p>
                <p>${this.detail.kind} · ${this.detail.source}</p>
                <p>Task: ${this.detail.task_id}</p>
                ${this.detail.artifact_context
                  ? html`<p>
                      Artifact relation: ${this.detail.artifact_context.relation}.
                      ${this.detail.artifact_context.relation === "federation_observation"
                        ? "Artifact links belong to this observation."
                        : html`Current attempt
                          ${this.detail.artifact_context.current_attempt_id ?? "not recorded"} ·
                          artifact attempt
                          ${this.detail.artifact_context.artifact_attempt_id ?? "not recorded"}`}
                    </p>`
                  : nothing}
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
                  <a
                    href=${this.observationLink(
                      this.detail.requestedOperation.operation_id,
                      this.detail.requestedOperation.event_id,
                    )}
                    >Link to requested observation</a
                  >${this.detail.newerObservation
                    ? html` ·
                        <a
                          href=${this.observationLink(
                            this.detail.operation_id,
                            this.detail.event_id,
                          )}
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
