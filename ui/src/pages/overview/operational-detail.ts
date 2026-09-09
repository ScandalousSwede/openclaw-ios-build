import { html, nothing } from "lit";
import type { Artifact, Operation, WorkContract, ReviewHistory } from "./operational-contract.ts";
import { operationHeading } from "./operational-heading.ts";

export type Detail = Operation & {
  workContract: WorkContract | null;
  reviewHistory: ReviewHistory | null;
  timeline: Operation[];
  newerObservation: boolean;
  historyComplete: boolean;
  requestedOperation: Operation;
};

export type DetailPresentation = {
  detail: Detail;
  connectionReady: boolean;
  busy: boolean;
  verifiedArtifact: { url: string; label: string } | null;
  canRequestReview: boolean;
  hasPendingReview: boolean;
  reviewBusy: boolean;
  reviewMessage: string | null;
};
export type DetailActions = {
  observationLink: (operationId: string, eventId?: string) => string;
  openArtifact: (operation: Operation, artifact: Artifact, label: string) => void;
  requestReview: () => void;
};
type ArtifactControls = {
  disabled: boolean;
  openArtifact: DetailActions["openArtifact"];
};

export function operationTime(value: string): string {
  const date = new Date(value);
  return Number.isNaN(date.valueOf())
    ? "Observation time unavailable"
    : date.toLocaleString(undefined, { timeZoneName: "short" });
}

function renderArtifacts(operation: Operation, controls: ArtifactControls, earlier = false) {
  const label = earlier
    ? "earlier-observation artifact"
    : operation.artifact_context?.relation === "previous_attempt"
      ? "previous-attempt artifact"
      : "artifact";
  return operation.artifacts.map(
    (artifact) => html`<p>
      <button
        class="btn"
        ?disabled=${controls.disabled}
        @click=${() => controls.openArtifact(operation, artifact, label)}
      >
        ${`Verify ${label} ${artifact.display_name ? `${artifact.display_name} · ` : ""}${artifact.sha256.slice(0, 12)} (${artifact.bytes === null ? "size checked on open" : `${artifact.bytes} bytes`})`}
      </button>
    </p>`,
  );
}
function renderEarlierArtifacts(
  detail: Detail,
  controls: ArtifactControls,
  observationLink: DetailActions["observationLink"],
) {
  // A requested observation can fall outside the bounded timeline.
  const observations = new Map(detail.timeline.map((operation) => [operation.event_id, operation]));
  observations.set(detail.requestedOperation.event_id, detail.requestedOperation);
  const earlier = [...observations.values()].filter(
    (operation) =>
      operation.event_id !== detail.event_id &&
      operation.artifacts.length > 0 &&
      (operation.operation_id !== detail.operation_id ||
        operation.kind === "codex.completion.artifact_produced" ||
        operation.event_id === detail.requestedOperation.event_id),
  );
  if (!earlier.length) {
    return nothing;
  }
  return html`<details class="argus-earlier-artifacts">
    <summary>
      Earlier artifacts (${earlier.length} ${earlier.length === 1 ? "observation" : "observations"})
    </summary>
    <p>
      These artifacts belong to earlier observations. They do not establish a result for the current
      work.
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
        <a href=${observationLink(operation.operation_id, operation.event_id)}
          >Link to this earlier observation</a
        >
        ${renderArtifacts(operation, controls, true)}
      </section>`,
    )}
  </details>`;
}
function renderWorkContract(detail: Detail, observationLink: DetailActions["observationLink"]) {
  const contract = detail.workContract;
  if (!contract) {
    return html`<p>Owner acceptance ${detail.owner_accepted ? "recorded" : "not recorded"}.</p>
      <p>
        Evidence basis is unavailable from this gateway. Verification and owner disposition are not
        inferred.
      </p>`;
  }
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
        ${
          contract.native_observations.length
            ? html`<ul>
                ${contract.native_observations.map(
                  (observation) =>
                    html`<li>
                      ${observation.adapter ?? "Unknown producer"}:
                      ${observation.outcome ?? "outcome not recorded"} · producer observation
                    </li>`,
                )}
              </ul>`
            : "No native outcome included in this scope"
        }
      </dd>
      <dt>Structural verification</dt>
      <dd>
        ${structural ?? "Status unavailable"}. Semantic correctness is not established by this
        check.
      </dd>
      <dt>Independent verification</dt>
      <dd>
        ${
          independent.artifacts.length
            ? html`<p>
                  ${
                    independent.covers_all_current_artifacts
                      ? "PASS receipts cover all current artifacts."
                      : "Returned receipts do not establish a pass for all current artifacts."
                  }
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
            : "Not established in returned evidence"
        }
      </dd>
      <dt>Owner disposition</dt>
      <dd>Unknown in this reader. Owner acceptance not recorded.</dd>
    </dl>
    <p>
      ${contract.coverage.complete ? "Complete returned scope" : "Partial returned scope"} ·
      ${
        contract.coverage.scope === "canonical_federation_observation"
          ? "this federation observation"
          : "this canonical operation trace"
      }.
      Evidence outside this scope has not been ruled out.
    </p>
    <h3>Read-only continuation</h3>
    <p>
      <a href=${observationLink(contract.continuation.operation_id, contract.continuation.event_id)}
        >Inspect current evidence</a
      >. Use the verified artifact controls above. Continuing execution requires the owning
      workflow; this view does not dispatch work or record a state transition.
    </p>
  </section>`;
}
function renderReviewHistory(history: ReviewHistory | null) {
  const time = (value: number) => {
    const date = new Date(value);
    return Number.isNaN(date.valueOf())
      ? "Time unavailable"
      : date.toLocaleString(undefined, { timeZoneName: "short" });
  };
  return html`<section class="argus-review-history" aria-label="Recorded operator reviews">
    <details>
      <summary>Recorded operator reviews${history ? ` (${history.items.length})` : ""}</summary>
      ${
        !history
          ? html`<p>Operator review history was not supplied by this reader.</p>`
          : html`
              <p>
                Receipt-qualified operator records in the admitted review corpus at snapshot
                ${history.coverage.snapshot_sequence}.
                ${
                  history.coverage.complete && !history.coverage.has_more
                    ? "Complete within this returned scope."
                    : "Partial coverage; additional records may exist."
                }
              </p>
              <p>
                This history does not establish a currently actionable review, owner acceptance,
                scientific correctness or independent verification.
              </p>
              ${
                history.items.length === 0
                  ? html`<p>No qualified review records were returned in this scope.</p>`
                  : html`<ol>
                      ${history.items.map(
                        (review) => html`<li>
                          <p>
                            <strong
                              >${
                                review.state === "pending"
                                  ? "Review requested"
                                  : review.state === "accepted"
                                    ? "Operator accepted the bound artifact"
                                    : "Operator rejected the bound artifact"
                              }</strong
                            >
                            ·
                            ${
                              review.binding_relation === "current"
                                ? "Current artifact binding"
                                : "Earlier evidence binding"
                            }
                          </p>
                          ${
                            review.state === "pending"
                              ? html`<p>No qualified disposition recorded.</p>`
                              : html`<p>
                                  Authenticated operator disposition recorded
                                  ${time(review.disposition!.recorded_at_ms)}.
                                </p>`
                          }
                          <p>
                            Requested ${time(review.requested_at_ms)}. Request expiry
                            ${time(review.expires_at_ms)}${
                              review.expires_at_ms <= Date.now() ? " (passed)" : ""
                            }.
                          </p>
                          <p>
                            Review <code>${review.id}</code> · Request event
                            <code>${review.request_event_id}</code>${
                              review.disposition
                                ? html` · Disposition event
                                    <code>${review.disposition.event_id}</code>`
                                : nothing
                            }
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
                    </ol>`
              }
            `
      }
    </details>
  </section>`;
}

export function renderOperationalDetail(view: DetailPresentation, actions: DetailActions) {
  const { detail } = view;
  const artifactControls = {
    disabled: !view.connectionReady || view.busy,
    openArtifact: actions.openArtifact,
  };
  return html`<section class="argus-detail" aria-label="Work details">
    <h3 class="argus-selected-title" tabindex="-1">${operationHeading(detail)}</h3>
    <p>
      <span title=${detail.state}>Recorded state: ${detail.state.replaceAll("_", " ")}</span>
    </p>
    ${
      operationHeading(detail) !== (detail.display?.label ?? detail.title)
        ? html`<p class="argus-source-summary">${detail.title}</p>`
        : nothing
    }
    ${detail.display?.change_summary ? html`<p>${detail.display.change_summary}</p>` : nothing}
    ${
      detail.display?.artifact_label && detail.artifacts.length
        ? html`<p>Artifact: ${detail.display.artifact_label}</p>`
        : nothing
    }
    <p class="argus-disposition">
      ${
        detail.workContract?.independent_verification.covers_all_current_artifacts
          ? detail.workContract.independent_verification.semantic_correctness_established ===
              false &&
            detail.workContract.independent_verification.artifacts.length > 0 &&
            detail.workContract.independent_verification.artifacts.every(
              (entry) => entry.verification_kind === "structural_artifact_contract",
            )
            ? "Structural verification passed for the current artifacts. Semantic correctness is not established by this receipt."
            : "Independent PASS receipts cover the current artifacts."
          : detail.workContract?.independent_verification.artifacts.some(
                (entry) => entry.outcome === "FAIL",
              )
            ? "An independent check reported a failure. Inspect the evidence."
            : "Independent verification is not established for all current artifacts."
      }
    </p>
    ${
      detail.newerObservation
        ? html`<p>
            A newer observation is available for this task. Showing current evidence; the requested
            observation remains in provenance.
          </p>`
        : nothing
    }
    ${
      detail.workContract?.pending_owner_feedback.length
        ? html`<section class="argus-owner-request" aria-label="Requested owner feedback">
            <h4>Requested owner feedback</h4>
            <ul>
              ${detail.workContract.pending_owner_feedback.map(
                (feedback) =>
                  html`<li>
                    ${feedback.owner ?? "Owner unspecified"}:
                    ${feedback.reason ?? "Reason not included"}
                  </li>`,
              )}
            </ul>
          </section>`
        : nothing
    }
    ${
      detail.artifact_context?.relation === "previous_attempt"
        ? html`<p class="argus-artifact-attempt">
            No artifact from the current attempt is available. The evidence below belongs to a
            previous attempt.
          </p>`
        : nothing
    }
    <h3>
      ${
        detail.artifact_context?.relation === "previous_attempt"
          ? "Inspect previous-attempt evidence"
          : detail.artifact_context?.relation === "current_attempt" ||
              detail.artifact_context?.relation === "federation_observation"
            ? detail.artifacts.length
              ? "Inspect the result"
              : "Inspect recorded evidence"
            : "Inspect available evidence"
      }
    </h3>
    ${
      !detail.artifacts.length
        ? html`<p>
            No artifact references were returned for the current observation. Earlier artifacts,
            when available, are listed below.
          </p>`
        : nothing
    }
    ${renderArtifacts(detail, artifactControls)}
    ${renderEarlierArtifacts(detail, artifactControls, actions.observationLink)}
    ${
      view.verifiedArtifact
        ? html`<a class="btn" href=${view.verifiedArtifact.url} target="_blank" rel="noopener"
            >Open verified ${view.verifiedArtifact.label}</a
          >`
        : nothing
    }
    ${
      detail.display?.continuation_label
        ? html`<p>${detail.display.continuation_label}</p>`
        : nothing
    }
    ${
      view.canRequestReview
        ? html`<p>
            <button
              class="btn"
              ?disabled=${view.reviewBusy || view.busy}
              @click=${() => actions.requestReview()}
            >
              ${view.hasPendingReview ? "Open pending review" : "Request operator review"}
            </button>
          </p>`
        : nothing
    }
    ${view.reviewMessage ? html`<p role="status">${view.reviewMessage}</p>` : nothing}
    ${renderReviewHistory(detail.reviewHistory)}
    <details>
      <summary>Provenance, verification and history</summary>
      <p>Recorded state value: ${detail.state}</p>
      <h4>Producer narrative</h4>
      <p>${detail.title}</p>
      <p>${detail.kind} · ${detail.source}</p>
      <p>Task: ${detail.task_id}</p>
      ${
        detail.artifact_context
          ? html`<p>
              Artifact relation: ${detail.artifact_context.relation}.
              ${
                detail.artifact_context.relation === "federation_observation"
                  ? "Artifact links belong to this observation."
                  : html`Current attempt
                    ${detail.artifact_context.current_attempt_id ?? "not recorded"} · artifact
                    attempt ${detail.artifact_context.artifact_attempt_id ?? "not recorded"}`
              }
            </p>`
          : nothing
      }
      <p>Scope: ${detail.evidence_scope ?? "canonical_federation_observation"}</p>
      ${detail.executor_id ? html`<p>Executor: ${detail.executor_id}</p>` : nothing}
      ${detail.capability_id ? html`<p>Capability: ${detail.capability_id}</p>` : nothing}
      <p>
        Event ${operationTime(detail.occurred_at)} · observed ${operationTime(detail.observed_at)}
      </p>
      <p>
        Detail follows this task and producer, including newer observations outside the list's time
        window.
      </p>
      <p>
        Read-only evidence. Continuing work requires the owning workflow; opening this view does not
        dispatch work.
      </p>
      ${
        detail.newerObservation
          ? html`<p>
              This does not establish that the earlier observation was superseded. Requested:
              ${detail.requestedOperation.title}
              (${operationTime(detail.requestedOperation.observed_at)}).
            </p>`
          : nothing
      }
      <p>
        <a
          href=${actions.observationLink(
            detail.requestedOperation.operation_id,
            detail.requestedOperation.event_id,
          )}
          >Link to requested observation</a
        >${
          detail.newerObservation
            ? html` ·
                <a href=${actions.observationLink(detail.operation_id, detail.event_id)}
                  >Link to current observation</a
                >`
            : nothing
        }
      </p>
      ${renderWorkContract(detail, actions.observationLink)}
      <p>
        ${
          detail.historyComplete
            ? "Complete returned history within this task and producer."
            : "Partial history; additional evidence exists."
        }
      </p>
      <p>Operation: ${detail.operation_id}</p>
      <p>Event: ${detail.event_id}</p>
      <ol>
        ${detail.timeline.map(
          (event) =>
            html`<li>${event.state} · ${event.kind} · ${operationTime(event.occurred_at)}</li>`,
        )}
      </ol>
    </details>
  </section>`;
}
