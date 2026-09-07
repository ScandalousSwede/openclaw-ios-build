/** Typed, opt-in arm of plugin.approval; no execution-decision conversion or local store. */
export type ArtifactReviewBinding = Readonly<{
  operation_id: string;
  event_id: string;
  artifact_sha256: readonly string[];
}>;
export type ArtifactReviewActor = Readonly<{
  device_id: string;
  connection_id: string;
  scopes: readonly string[];
}>;
export type ArtifactReviewDecision = "accept_artifact" | "reject_artifact";
export type ArtifactReviewCommand = Readonly<{
  binding: ArtifactReviewBinding;
  idempotency_key: string;
}>;
export type ArtifactReviewResolution = ArtifactReviewCommand &
  Readonly<{
    id: string;
    decision: ArtifactReviewDecision;
  }>;
export type ArtifactReviewReceipt = Readonly<{
  id: string;
  binding: ArtifactReviewBinding;
  actor_device_id: string;
  canonical_event_id: string;
  idempotency_key: string;
  state: "pending" | "accepted" | "rejected";
}>;
/**
 * Installed by trusted server composition only. Both calls MUST authorize the authenticated
 * device against the real owner policy and bind/recheck the exact current event and artifact
 * set inside the canonical transaction. Resolve must atomically reject stale/conflicting
 * decisions, enforce expiry and durable idempotency, and commit before returning a receipt.
 * A gateway scope or requester identity alone is not an owner mapping. No default adapter.
 */
export type ArtifactReviewAdapter = {
  request(
    command: ArtifactReviewCommand,
    actor: ArtifactReviewActor,
  ): Promise<ArtifactReviewReceipt>;
  resolve(
    command: ArtifactReviewResolution,
    actor: ArtifactReviewActor,
  ): Promise<ArtifactReviewReceipt>;
};
type Client = {
  connId?: string;
  connect?: { role?: string; device?: { id?: string }; scopes?: string[] };
} | null;
const fail = (): never => {
  throw new Error("Artifact review unavailable or invalid");
};
const record = (value: unknown): Record<string, unknown> => {
  if (!value || typeof value !== "object" || Array.isArray(value)) return fail();
  return value as Record<string, unknown>;
};
const exact = (value: Record<string, unknown>, keys: string[]) => {
  if (Object.keys(value).some((key) => !keys.includes(key)) || keys.some((key) => !(key in value)))
    fail();
};
const id = (value: unknown): string => {
  if (typeof value !== "string" || !/^[A-Za-z0-9_.:-]{1,512}$/.test(value)) return fail();
  return value;
};
function binding(value: unknown): ArtifactReviewBinding {
  const item = record(value);
  exact(item, ["operation_id", "event_id", "artifact_sha256"]);
  if (
    !Array.isArray(item.artifact_sha256) ||
    item.artifact_sha256.length < 1 ||
    item.artifact_sha256.length > 64
  )
    return fail();
  const hashes = item.artifact_sha256.map((hash) => {
    if (typeof hash !== "string" || !/^[a-f0-9]{64}$/.test(hash)) return fail();
    return hash;
  });
  if (new Set(hashes).size !== hashes.length) return fail();
  return Object.freeze({
    operation_id: id(item.operation_id),
    event_id: id(item.event_id),
    artifact_sha256: Object.freeze(hashes.sort()),
  });
}
function actor(client: Client): ArtifactReviewActor {
  if (client?.connect?.role !== "operator") return fail();
  const scopes = client.connect.scopes;
  if (
    !Array.isArray(scopes) ||
    !scopes.every((scope) => typeof scope === "string") ||
    !scopes.some((scope) => scope === "operator.approvals" || scope === "operator.admin")
  )
    return fail();
  return Object.freeze({
    device_id: id(client.connect.device?.id),
    connection_id: id(client.connId),
    scopes: Object.freeze([...new Set(scopes)].sort()),
  });
}
function sameBinding(a: ArtifactReviewBinding, b: ArtifactReviewBinding): boolean {
  return (
    a.operation_id === b.operation_id &&
    a.event_id === b.event_id &&
    a.artifact_sha256.length === b.artifact_sha256.length &&
    a.artifact_sha256.every((hash, i) => hash === b.artifact_sha256[i])
  );
}
/** Undefined means the incumbent execution-approval arm should handle this request. */
export async function routeArtifactReview(params: {
  method: "request" | "resolve";
  input: unknown;
  client: Client;
  adapter?: ArtifactReviewAdapter;
}): Promise<ArtifactReviewReceipt | undefined> {
  const input = params.input;
  if (!input || typeof input !== "object" || Array.isArray(input) || !("kind" in input))
    return undefined;
  try {
    const item = record(input);
    if (item.kind !== "artifact_review" || !params.adapter) return fail();
    exact(
      item,
      params.method === "request"
        ? ["kind", "binding", "idempotency_key", "title", "description"]
        : ["kind", "binding", "idempotency_key", "id", "decision"],
    );
    // Existing title/description envelope is display-only, never an actor or authority input.
    if (
      params.method === "request" &&
      (typeof item.title !== "string" ||
        item.title.length < 1 ||
        item.title.length > 80 ||
        typeof item.description !== "string" ||
        item.description.length < 1 ||
        item.description.length > 512)
    )
      return fail();
    const trustedActor = actor(params.client);
    const base = { binding: binding(item.binding), idempotency_key: id(item.idempotency_key) };
    let command: ArtifactReviewCommand | ArtifactReviewResolution;
    let returned: ArtifactReviewReceipt;
    if (params.method === "request") {
      command = Object.freeze(base);
      returned = await params.adapter.request(command, trustedActor);
    } else {
      if (item.decision !== "accept_artifact" && item.decision !== "reject_artifact") return fail();
      command = Object.freeze({ ...base, id: id(item.id), decision: item.decision });
      returned = await params.adapter.resolve(command as ArtifactReviewResolution, trustedActor);
    }
    const receipt = record(returned);
    exact(receipt, [
      "id",
      "binding",
      "actor_device_id",
      "canonical_event_id",
      "idempotency_key",
      "state",
    ]);
    const receiptBinding = binding(receipt.binding);
    const expectedState = !("decision" in command)
      ? "pending"
      : command.decision === "accept_artifact"
        ? "accepted"
        : "rejected";
    if (
      receipt.state !== expectedState ||
      receipt.actor_device_id !== trustedActor.device_id ||
      receipt.idempotency_key !== command.idempotency_key ||
      !sameBinding(receiptBinding, command.binding) ||
      ("id" in command && receipt.id !== command.id)
    )
      return fail();
    return Object.freeze({
      id: id(receipt.id),
      binding: receiptBinding,
      actor_device_id: trustedActor.device_id,
      canonical_event_id: id(receipt.canonical_event_id),
      idempotency_key: command.idempotency_key,
      state: expectedState,
    });
  } catch {
    // Neither provider/writer exception text nor caller metadata may become a public error.
    return fail();
  }
}
