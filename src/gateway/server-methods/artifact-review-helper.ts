import { spawn } from "node:child_process";
import { isAbsolute } from "node:path";
import type { GatewayConfig } from "../../config/types.gateway.js";
import { isArtifactReviewActorAuthorized } from "./artifact-review-policy.js";
import {
  parseArtifactReviewBinding,
  type ArtifactReviewAdapter,
  type ArtifactReviewActor,
  type ArtifactReviewPending,
} from "./artifact-review.js";

const unavailable = () => new Error("Artifact review unavailable or invalid");
const MAX_BYTES = 65536;
/** Trusted configuration only; request content is bounded JSON stdin, never argv or shell text. */
export function createArtifactReviewHelperAdapter(
  config: GatewayConfig["artifactReview"],
): ArtifactReviewAdapter | undefined {
  if (!config) return undefined;
  if (
    !isAbsolute(config.command) ||
    config.command.includes("\0") ||
    (config.args?.length ?? 0) > 32 ||
    config.args?.some((arg) => arg.length > 4096 || arg.includes("\0")) ||
    (config.timeoutMs !== undefined &&
      (!Number.isInteger(config.timeoutMs) || config.timeoutMs < 100 || config.timeoutMs > 15000))
  )
    throw unavailable();
  const command = config.command;
  const args = [...(config.args ?? [])];
  const timeoutMs = config.timeoutMs ?? 5000;
  async function call(
    method: string,
    actor: ArtifactReviewActor,
    request?: unknown,
  ): Promise<unknown> {
    const input = JSON.stringify({
      method,
      actor,
      ...(request === undefined ? {} : { command: request }),
    });
    if (Buffer.byteLength(input) > MAX_BYTES) throw unavailable();
    return new Promise((resolve, reject) => {
      const child = spawn(command, args, {
        shell: false,
        windowsHide: true,
        stdio: ["pipe", "pipe", "ignore"],
      });
      let bytes = 0;
      const chunks: Buffer[] = [];
      let settled = false;
      let forceKillTimer: ReturnType<typeof setTimeout> | undefined;
      const finish = (value?: unknown, failed = false) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        if (failed) {
          child.kill();
          forceKillTimer = setTimeout(() => child.kill("SIGKILL"), 250);
          forceKillTimer.unref();
          reject(unavailable());
        } else resolve(value);
      };
      const timer = setTimeout(() => finish(undefined, true), timeoutMs);
      child.on("error", () => finish(undefined, true));
      child.stdin.on("error", () => finish(undefined, true));
      child.stdout.on("data", (chunk: Buffer) => {
        bytes += chunk.length;
        if (bytes > MAX_BYTES) {
          finish(undefined, true);
          return;
        }
        chunks.push(chunk);
      });
      child.on("close", (code) => {
        clearTimeout(forceKillTimer);
        if (code !== 0) {
          finish(undefined, true);
          return;
        }
        try {
          finish(
            JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(Buffer.concat(chunks))),
          );
        } catch {
          finish(undefined, true);
        }
      });
      child.stdin.end(input);
    });
  }
  return {
    request: async (request, actor) =>
      (await call("request", actor, request)) as Awaited<
        ReturnType<ArtifactReviewAdapter["request"]>
      >,
    resolve: async (request, actor) =>
      (await call("resolve", actor, request)) as Awaited<
        ReturnType<ArtifactReviewAdapter["resolve"]>
      >,
    list: async (actor) => {
      const result = await call("list", actor);
      if (
        !result ||
        typeof result !== "object" ||
        !("items" in result) ||
        !Array.isArray(result.items) ||
        result.items.length > 100
      )
        throw unavailable();
      return result.items
        .map((raw: unknown): ArtifactReviewPending => {
          if (!raw || typeof raw !== "object") throw unavailable();
          const row = raw as Record<string, unknown>;
          if (
            typeof row.id !== "string" ||
            !/^[A-Za-z0-9_.:-]{1,512}$/.test(row.id) ||
            typeof row.requested_by_device_id !== "string" ||
            !row.requested_by_device_id ||
            !Array.isArray(row.reviewer_device_ids) ||
            row.reviewer_device_ids.length > 64 ||
            !row.reviewer_device_ids.every((id) => typeof id === "string" && id.length <= 512) ||
            !Number.isSafeInteger(row.created_at_ms) ||
            !Number.isSafeInteger(row.expires_at_ms) ||
            (row.created_at_ms as number) <= 0 ||
            (row.expires_at_ms as number) <= (row.created_at_ms as number)
          )
            throw unavailable();
          return {
            id: row.id,
            binding: parseArtifactReviewBinding(row.binding),
            created_at_ms: row.created_at_ms as number,
            expires_at_ms: row.expires_at_ms as number,
            requested_by_device_id: row.requested_by_device_id,
            reviewer_device_ids: row.reviewer_device_ids as string[],
          };
        })
        .filter(
          (row) => row.expires_at_ms > Date.now() && isArtifactReviewActorAuthorized(actor, row),
        );
    },
  };
}
