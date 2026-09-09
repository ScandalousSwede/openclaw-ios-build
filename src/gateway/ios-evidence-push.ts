import { isDeepStrictEqual } from "node:util";
import { getRuntimeConfig } from "../config/io.js";
import { loadOrCreateProcessDeviceIdentity } from "../infra/device-identity.js";
import {
  getPairedDevice,
  hasEffectivePairedDeviceRole,
  type PairedDevice,
} from "../infra/device-pairing.js";
import {
  isApnsEvidenceAlertPayloadWithinLimit,
  loadApnsRegistration,
  resolveApnsAuthConfigFromEnv,
  resolveApnsRelayConfigFromEnv,
  sendApnsEvidenceAlert,
  type ApnsPushResult,
} from "../infra/push-apns.js";
import { roleScopesAllow } from "../shared/operator-scope-compat.js";

/** Exact canonical evidence identifiers; no notification content or routing overrides. */
export type IosEvidenceNotificationInput = {
  targetDeviceId: string;
  operationId: string;
  eventId: string;
  artifactSha256?: string;
};

/** An additional caller-owned deny check, never a substitute for device authorization. */
export type IosEvidenceNotificationOptions = {
  authorizeSend: () => Promise<boolean>;
};

/** Provider acceptance is distinct from device delivery, opening, or owner acknowledgment. */
export type IosEvidenceNotificationResult = {
  status:
    | "provider_accepted"
    | "provider_rejected"
    | "acceptance_unknown"
    | "not_sent_unavailable"
    | "not_sent_held";
  transport?: "direct" | "relay";
  providerId?: string;
  httpStatus?: number;
};

type Dependencies = {
  getPairedDevice: typeof getPairedDevice;
  loadApnsRegistration: typeof loadApnsRegistration;
  resolveDirectAuth: typeof resolveApnsAuthConfigFromEnv;
  resolveRelayConfig: typeof resolveApnsRelayConfigFromEnv;
  getRuntimeConfig: typeof getRuntimeConfig;
  getGatewayIdentity: typeof loadOrCreateProcessDeviceIdentity;
  sendAlert: typeof sendApnsEvidenceAlert;
};

const defaultDependencies: Dependencies = {
  getPairedDevice,
  loadApnsRegistration,
  resolveDirectAuth: resolveApnsAuthConfigFromEnv,
  resolveRelayConfig: resolveApnsRelayConfigFromEnv,
  getRuntimeConfig,
  getGatewayIdentity: loadOrCreateProcessDeviceIdentity,
  sendAlert: sendApnsEvidenceAlert,
};

function validIdentifier(value: unknown, maxLength: number): value is string {
  return (
    typeof value === "string" &&
    value.length > 0 &&
    Array.from(value).length <= maxLength &&
    value === value.trim() &&
    !/[\p{Cc}\p{Cf}\p{Cs}]/u.test(value) &&
    !/^\p{White_Space}|\p{White_Space}$/u.test(value)
  );
}

function canReadEvidence(
  device: PairedDevice | null,
  targetDeviceId: string,
): device is PairedDevice {
  const platform = device?.platform?.trim().toLowerCase() ?? "";
  const token = device?.tokens?.operator;
  return Boolean(
    device?.deviceId === targetDeviceId &&
    (platform.startsWith("ios") || platform.startsWith("ipados")) &&
    hasEffectivePairedDeviceRole(device, "operator") &&
    token &&
    !token.revokedAtMs &&
    roleScopesAllow({
      role: "operator",
      requestedScopes: ["operator.read"],
      allowedScopes: token.scopes,
    }),
  );
}

function providerResult(result: ApnsPushResult): IosEvidenceNotificationResult {
  const httpStatus =
    Number.isInteger(result.status) && result.status >= 100 && result.status <= 599
      ? result.status
      : undefined;
  const providerId =
    typeof result.apnsId === "string" &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(result.apnsId)
      ? result.apnsId
      : undefined;
  return {
    status:
      result.ok && httpStatus !== undefined && httpStatus >= 200 && httpStatus < 300
        ? "provider_accepted"
        : !result.ok && httpStatus !== undefined && httpStatus >= 300
          ? "provider_rejected"
          : "acceptance_unknown",
    transport: result.transport,
    ...(httpStatus === undefined ? {} : { httpStatus }),
    ...(providerId === undefined ? {} : { providerId }),
  };
}

/** Internal dependency seam; production plugins use the lazy gateway-runtime helper. */
export function createIosEvidenceNotificationSender(deps: Dependencies = defaultDependencies) {
  return async (
    input: IosEvidenceNotificationInput,
    options: IosEvidenceNotificationOptions,
  ): Promise<IosEvidenceNotificationResult> => {
    const unavailable = { status: "not_sent_unavailable" } as const;
    if (
      !input ||
      !validIdentifier(input.targetDeviceId, 128) ||
      !validIdentifier(input.operationId, 300) ||
      !validIdentifier(input.eventId, 300) ||
      (input.artifactSha256 !== undefined &&
        (typeof input.artifactSha256 !== "string" ||
          !/^[0-9a-f]{64}$/.test(input.artifactSha256))) ||
      typeof options?.authorizeSend !== "function"
    ) {
      return unavailable;
    }
    // Copy the exact pointer before awaiting caller-owned work.
    const { targetDeviceId, operationId, eventId, artifactSha256 } = input;
    let sendParams: Parameters<typeof sendApnsEvidenceAlert>[0];
    try {
      const paired = await deps.getPairedDevice(targetDeviceId);
      if (!canReadEvidence(paired, targetDeviceId)) {
        return unavailable;
      }
      const registration = await deps.loadApnsRegistration(targetDeviceId);
      if (!registration || registration.nodeId !== targetDeviceId) {
        return unavailable;
      }
      const gatewayIdentity = deps.getGatewayIdentity();
      if (!validIdentifier(gatewayIdentity.deviceId, 128)) {
        return unavailable;
      }
      const pointer = {
        gatewayDeviceId: gatewayIdentity.deviceId,
        operationId,
        eventId,
        ...(artifactSha256 === undefined ? {} : { artifactSha256 }),
      };
      if (!isApnsEvidenceAlertPayloadWithinLimit(pointer)) {
        return unavailable;
      }
      if (registration.transport === "direct") {
        const auth = await deps.resolveDirectAuth(process.env);
        if (!auth.ok) {
          return unavailable;
        }
        sendParams = { ...pointer, registration, auth: auth.value };
      } else {
        const relay = deps.resolveRelayConfig(process.env, deps.getRuntimeConfig().gateway, {
          registrationRelayOrigin: registration.relayOrigin,
        });
        if (!relay.ok) {
          return unavailable;
        }
        sendParams = {
          ...pointer,
          registration,
          relayConfig: relay.value,
          relayGatewayIdentity: gatewayIdentity,
        };
      }
      // JavaScript plugins can violate the declared boolean contract. Only literal true admits.
      const sendAuthorization: unknown = await options.authorizeSend();
      if (sendAuthorization !== true) {
        return { status: "not_sent_held" };
      }
      // A replaced route needs a new admission. Never send using stale registration custody.
      if (!isDeepStrictEqual(registration, await deps.loadApnsRegistration(targetDeviceId))) {
        return unavailable;
      }
      const currentPairing = await deps.getPairedDevice(targetDeviceId);
      if (
        !canReadEvidence(currentPairing, targetDeviceId) ||
        currentPairing.publicKey !== paired.publicKey
      ) {
        return unavailable;
      }
    } catch {
      return unavailable;
    }
    try {
      return providerResult(await deps.sendAlert(sendParams));
    } catch {
      // The transport may have dispatched before failing. Do not retry or claim rejection.
      return { status: "acceptance_unknown", transport: sendParams.registration.transport };
    }
  };
}

export const sendIosEvidenceNotification = createIosEvidenceNotificationSender();
