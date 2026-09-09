import { AsyncLocalStorage } from "node:async_hooks";
import { normalizeAgentId } from "@openclaw/normalization-core/agent-id";
import { normalizeOptionalString } from "@openclaw/normalization-core/string-coerce";
import {
  captureGatewayRootWorkAdmissionContinuationScope,
  retainGatewayRootWorkAdmissionContinuation,
  type GatewayRootWorkAdmissionContinuationScope,
} from "../process/gateway-work-admission.js";
import { resolveGlobalSingleton } from "../shared/global-singleton.js";

const SYSTEM_EVENT_OWNERSHIP_KEY = Symbol.for("openclaw.systemEvents.ownership");

// The queue is process-global, so duplicated runtime chunks must share its
// object-identity metadata or another agent can consume an owner-marked event.
const owners = resolveGlobalSingleton(
  SYSTEM_EVENT_OWNERSHIP_KEY,
  () => new WeakMap<object, string>(),
);
// Keep the established string-valued ownership slot compatible with older
// native/transformed modules. Admission custody is private occurrence metadata.
type EventAdmission = {
  scope: GatewayRootWorkAdmissionContinuationScope;
  waiter?: { readonly active: boolean };
};
type EventSelection = {
  closed: boolean;
  releases: Array<() => void>;
  waiters: ReadonlySet<object>;
};
const admissions = resolveGlobalSingleton(
  Symbol.for("openclaw.systemEvents.admission"),
  () => new WeakMap<object, EventAdmission>(),
);

function normalizeOwnerAgentId(agentId: string | null | undefined): string | null {
  return normalizeOptionalString(agentId) ? normalizeAgentId(agentId) : null;
}

export function withSystemEventOwner<T extends object>(options: T, agentId: string): T {
  recordSystemEventOwner(options, agentId);
  return options;
}

export function recordSystemEventOwner(event: object, agentId: string | null): void {
  const normalized = normalizeOwnerAgentId(agentId);
  if (normalized) {
    owners.set(event, normalized);
  }
}

export function cloneSystemEventOwner(source: object, clone: object): void {
  const ownership = owners.get(source);
  if (ownership) {
    owners.set(clone, ownership);
  }
  const admission = admissions.get(source);
  if (admission) {
    admissions.set(clone, admission);
  }
}

export function resolveSystemEventOwnerAgentId(event: object): string | null {
  return owners.get(event) ?? null;
}

export function selectAgentSystemEvents<T extends object>(
  events: readonly T[],
  agentId: string,
): T[] {
  const normalizedAgentId = normalizeAgentId(agentId);
  // Unowned events retain their legacy first-consumer semantics. Owner-marked
  // events stay invisible to other agents sharing the transient global queue.
  return events.filter((event) => {
    const ownerAgentId = resolveSystemEventOwnerAgentId(event);
    return ownerAgentId === null || ownerAgentId === normalizedAgentId;
  });
}

// This selection exists only while an already-admitted wake drains through a
// suspension fence. Its event roots stay live until the whole handler settles.
const admittedSelections = resolveGlobalSingleton(
  Symbol.for("openclaw.systemEvents.admittedSelection"),
  () => new AsyncLocalStorage<{ receipt?: EventAdmission; selection?: EventSelection }>(),
);

/** Records custody at the actual occurrence, not from caller-controlled options. */
export function recordSystemEventAdmission(event: object): void {
  const admission = captureGatewayRootWorkAdmissionContinuationScope();
  if (admission) {
    admissions.set(event, { scope: admission });
  }
}

/** Carries only an actual enqueue receipt across the existing wake adapter. */
export function runWithSystemEventWakeReceipt<T>(
  receipt: object | null | undefined,
  run: () => T,
): T {
  return admittedSelections.run(
    {
      ...admittedSelections.getStore(),
      receipt: receipt ? admissions.get(receipt) : undefined,
    },
    run,
  );
}

/** One queued occurrence keeps its first waiter owner across retries. */
export function bindSystemEventWakeAdmission(waiter: { readonly active: boolean }): void {
  const receipt = admittedSelections.getStore()?.receipt;
  if (receipt && !receipt.waiter) {
    receipt.waiter = waiter;
  }
}

/** Exact waiters select a draining turn; undefined starts a fresh independent context. */
export async function runWithAdmittedSystemEventSelection<T>(
  waiters: readonly object[] | undefined,
  run: () => Promise<T>,
): Promise<T> {
  if (waiters === undefined) {
    // A fresh independent admission cannot inherit a timer creator's receipt
    // or finished borrowed selection, including when it emits follow-up work.
    return admittedSelections.exit(run);
  }
  const selection: EventSelection = {
    closed: false,
    releases: [],
    waiters: new Set(waiters),
  };
  try {
    return await admittedSelections.run({ ...admittedSelections.getStore(), selection }, run);
  } finally {
    selection.closed = true;
    for (const release of selection.releases) {
      release();
    }
  }
}

export async function selectAdmittedSystemEvents<T extends object>(
  events: readonly T[],
): Promise<T[]> {
  const selection = admittedSelections.getStore()?.selection;
  if (!selection) {
    return [...events];
  }
  const selected: T[] = [];
  for (const event of events) {
    // Handler replacement can end the selection while its preflight is pending.
    if (selection.closed) {
      break;
    }
    const admission = admissions.get(event);
    // A live parent alone does not bind an occurrence to this contribution.
    // Unbound, detached, or other-waiter events await independent admission.
    if (!admission?.waiter?.active || !selection.waiters.has(admission.waiter)) {
      continue;
    }
    try {
      await admission.scope.run(async () => {
        if (selection.closed) {
          return;
        }
        const release = retainGatewayRootWorkAdmissionContinuation();
        if (release) {
          selection.releases.push(release);
          selected.push(event);
        }
      });
    } catch {
      // A retired/reset origin cannot lend authority to a different active wake.
      // Its occurrence stays queued for normal independent admission after resume.
    }
  }
  return selected;
}
