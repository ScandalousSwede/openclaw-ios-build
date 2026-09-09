import { z } from "zod";
import { operationalResponseSchemas } from "./operational-schemas.ts";

const reviewHistorySchema = operationalResponseSchemas.detail.shape.review_history.unwrap();

// One neutral response contract, exported for the existing Python/plugin fixtures.
// Extra admitted backend metadata is allowed on input and stripped from UI values.
export function createOperationalContractJsonSchema() {
  const contract = {
    $schema: "https://json-schema.org/draft/2020-12/schema",
    $id: "urn:argus:operational-read-response:v1",
    $defs: {
      list: z.toJSONSchema(operationalResponseSchemas.list, { io: "input" }),
      detail: z.toJSONSchema(operationalResponseSchemas.detail, {
        io: "input",
        override: ({ zodSchema, jsonSchema }) => {
          // Bind generated constraints to their actual schema owners rather
          // than asserting the shape of an untyped generated property tree.
          const entry = reviewHistorySchema.shape.items.element;
          if (zodSchema === entry.shape.binding.shape.artifact_sha256) {
            jsonSchema.uniqueItems = true;
          }
          if (zodSchema === entry) {
            jsonSchema.allOf = [
              {
                if: { properties: { state: { const: "pending" } } },
                // JSON Schema conditional data, not a Promise-like method.
                // eslint-disable-next-line unicorn/no-thenable
                then: { properties: { disposition: { type: "null" } } },
                else: { properties: { disposition: { type: "object" } } },
              },
            ];
          }
        },
      }),
      artifact: z.toJSONSchema(operationalResponseSchemas.artifact, { io: "input" }),
    },
  };
  return contract;
}
