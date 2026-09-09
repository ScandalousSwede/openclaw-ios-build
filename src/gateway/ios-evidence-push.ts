import { isDeepStrictEqual } from "node:util";
import { getRuntimeConfig } from "../config/io.js";
import { loadOrCreateProcessDeviceIdentity } from "../infra/device-identity.js";
import {
  getPairedDevice,
  hasEffectivePairedDeviceRole,
  type PairedDevice,
} from "../infra/device-pairing.js";
import { getApnsBearerToken } from "../infra/push-apns-auth.js";
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
  /** Repeatable send-time deny check; may run again after transport preparation. */
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
    let snapshot: IosEvidenceNotificationInput;
    let authorizeSend: IosEvidenceNotificationOptions["authorizeSend"];
    try {
      if (!input) {
        return unavailable;
      }
      // Accessor-backed JavaScript input must not change between validation and use.
      snapshot = {
        targetDeviceId: input.targetDeviceId,
        operationId: input.operationId,
        eventId: input.eventId,
        artifactSha256: input.artifactSha256,
      };
      authorizeSend = options?.authorizeSend;
    } catch {
      return unavailable;
    }
    const { targetDeviceId, operationId, eventId, artifactSha256 } = snapshot;
    if (
      !validIdentifier(targetDeviceId, 128) ||
      !validIdentifier(operationId, 300) ||
      !validIdentifier(eventId, 300) ||
      (artifactSha256 !== undefined &&
        (typeof artifactSha256 !== "string" || !/^[0-9a-f]{64}$/.test(artifactSha256))) ||
      typeof authorizeSend !== "function"
    ) {
      return unavailable;
    }
    let sendParams: Parameters<typeof sendApnsEvidenceAlert>[0];
    let transportDenial: IosEvidenceNotificationResult | undefined;
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
        // Signing failures are known preparation failures, before any request.
        // The transport reuses the authentication owner's cached bearer token.
        getApnsBearerToken(auth.value);
        sendParams = { ...pointer, nodeId: targetDeviceId, registration, auth: auth.value };
      } else {
        const relay = deps.resolveRelayConfig(process.env, deps.getRuntimeConfig().gateway, {
          registrationRelayOrigin: registration.relayOrigin,
        });
        if (!relay.ok) {
          return unavailable;
        }
        sendParams = {
          ...pointer,
          nodeId: targetDeviceId,
          registration,
          relayConfig: relay.value,
          relayGatewayIdentity: gatewayIdentity,
        };
      }
      // JavaScript plugins can violate the declared boolean contract. Only literal true admits.
      const sendAuthorization: unknown = await authorizeSend.call(options);
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
      // The transport repeats this after awaited connection preparation. Keep
      // the admitted pointer and pairing identity fenced through that boundary.
      sendParams.isCurrent = async () => {
        try {
          const currentAuthorization: unknown = await authorizeSend.call(options);
          if (currentAuthorization !== true) {
            transportDenial = { status: "not_sent_held" };
            return false;
          }
          if (!isDeepStrictEqual(registration, await deps.loadApnsRegistration(targetDeviceId))) {
            transportDenial = unavailable;
            return false;
          }
          const latestPairing = await deps.getPairedDevice(targetDeviceId);
          if (
            !canReadEvidence(latestPairing, targetDeviceId) ||
            latestPairing.publicKey !== paired.publicKey
          ) {
            transportDenial = unavailable;
            return false;
          }
          return true;
        } catch {
          transportDenial = unavailable;
          return false;
        }
      };
    } catch {
      return unavailable;
    }
    try {
      return providerResult(await deps.sendAlert(sendParams));
    } catch {
      // Current APNs transports invoke isCurrent only before issuing their request.
      if (transportDenial) {
        return transportDenial;
      }
      // The transport may have dispatched before failing. Do not retry or claim rejection.
      return { status: "acceptance_unknown", transport: sendParams.registration.transport };
    }
  };
}
