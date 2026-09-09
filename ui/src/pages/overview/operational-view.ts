import { consume } from "@lit/context";
import { LitElement, nothing } from "lit";
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
import { SHELL_APPROVALS_OPEN_EVENT } from "../../app/lazy-shell-action.ts";
import { hasOperatorReadAccess } from "../../app/operator-access.ts";
import { I18nController } from "../../i18n/index.ts";
import {
  parsePage,
  parseDetail,
  parseArtifactResponse,
  type Artifact,
  type Operation,
  type Page,
} from "./operational-contract.ts";
import { renderOperationalDetail, type Detail } from "./operational-detail.ts";
import { renderOperationalEvidence, type EvidenceFilters } from "./operational-presentation.ts";

const defaultFilters = (): EvidenceFilters => ({
  project: "Argus",
  task: "",
  source: "",
  from: "",
  before: "",
});
const queryKeys = [
  ["project", "argus_project"],
  ["task", "argus_task"],
  ["source", "argus_source"],
  ["from", "argus_from"],
  ["before", "argus_before"],
] as const;
const operationKey = "argus_operation";
const eventKey = "argus_event";
const freshnessIntervalMs = 60_000;

function validateFilters(filters: EvidenceFilters): string | null {
  if (!["Argus", "MiKobots", "EPC"].includes(filters.project)) {
    return "Choose a supported project.";
  }
  if (filters.task.length > 160 || filters.source.length > 160) {
    return "Task and source must be at most 160 characters.";
  }
  for (const value of [filters.from, filters.before]) {
    if (
      value &&
      (value.length > 80 ||
        !/^\d{4}-\d{2}-\d{2}T.+(?:Z|[+-]\d{2}:\d{2})$/i.test(value) ||
        !Number.isFinite(Date.parse(value)))
    ) {
      return "Use an ISO observation time with a timezone, such as 2026-09-06T18:00:00Z.";
    }
  }
  return null;
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
    ) {
      void this.refresh(true);
    }
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
  private canRead(snapshot = this.context.gateway.snapshot): boolean {
    return (
      snapshot.phase === "connected" &&
      snapshot.client !== null &&
      hasOperatorReadAccess(snapshot.hello?.auth ?? null)
    );
  }
  private updateGateway(snapshot: ApplicationGatewaySnapshot) {
    const clientChanged = snapshot.client !== this.connectionClient;
    const allowed = hasOperatorReadAccess(snapshot.hello?.auth ?? null);
    const ready = this.canRead(snapshot);
    const readinessChanged = ready !== this.connectionReady;
    this.connectionClient = snapshot.client;
    this.connectionReady = ready;
    if (clientChanged || readinessChanged || !allowed) {
      // A reconnect reuses its client. Invalidate pending reads at readiness
      // edges so late responses cannot replace the next connection's evidence.
      this.generation++;
      this.busy = false;
      this.clearArtifact();
      this.detail = null;
      if (clientChanged || !allowed) {
        this.page = null;
      }
      if (ready) {
        void this.refresh();
      }
    }
    this.requestUpdate();
  }
  override disconnectedCallback() {
    this.unsubscribe?.();
    this.unsubscribeOverlays?.();
    if (this.refreshTimer !== undefined) {
      window.clearInterval(this.refreshTimer);
    }
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
    for (const [key, queryKey] of queryKeys) {
      filters[key] = query.get(queryKey) ?? filters[key];
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
    for (const [key, queryKey] of queryKeys) {
      if (this.appliedFilters[key]) {
        url.searchParams.set(queryKey, this.appliedFilters[key]);
      }
    }
    url.searchParams.set(operationKey, operationId);
    if (eventId) {
      url.searchParams.set(eventKey, eventId);
    }
    return url.pathname + url.search;
  }
  private writeLocation() {
    const url = new URL(window.location.href);
    for (const [key, queryKey] of queryKeys) {
      if (this.appliedFilters[key]) {
        url.searchParams.set(queryKey, this.appliedFilters[key]);
      } else {
        url.searchParams.delete(queryKey);
      }
    }
    if (this.selectedOperation) {
      url.searchParams.set(operationKey, this.selectedOperation);
    } else {
      url.searchParams.delete(operationKey);
    }
    if (this.selectedEvent) {
      url.searchParams.set(eventKey, this.selectedEvent);
    } else {
      url.searchParams.delete(eventKey);
    }
    window.history.replaceState(window.history.state, "", url);
  }
  private applyFilters(event: Event) {
    event.preventDefault();
    const filters = defaultFilters();
    for (const [key] of queryKeys) {
      filters[key] = this.draftFilters[key].trim();
    }
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
    if (this.busy || !this.canRead()) {
      return;
    }
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
    if (generation === this.generation && selected) {
      await this.openDetailId(selected, false, background, this.selectedEvent ?? undefined);
    }
  }
  private clearArtifact() {
    if (this.verifiedArtifact) {
      URL.revokeObjectURL(this.verifiedArtifact.url);
    }
    this.verifiedArtifact = null;
  }
  private async load(more = false, preserveDetail = false) {
    const { client } = this.context.gateway.snapshot;
    const connected = this.canRead();
    if (!client || !connected || this.busy) {
      return;
    }
    const generation = this.generation;
    this.busy = true;
    this.error = null;
    try {
      const page = parsePage(
        await client.request("argus.operations.list", {
          project: this.appliedFilters.project,
          ...(this.appliedFilters.task ? { task_id: this.appliedFilters.task } : {}),
          ...(this.appliedFilters.source ? { source: this.appliedFilters.source } : {}),
          ...(this.appliedFilters.from ? { recorded_from: this.appliedFilters.from } : {}),
          ...(this.appliedFilters.before ? { recorded_before: this.appliedFilters.before } : {}),
          limit: 30,
          ...(more && this.page?.next_cursor ? { cursor: this.page.next_cursor } : {}),
        }),
      );
      if (generation !== this.generation || !this.canRead()) {
        return;
      }
      const previous = more ? (this.page?.items ?? []) : [];
      const items = new Map(previous.map((item) => [item.operation_id, item]));
      for (const item of page.items) {
        items.set(item.operation_id, item);
      }
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
      if (generation === this.generation) {
        this.busy = false;
      }
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
    const { client } = this.context.gateway.snapshot;
    const connected = this.canRead();
    if (!client || !connected || this.busy) {
      return;
    }
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
        await client.request("argus.operations.detail", {
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
        ) {
          this.clearArtifact();
        }
        if (
          this.detail?.event_id !== detail.item.event_id ||
          this.detail?.operation_id !== detail.item.operation_id
        ) {
          this.reviewMessage = null;
        }
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
        if (!background) {
          this.querySelector<HTMLElement>(".argus-detail h3")?.focus();
        }
      }
    } catch {
      if (generation === this.generation) {
        this.clearArtifact();
        this.detail = null;
        this.error = "Work detail is unavailable. Refresh and retry.";
      }
    } finally {
      if (generation === this.generation) {
        this.busy = false;
      }
    }
  }
  private async openArtifact(operation: Operation, artifact: Artifact, label: string) {
    const { client } = this.context.gateway.snapshot;
    const connected = this.canRead();
    if (!client || !connected || !this.detail || this.busy) {
      return;
    }
    const generation = this.generation;
    this.busy = true;
    this.error = null;
    this.clearArtifact();
    try {
      const result = parseArtifactResponse(
        await client.request("argus.operations.artifact", {
          operation_id: operation.operation_id,
          event_id: operation.event_id,
          sha256: artifact.sha256,
        }),
      );
      if (generation !== this.generation || !this.canRead()) {
        return;
      }
      if (
        result.sha256 !== artifact.sha256 ||
        (result.operation_id !== undefined && result.operation_id !== operation.operation_id) ||
        result.event_id !== operation.event_id ||
        !Number.isSafeInteger(result.bytes) ||
        result.bytes < 0 ||
        result.bytes > 1_048_576 ||
        result.content_base64.length > 1_398_104 ||
        !["text/plain", "text/markdown", "application/pdf", "image/png", "image/jpeg"].includes(
          (result.mime_type.split(";")[0] ?? "").trim(),
        )
      ) {
        throw new Error("Artifact refused");
      }
      const bytes = Uint8Array.from(atob(result.content_base64), (char) => char.charCodeAt(0));
      const hash = [...new Uint8Array(await crypto.subtle.digest("SHA-256", bytes))]
        .map((byte) => byte.toString(16).padStart(2, "0"))
        .join("");
      if (
        hash !== artifact.sha256 ||
        bytes.length !== result.bytes ||
        (artifact.bytes !== null && bytes.length !== artifact.bytes)
      ) {
        throw new Error("Artifact integrity failed");
      }
      if (generation === this.generation && this.canRead()) {
        this.verifiedArtifact = {
          url: URL.createObjectURL(new Blob([bytes], { type: result.mime_type })),
          label: `${label} ${artifact.display_name ? `${artifact.display_name} · ` : ""}${artifact.sha256.slice(0, 12)}`,
        };
      }
    } catch {
      if (generation === this.generation) {
        this.error = "Artifact could not be verified or is unavailable. No file was opened.";
      }
    } finally {
      if (generation === this.generation) {
        this.busy = false;
      }
    }
  }
  private currentReviewBinding(): ArtifactReviewBinding | null {
    return this.detail
      ? {
          operation_id: this.detail.operation_id,
          event_id: this.detail.event_id,
          artifact_sha256: this.detail.artifacts.map((a) => a.sha256).toSorted(),
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
      !this.canRead() ||
      !this.detail ||
      !this.canRequestArtifactReview() ||
      this.reviewBusy
    ) {
      return;
    }
    const generation = this.generation;
    const binding = {
      operation_id: this.detail.operation_id,
      event_id: this.detail.event_id,
      artifact_sha256: this.detail.artifacts.map((a) => a.sha256).toSorted(),
    };
    const identity = JSON.stringify(binding);
    if (this.reviewRequestIdentity?.binding !== identity) {
      this.reviewRequestIdentity = {
        binding: identity,
        key: `artifact-review:${crypto.randomUUID()}`,
      };
    }
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
      ) {
        return;
      }
      if (!this.reviewAvailable) {
        throw new Error("Review list unavailable");
      }
      if (opened) {
        const pending = this.pendingArtifactReviews.find(
          (entry) =>
            entry.expiresAtMs > Date.now() &&
            entry.artifactReview &&
            sameArtifactReviewBinding(entry.artifactReview.binding, binding),
        );
        if (!pending) {
          throw new Error("Pending review changed");
        }
        window.dispatchEvent(
          new CustomEvent(SHELL_APPROVALS_OPEN_EVENT, {
            detail: { approvalId: pending.id },
          }),
        );
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
      ) {
        return;
      }
      this.reviewMessage =
        "Review request recorded. This action does not submit an artifact decision.";
      await this.context.overlays.refreshApprovals?.();
    } catch {
      if (generation === this.generation && this.detail?.event_id === binding.event_id) {
        this.reviewMessage =
          "Artifact review unavailable or evidence changed. Refresh evidence and try again.";
      }
    } finally {
      this.reviewBusy = false;
    }
  }

  override render() {
    return renderOperationalEvidence(
      {
        page: this.page,
        readAllowed: hasOperatorReadAccess(this.context.gateway.snapshot.hello?.auth ?? null),
        connected: this.canRead(),
        busy: this.busy,
        error: this.error,
        listUnavailable: this.listUnavailable,
        draftFilters: this.draftFilters,
        lastCheckedAt: this.lastCheckedAt,
        filter: this.filter,
        selectedOperation: this.selectedOperation,
        selectedEvent: this.selectedEvent,
      },
      {
        applyFilters: (event) => this.applyFilters(event),
        updateDraftFilter: (key, value) => {
          this.draftFilters = { ...this.draftFilters, [key]: value };
        },
        refresh: () => {
          void this.refresh();
        },
        setFilter: (value) => {
          this.filter = value;
        },
        openDetail: (operation) => {
          void this.openDetail(operation);
        },
        loadMore: () => {
          void this.load(true);
        },
      },
      this.detail
        ? renderOperationalDetail(
            {
              detail: this.detail,
              connectionReady: this.connectionReady,
              busy: this.busy,
              verifiedArtifact: this.verifiedArtifact,
              canRequestReview: this.canRequestArtifactReview(),
              hasPendingReview: this.hasPendingArtifactReview(),
              reviewBusy: this.reviewBusy,
              reviewMessage: this.reviewMessage,
            },
            {
              observationLink: (operationId, eventId) => this.observationLink(operationId, eventId),
              openArtifact: (operation, artifact, label) => {
                void this.openArtifact(operation, artifact, label);
              },
              requestReview: () => {
                void this.requestArtifactReview();
              },
            },
          )
        : nothing,
    );
  }
}
if (!customElements.get("argus-operational-view")) {
  customElements.define("argus-operational-view", OperationalView);
}
