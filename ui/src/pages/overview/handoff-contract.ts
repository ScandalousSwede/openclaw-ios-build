import { z } from "zod";

const identity = z.string().min(1).max(256);
const sequence = z.number().int().positive().max(Number.MAX_SAFE_INTEGER);
const timestamp = z.string().datetime({ offset: true });
const handoffSchema = z.object({
  handoff_id: identity,
  summary: z.string().min(1).max(500),
  binding: z.object({
    thread_id: identity,
    workspace: z.string().min(1).max(1024),
    agent_id: identity,
  }),
  content_sha256: z.string().regex(/^[a-f0-9]{64}$/),
  state: z.enum(["queued", "delivered", "acknowledged"]),
  operation_id: z.string().min(1).max(300),
  request_event_id: identity,
  canonical_event_id: identity,
  queued_at: timestamp,
  updated_at: timestamp,
  submission_sequence: sequence,
  owner_accepted: z.literal(false),
});
const pageSchema = z.object({
  items: z.array(handoffSchema).max(25),
  has_more: z.boolean(),
  next_before_sequence: sequence.nullable(),
  order: z.literal("newest_submitted_first"),
  automatic_wake_enabled: z.literal(false),
});
export type HandoffReceipt = z.infer<typeof handoffSchema>;
export type HandoffPage = z.infer<typeof pageSchema>;
export function parseHandoffPage(value: unknown, before?: number): HandoffPage {
  const page = pageSchema.parse(value);
  if (page.has_more !== (page.next_before_sequence !== null))
    throw new Error("Invalid handoff coverage");
  const ids = new Set<string>();
  let previous = before ?? Infinity;
  for (const item of page.items) {
    if (item.operation_id !== `harness-handoff:${item.handoff_id}`)
      throw new Error("Invalid handoff operation binding");
    if (ids.has(item.handoff_id) || item.submission_sequence >= previous)
      throw new Error("Invalid handoff order");
    ids.add(item.handoff_id);
    previous = item.submission_sequence;
  }
  if (page.has_more && (!page.items.length || page.next_before_sequence !== previous))
    throw new Error("Invalid handoff continuation");
  return page;
}
