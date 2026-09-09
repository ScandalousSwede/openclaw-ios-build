import { html, nothing, type TemplateResult } from "lit";
import { t } from "../../i18n/index.ts";
import type { Operation, Page } from "./operational-contract.ts";
import { operationTime } from "./operational-detail.ts";
import { operationHeading } from "./operational-heading.ts";
import { operationalStyles } from "./operational-styles.ts";

export type EvidenceFilters = Record<"project" | "task" | "source" | "from" | "before", string>;
type EvidencePresentation = {
  page: Page | null;
  readAllowed: boolean;
  connected: boolean;
  busy: boolean;
  error: string | null;
  listUnavailable: boolean;
  draftFilters: EvidenceFilters;
  lastCheckedAt: string | null;
  filter: string;
  selectedOperation: string | null;
  selectedEvent: string | null;
};
type EvidenceActions = {
  applyFilters: (event: Event) => void;
  updateDraftFilter: (key: keyof EvidenceFilters, value: string) => void;
  refresh: () => void;
  setFilter: (value: string) => void;
  openDetail: (operation: Operation) => void;
  loadMore: () => void;
};

export function renderOperationalEvidence(
  view: EvidencePresentation,
  actions: EvidenceActions,
  detailContent: TemplateResult | typeof nothing,
) {
  const { connected } = view;
  const { _authority_read: authorityRead } = view.page ?? {};
  const items =
    view.page?.items.filter((item) =>
      `${item.title} ${item.task_id} ${item.source}`
        .toLocaleLowerCase()
        .includes(view.filter.toLocaleLowerCase()),
    ) ?? [];
  return html`${operationalStyles}
    <section class="argus-evidence" aria-labelledby="argus-evidence-heading" aria-busy=${view.busy}>
      <p>ARGUS · Technical evidence</p>
      <h2 id="argus-evidence-heading">Here's what matters now.</h2>
      <p>Recorded technical work and its artifacts. Coverage is limited to admitted evidence.</p>
      <p role="status">
        ${
          !view.readAllowed
            ? "Read permission required — request access to operational evidence."
            : !connected
              ? "Disconnected — reconnect to verify current work."
              : view.busy
                ? "Loading operational evidence…"
                : view.error || view.listUnavailable
                  ? "Evidence unavailable; verify freshness before acting on loaded records."
                  : view.page
                    ? `${t(view.page.items.length === 1 ? "argusEvidence.loadedRecord" : "argusEvidence.loadedRecords", { count: String(view.page.items.length) })} ${t(view.page.coverage.complete ? "argusEvidence.allRecordsLoaded" : "argusEvidence.partialRecords")}`
                    : "Coverage unavailable."
        }
      </p>
      ${
        view.page
          ? html`<details>
              <summary>Evidence scope and freshness</summary>
              <p>
                Observed ${operationTime(view.page.coverage.observed_at)} · Technical evidence ·
                ${view.page.coverage.scope.project}${
                  view.page.coverage.scope.task_id
                    ? ` · Task ${view.page.coverage.scope.task_id}`
                    : ""
                }${
                  view.page.coverage.scope.source
                    ? ` · Source ${view.page.coverage.scope.source}`
                    : ""
                }
                ${
                  view.page.coverage.scope.recorded_from
                    ? ` · From ${view.page.coverage.scope.recorded_from} (inclusive)`
                    : ""
                }
                ${
                  view.page.coverage.scope.recorded_before
                    ? ` · Before ${view.page.coverage.scope.recorded_before} (exclusive)`
                    : ""
                }
              </p>
              <p>
                Snapshot evidence, not a live activity feed. Refreshes on reconnect and when
                returning after a minute.
              </p>
              <p>Corpus: ${view.page.coverage.scope.corpus}</p>
            </details>`
          : nothing
      }
      ${view.error ? html`<p role="alert">${view.error}</p>` : nothing}
      <details>
        <summary>Filter evidence by project, task, source or time</summary>
        <form @submit=${(event: Event) => actions.applyFilters(event)}>
          <fieldset ?disabled=${view.busy}>
            <legend>Find evidence on the server</legend>
            <div class="argus-scope-fields">
              <label
                >Project<select
                  @change=${(event: Event) => {
                    const target = event.currentTarget;
                    if (!(target instanceof HTMLSelectElement)) {
                      return;
                    }
                    actions.updateDraftFilter("project", target.value);
                  }}
                >
                  ${["Argus", "MiKobots", "EPC"].map(
                    (project) =>
                      html`<option
                        value=${project}
                        .selected=${project === view.draftFilters.project}
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
                      .value=${view.draftFilters[key]}
                      placeholder=${
                        key === "from" || key === "before" ? "2026-09-06T18:00:00Z" : "Any"
                      }
                      @input=${(event: Event) => {
                        const target = event.currentTarget;
                        if (!(target instanceof HTMLInputElement)) {
                          return;
                        }
                        actions.updateDraftFilter(key, target.value);
                      }}
                  /></label>
                `,
              )}
            </div>
            <button class="btn" type="submit" ?disabled=${!connected || view.busy}>
              Apply evidence filters
            </button>
          </fieldset>
        </form>
      </details>
      ${
        view.lastCheckedAt
          ? html`<p>
              Evidence last checked ${operationTime(view.lastCheckedAt)}.
              ${
                authorityRead?.snapshot_age_seconds !== undefined
                  ? html`Snapshot age at that check:
                    ${Math.max(0, Math.round(authorityRead.snapshot_age_seconds))} seconds.`
                  : html`Snapshot age is unavailable.`
              }
              This visible view checks every 60 seconds; the evidence projection normally updates
              every 5 minutes.
            </p>`
          : nothing
      }
      <div class="argus-toolbar">
        <button class="btn" ?disabled=${!connected || view.busy} @click=${() => actions.refresh()}>
          Refresh evidence
        </button>
        <label
          >Find in loaded work<input
            type="search"
            .value=${view.filter}
            @input=${(event: Event) => {
              const target = event.currentTarget;
              if (target instanceof HTMLInputElement) {
                actions.setFilter(target.value);
              }
            }}
        /></label>
      </div>
      <ul class="argus-work-list" aria-label="Work observations">
        ${items.map(
          (item) => html`<li>
            <button
              class="argus-work-row"
              aria-current=${
                view.selectedOperation === item.operation_id &&
                (!view.selectedEvent || view.selectedEvent === item.event_id)
                  ? "true"
                  : "false"
              }
              ?disabled=${!connected || view.busy}
              @click=${() => actions.openDetail(item)}
            >
              <span class="argus-work-title" title=${item.display?.label ?? item.title}
                >${operationHeading(item)}</span
              >
              <span class="argus-work-action">
                ${
                  view.selectedOperation === item.operation_id &&
                  (!view.selectedEvent || view.selectedEvent === item.event_id)
                    ? "Selected"
                    : "Open work details"
                }
              </span>
              <span class="argus-work-context">
                <span title=${item.state}>Recorded state: ${item.state.replaceAll("_", " ")}</span>
                ·
                ${t(
                  item.artifacts.length === 1
                    ? "argusEvidence.artifactReference"
                    : "argusEvidence.artifactReferences",
                  { count: String(item.artifacts.length) },
                )}
                ${
                  item.artifact_context?.relation === "previous_attempt"
                    ? " · Previous-attempt evidence"
                    : item.artifact_context?.relation === "current_attempt"
                      ? " · Current-attempt evidence"
                      : ""
                }
              </span>
              <span class="argus-work-context">Observed ${operationTime(item.observed_at)}</span>
            </button>
          </li>`,
        )}
      </ul>
      ${
        view.page && !items.length
          ? html`<p>
              ${
                view.filter
                  ? "No loaded work matches this search."
                  : "No technical work returned within this scope."
              }
            </p>`
          : nothing
      }
      ${
        view.page?.next_cursor
          ? html`<button
              class="btn"
              ?disabled=${!connected || view.busy}
              @click=${() => actions.loadMore()}
            >
              Load more evidence
            </button>`
          : nothing
      }
      ${detailContent}
    </section>`;
}
