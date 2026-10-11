export type Action =
  | { tool: "open_app"; app: string }
  | { tool: "close_app"; app: string }
  | { tool: "set_low_power_mode"; on: boolean }
  | { tool: "set_dark_mode"; on: boolean }
  | { tool: "set_volume"; level: number }
  | { tool: "mute"; on: boolean }
  | { tool: "close_this" }
  | { tool: "minimize_this" }
  | { tool: "open_this" }
  | { tool: "minimize_front_window" }
  | { tool: "install_app"; name: string }
  | { tool: "open_url"; url: string }
  | { tool: "type_text"; text: string }
  | { tool: "press_key"; key: "escape" | "enter" | "space" | "tab" }
  | { tool: "wait"; seconds: number }
  | { tool: "click_element"; app: string; label: string };

export interface AgentResponse {
  reply: string;
  actions: Action[];
  model: "cloud" | "local";
  session_id: string;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isAction(value: unknown): value is Action {
  if (!isRecord(value) || typeof value.tool !== "string") return false;
  const exact = (...keys: string[]): boolean =>
    Object.keys(value).length === keys.length && keys.every((key) => Object.hasOwn(value, key));
  const text = (key: string): boolean => {
    const val = value[key];
    return typeof val === "string" && val.trim().length > 0;
  };

  switch (value.tool) {
    case "open_app":
    case "close_app":
      return exact("tool", "app") && text("app");
    case "set_low_power_mode":
    case "set_dark_mode":
    case "mute":
      return exact("tool", "on") && typeof value.on === "boolean";
    case "set_volume":
      return exact("tool", "level") && typeof value.level === "number" &&
        Number.isInteger(value.level) && value.level >= 0 && value.level <= 100;
    case "close_this":
    case "minimize_this":
    case "open_this":
    case "minimize_front_window":
      return exact("tool");
    case "install_app":
      return exact("tool", "name") && text("name");
    case "type_text":
      return exact("tool", "text") && text("text");
    case "press_key":
      return exact("tool", "key") && typeof value.key === "string" &&
        ["escape", "enter", "space", "tab"].includes(value.key);
    case "open_url": {
      if (!exact("tool", "url") || typeof value.url !== "string") return false;
      try {
        const url = new URL(value.url);
        return value.url.startsWith("https://") && url.protocol === "https:" && url.hostname.length > 0;
      } catch { return false; }
    }
    case "wait":
      return exact("tool", "seconds") && typeof value.seconds === "number" &&
        !Number.isNaN(value.seconds) && value.seconds >= 0.5 && value.seconds <= 5;
    case "click_element":
      return exact("tool", "app", "label") && text("app") && text("label");
    default:
      return false;
  }
}

export function parseAgentReply(
  raw: string,
  model: "cloud" | "local" = "local",
  session_id = "",
): AgentResponse {
  let cleaned = raw.trim();
  if (cleaned.startsWith("```")) {
    cleaned = cleaned.replace(/^```(?:json)?\s*/i, "").replace(/\s*```$/, "").trim();
  }
  let parsed: unknown;
  try { parsed = JSON.parse(cleaned); }
  catch { return { reply: raw, actions: [], model, session_id }; }
  // An invalid reply envelope must not authorize otherwise well-shaped actions.
  if (!isRecord(parsed) || typeof parsed.reply !== "string") {
    return { reply: raw, actions: [], model, session_id };
  }
  return {
    reply: parsed.reply,
    actions: Array.isArray(parsed.actions) ? parsed.actions.filter(isAction) : [],
    model,
    session_id,
  };
}
