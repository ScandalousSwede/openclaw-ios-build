import { html } from "lit";

export const operationalStyles = html`<style>
  .argus-selected-title {
    overflow-wrap: anywhere;
    white-space: normal;
    font-size: 1.05rem;
    line-height: 1.5;
  }
  .argus-review-history code {
    overflow-wrap: anywhere;
  }
  .argus-review-history li {
    margin-block: 1rem;
  }
  .argus-evidence-basis {
    display: grid;
    grid-template-columns: minmax(130px, 1fr) minmax(0, 3fr);
    gap: 12px 20px;
  }
  .argus-evidence-basis dt {
    font-weight: 650;
  }
  .argus-evidence-basis dd {
    margin: 0;
    overflow-wrap: anywhere;
  }
  .argus-evidence-basis ul,
  .argus-evidence-basis p {
    margin: 0;
  }
  @media (max-width: 640px) {
    .argus-selected-title {
      overflow-wrap: anywhere;
      white-space: normal;
      font-size: 1.05rem;
      line-height: 1.5;
    }
    .argus-review-history code {
      overflow-wrap: anywhere;
    }
    .argus-review-history li {
      margin-block: 1rem;
    }
    .argus-evidence-basis {
      grid-template-columns: minmax(0, 1fr);
      gap: 4px;
    }
    .argus-evidence-basis dd {
      margin-bottom: 12px;
    }
  }
  .argus-evidence {
    background: var(--card, #101c29);
    border: 1px solid color-mix(in srgb, currentColor 45%, transparent);
    border-radius: 16px;
    padding: clamp(18px, 3vw, 32px);
    margin-bottom: 24px;
    font-size: 18px;
    line-height: 1.6;
    overflow-wrap: anywhere;
  }
  .argus-evidence h2 {
    font-size: clamp(26px, 3vw, 38px);
    margin: 0 0 12px;
    line-height: 1.25;
  }
  .argus-evidence h3 {
    font-size: 22px;
    margin: 12px 0;
  }
  .argus-evidence p {
    margin: 8px 0;
  }
  .argus-evidence .argus-toolbar {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: 12px;
    margin: 12px 0;
  }
  .argus-evidence button,
  .argus-evidence input,
  .argus-evidence a {
    font: inherit;
    min-height: 48px;
  }
  .argus-evidence a {
    white-space: normal;
    max-width: 100%;
    box-sizing: border-box;
    color: inherit;
    text-decoration: underline;
  }
  .argus-evidence button {
    padding: 10px 18px;
    border: 1px solid color-mix(in srgb, currentColor 55%, transparent);
    white-space: normal;
  }
  .argus-evidence .argus-scope-fields {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(min(100%, 16rem), 1fr));
    gap: 16px;
    margin: 16px 0;
  }
  .argus-evidence select {
    font: inherit;
    min-height: 48px;
    width: 100%;
    padding: 10px;
  }
  .argus-evidence input {
    width: 100%;
    max-width: 36rem;
    padding: 10px;
    box-sizing: border-box;
  }
  .argus-evidence :focus-visible {
    outline: 3px solid #39d9eb;
    outline-offset: 4px;
  }
  .argus-evidence ul {
    padding: 0;
    list-style: none;
    display: grid;
    gap: 16px;
  }
  .argus-evidence li {
    border: 1px solid color-mix(in srgb, currentColor 45%, transparent);
    border-radius: 10px;
    padding: 18px;
  }
  .argus-evidence .argus-work-list {
    gap: 8px;
    max-height: 20rem;
    overflow-y: auto;
    padding: 4px;
    margin: 8px -4px;
  }
  .argus-evidence .argus-work-list > li {
    border: 0;
    padding: 0;
  }
  .argus-evidence .argus-work-row {
    display: grid;
    grid-template-columns: minmax(0, 1fr) auto;
    align-items: center;
    gap: 4px 12px;
    width: 100%;
    text-align: left;
    border: 1px solid var(--border);
    border-radius: var(--radius-md, 8px);
    background: var(--card);
    color: inherit;
    padding: 10px 12px;
    line-height: 1.4;
  }
  .argus-evidence .argus-work-row[aria-current="true"] {
    border-color: var(--accent);
    box-shadow: inset 3px 0 0 var(--accent);
    background: color-mix(in srgb, var(--accent) 8%, var(--card));
  }
  .argus-work-title {
    display: -webkit-box;
    -webkit-box-orient: vertical;
    -webkit-line-clamp: 2;
    overflow: hidden;
    font-size: 1rem;
    font-weight: 650;
  }
  .argus-work-context {
    grid-column: 1 / -1;
    font-size: 0.875rem;
  }
  .argus-work-action {
    font-size: 0.875rem;
    font-weight: 600;
  }
  @media (max-width: 640px) {
    .argus-evidence .argus-work-list {
      max-height: 14rem;
    }
    .argus-evidence .argus-work-row {
      grid-template-columns: minmax(0, 1fr);
      gap: 4px;
    }
    .argus-work-action {
      grid-row: 4;
    }
  }
  .argus-evidence details {
    margin-top: 16px;
  }
  .argus-evidence summary {
    cursor: pointer;
    min-height: 44px;
  }
  .argus-evidence .argus-detail {
    border-top: 2px solid var(--border, #466075);
    margin-top: 16px;
    padding-top: 12px;
  }
</style>`;
