import * as crypto from "node:crypto";
import * as fs from "node:fs";
import * as path from "node:path";
import { api } from "encore.dev/api";
import { secret } from "encore.dev/config";
import { parseAgentReply, type AgentResponse } from "./agent-response";
import { fetchAvailableModels } from "./models";
import { resolveOrCreateSession, recordMessages, isValidUUID } from "./sessions";

const groqApiKeySecret = secret("GROQ_API_KEY");

export function getGroqApiKey(): string | undefined {
  try {
    const key = groqApiKeySecret();
    if (key && key.trim().length > 0) return key.trim();
  } catch {
    // Secret not configured in Encore secrets
  }
  const envKey = process.env.GROQ_API_KEY;
  if (envKey && envKey.trim().length > 0) return envKey.trim();

  try {
    const envPaths = [
      path.resolve(process.cwd(), ".env"),
      path.resolve(process.cwd(), ".env.local"),
      path.resolve(__dirname, "../.env"),
      path.resolve(__dirname, "../../.env"),
    ];
    for (const p of envPaths) {
      if (fs.existsSync(p)) {
        const content = fs.readFileSync(p, "utf-8");
        for (const line of content.split("\n")) {
          const trimmed = line.trim();
          if (trimmed.startsWith("GROQ_API_KEY=")) {
            const val = trimmed.slice("GROQ_API_KEY=".length).trim().replace(/^["']|["']$/g, "");
            if (val) return val;
          }
        }
      }
    }
  } catch {
    // Unable to read local file
  }

  return undefined;
}

export interface AgentRequest {
  text: string;
  model?: string;
  session_id?: string;
  pointed_target?: {
    app: string;
    kind: "window" | "dock_icon";
    title?: string;
  };
  running_apps?: string[];
  frontmost_app?: string;
}

export function needsActions(request: AgentRequest): boolean {
  if (request.pointed_target) {
    return true;
  }
  const text = (request.text || "").trim();
  if (!text) {
    return false;
  }

  // App control verbs: "open Notes", "close Terminal", "launch Safari", "quit Slack"
  if (/\b(open|launch|close|quit|exit|kill|terminate)\b/i.test(text)) {
    return true;
  }

  // System settings: "dark mode", "light mode", "low power", "battery saver", "volume", "mute", "unmute"
  if (/\b(dark[\s_-]*mode|light[\s_-]*mode|low[\s_-]*power|battery[\s_-]*saver|volume|mute|unmute)\b/i.test(text)) {
    return true;
  }

  // Window actions: "minimize", "maximize", "close this", "minimize this", "open this"
  if (/\b(minimize|fullscreen|close\s+this|minimize\s+this|open\s+this|close\s+window)\b/i.test(text)) {
    return true;
  }

  // App installation: "install Chrome", "download Docker"
  if (/\b(install|download)\b/i.test(text)) {
    return true;
  }

  // Navigation & URLs: "go to apple.com", "visit https://...", "search google for..."
  if (/\b(go\s+to|visit|browse(\s+to)?|navigate\s+to)\b/i.test(text)) {
    return true;
  }
  if (/https?:\/\/|\b[\w-]+\.(com|org|net|io|dev|app|edu|gov)\b/i.test(text)) {
    return true;
  }

  // In-app actions & typing commands: "click Button", "press Enter", "type Hello", "hit key"
  if (/\b(click|press\s+key|hit\s+key|type\s+["']|press\s+(enter|escape|space|tab|return))\b/i.test(text)) {
    return true;
  }

  // Multi-step action connector words: "and write", "and type", "and search"
  if (/\band\s+(then\s+)?(write|type|search|open|close|click|press)\b/i.test(text)) {
    return true;
  }

  return false;
}

const fastChatSystemPrompt = `You are Wave, an ultra-smart Mac assistant and companion. Talk like a sharp, friendly, natural pro: short, speakable (1-2 sentences, no markdown). Always respond with ONLY valid JSON: {"reply": "<your answer>", "actions": []}`;

const systemPrompt = `You are Wave, an ultra-smart Mac assistant and companion. Talk like a sharp, friendly, natural pro: short, speakable ('opening YouTube for you', 'got it, closing Terminal', 'On it, opening Notes and writing that down, bro.'). Always respond with ONLY valid JSON: {"reply": "<1-2 short speakable sentences, no markdown>", "actions": [...]}.

Strict Rules for Actions:
- Multi-step Planning:
  * When the user asks for something multi-step (e.g. 'open Notes and write the shopping list', 'open Notes and write hello wave', 'open Safari and go to apple.com'), break it into an ordered actions list.
  * Put a short wait after open_app before type_text so the app has time to open (e.g. {"tool":"open_app","app":"Notes"}, {"tool":"wait","seconds":1}, {"tool":"type_text","text":"..."}).
  * When opening a browser to visit a URL, remember to emit ONLY open_url.
  * Keep the reply to 1-2 short speakable sentences saying what you are doing (e.g. "On it, opening Notes and writing that down, bro.").
- Actions inside apps (e.g. 'search Chrome for cute puppies', 'in Chrome search for puppies', 'in Notes write grocery list'):
  * Plan the full sequence: open_app, then click_element for the right field (e.g. {"tool":"click_element","app":"Chrome","label":"Address bar"}), then type_text, then press_key Enter ({"tool":"press_key","key":"enter"}).
  * Keep the 1-2 sentence buddy reply (e.g. "On it, searching Chrome for cute puppies.").
- Websites / Services / URLs (e.g. 'open YouTube', 'search Google', 'open github.com'):
  * Emit ONLY {"tool":"open_url","url":"https://..."}.
  * NEVER emit {"tool":"open_app"} for a browser (do NOT emit open_app for Safari or Chrome) when the user asks to open a website or URL.
  * Always use proper canonical HTTPS URLs (e.g. 'https://www.youtube.com', 'https://www.google.com', 'https://github.com').
- Pointing Target Actions ('close this', 'minimize this', 'open this'):
  * Use close_this, minimize_this, or open_this based on the pointed_target context.
- App Management ('open Slack', 'close Safari', 'quit Terminal'):
  * Use open_app or close_app with the app name.
- System Settings ('low power mode', 'dark mode', 'volume 70', 'mute'):
  * Emit set_low_power_mode, set_dark_mode, set_volume, or mute.
- If the user is just chatting or asking a general question, leave actions: [].`;

const tools = `Allowed action shapes (exact keys, no additional fields):
{"tool":"open_app","app":"<App Name>"}
{"tool":"close_app","app":"<App Name>"}
{"tool":"click_element","app":"<App Name>","label":"<Element Label>"}
{"tool":"set_low_power_mode","on":true}
{"tool":"set_dark_mode","on":true}
{"tool":"set_volume","level":50}
{"tool":"mute","on":true}
{"tool":"close_this"}
{"tool":"minimize_this"}
{"tool":"open_this"}
{"tool":"minimize_front_window"}
{"tool":"install_app","name":"<App Name>"}
{"tool":"open_url","url":"https://example.com"}
{"tool":"type_text","text":"<Text>"}
{"tool":"press_key","key":"escape"}
{"tool":"wait","seconds":1}
App names, install names, element labels, text, and HTTPS URLs are supplied by the user's request; the examples are not fixed values. on is a boolean. level is an integer from 0 to 100. seconds is a number between 0.5 and 5. key is exactly escape, enter, space, or tab. pointed_target is context, not an action field. Never emit open_app for a browser when opening a website URL.`;

async function callGroqFast(text: string, apiKey: string, model: string): Promise<AgentResponse | null> {
  try {
    const response = await fetch("https://api.groq.com/openai/v1/chat/completions", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": `Bearer ${apiKey}`,
      },
      body: JSON.stringify({
        model,
        messages: [
          { role: "system", content: fastChatSystemPrompt },
          { role: "user", content: text },
        ],
        response_format: { type: "json_object" },
        temperature: 0.3,
      }),
      signal: AbortSignal.timeout(6_000),
    });
    if (!response.ok) {
      console.warn(`Groq fast chat for model ${model} failed with status ${response.status}`);
      return null;
    }
    const data: unknown = await response.json();
    if (
      typeof data !== "object" || data === null ||
      !("choices" in data) || !Array.isArray(data.choices) || data.choices.length === 0 ||
      typeof data.choices[0] !== "object" || data.choices[0] === null ||
      !("message" in data.choices[0]) || typeof data.choices[0].message !== "object" ||
      data.choices[0].message === null || !("content" in data.choices[0].message) ||
      typeof data.choices[0].message.content !== "string"
    ) {
      return null;
    }
    return parseAgentReply(data.choices[0].message.content, "cloud");
  } catch (err) {
    console.warn(`Groq fast chat exception for model ${model}:`, err);
    return null;
  }
}

async function callGroq(request: AgentRequest, apiKey: string, model: string): Promise<AgentResponse | null> {
  try {
    const response = await fetch("https://api.groq.com/openai/v1/chat/completions", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": `Bearer ${apiKey}`,
      },
      body: JSON.stringify({
        model,
        messages: [
          { role: "system", content: systemPrompt },
          { role: "system", content: tools },
          { role: "user", content: JSON.stringify(request) },
        ],
        response_format: { type: "json_object" },
        temperature: 0,
      }),
      signal: AbortSignal.timeout(10_000),
    });
    if (!response.ok) {
      console.warn(`Groq request for model ${model} failed with status ${response.status}`);
      return null;
    }
    const data: unknown = await response.json();
    if (
      typeof data !== "object" || data === null ||
      !("choices" in data) || !Array.isArray(data.choices) || data.choices.length === 0 ||
      typeof data.choices[0] !== "object" || data.choices[0] === null ||
      !("message" in data.choices[0]) || typeof data.choices[0].message !== "object" ||
      data.choices[0].message === null || !("content" in data.choices[0].message) ||
      typeof data.choices[0].message.content !== "string"
    ) {
      return null;
    }
    return parseAgentReply(data.choices[0].message.content, "cloud");
  } catch (err) {
    console.warn(`Groq call exception for model ${model}:`, err);
    return null;
  }
}

async function callOllamaFast(text: string, model = "ornith:9b"): Promise<AgentResponse | null> {
  try {
    const response = await fetch("http://localhost:11434/api/chat", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        model,
        stream: false,
        keep_alive: "24h",
        format: "json",
        options: { temperature: 0.3 },
        messages: [
          { role: "system", content: fastChatSystemPrompt },
          { role: "user", content: text },
        ],
      }),
      signal: AbortSignal.timeout(60_000),
    });
    if (!response.ok) return null;
    const data: unknown = await response.json();
    if (
      typeof data !== "object" || data === null || "error" in data ||
      !("message" in data) || typeof data.message !== "object" ||
      data.message === null || !("content" in data.message) ||
      typeof data.message.content !== "string"
    ) return null;
    return parseAgentReply(data.message.content, "local");
  } catch (err) {
    console.warn(`Ollama fast call exception for model ${model}:`, err);
    return null;
  }
}

async function callOllama(request: AgentRequest, model = "ornith:9b"): Promise<AgentResponse | null> {
  try {
    const response = await fetch("http://localhost:11434/api/chat", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        model,
        stream: false,
        keep_alive: "24h",
        format: "json",
        options: { temperature: 0 },
        messages: [
          { role: "system", content: systemPrompt },
          { role: "system", content: tools },
          { role: "user", content: JSON.stringify(request) },
        ],
      }),
      signal: AbortSignal.timeout(60_000),
    });
    if (!response.ok) return null;
    const data: unknown = await response.json();
    if (
      typeof data !== "object" || data === null || "error" in data ||
      !("message" in data) || typeof data.message !== "object" ||
      data.message === null || !("content" in data.message) ||
      typeof data.message.content !== "string"
    ) return null;
    return parseAgentReply(data.message.content, "local");
  } catch (err) {
    console.warn(`Ollama call exception for model ${model}:`, err);
    return null;
  }
}

type ValidatedModel =
  | { type: "auto" }
  | { type: "cloud_default" }
  | { type: "cloud_specific"; modelId: string }
  | { type: "local_default" }
  | { type: "local_specific"; modelName: string };

async function validateRequestedModel(requested?: string): Promise<ValidatedModel> {
  if (!requested || typeof requested !== "string") {
    return { type: "auto" };
  }
  const trimmed = requested.trim();
  if (trimmed === "" || trimmed === "auto") {
    return { type: "auto" };
  }
  if (trimmed === "cloud") {
    return { type: "cloud_default" };
  }
  if (trimmed === "local") {
    return { type: "local_default" };
  }

  const models = await fetchAvailableModels();

  if (trimmed.startsWith("cloud:")) {
    const modelId = trimmed.slice("cloud:".length).trim();
    if (modelId && models.cloud.includes(modelId)) {
      return { type: "cloud_specific", modelId };
    }
    console.warn(`Requested cloud model '${modelId}' not in available list:`, models.cloud);
    return { type: "cloud_default" };
  }

  if (trimmed.startsWith("local:")) {
    const modelName = trimmed.slice("local:".length).trim();
    if (modelName && (models.local.includes(modelName) || (models.local.length === 0 && modelName === "ornith:9b"))) {
      return { type: "local_specific", modelName };
    }
    console.warn(`Requested local model '${modelName}' not in available list:`, models.local);
    return { type: "local_default" };
  }

  // Fallback on unrecognized input: default to auto
  console.warn(`Invalid model parameter format: '${requested}', falling back to auto`);
  return { type: "auto" };
}

async function safeRecordMessages(
  sessionId: string,
  userText: string,
  requestedModel: string | undefined,
  replyText: string,
  responseModel: string,
): Promise<void> {
  try {
    await recordMessages(sessionId, userText, requestedModel, replyText, responseModel);
  } catch (err) {
    console.warn("Failed to record messages in database:", err);
  }
}

export const agent = api(
  { expose: true, method: "POST", path: "/agent" },
  async (request: AgentRequest): Promise<AgentResponse> => {
    let sessionId: string;
    try {
      sessionId = await resolveOrCreateSession(request.session_id, request.text);
    } catch (err) {
      console.warn("Failed to resolve or create session:", err);
      sessionId =
        request.session_id && isValidUUID(request.session_id)
          ? request.session_id
          : crypto.randomUUID();
    }

    const validated = await validateRequestedModel(request.model);
    const isAction = needsActions(request);

    // 1. Explicit local model request (never overridden)
    if (validated.type === "local_default" || validated.type === "local_specific") {
      const localModelName = validated.type === "local_specific" ? validated.modelName : "ornith:9b";
      try {
        const localResult = await (isAction ? callOllama(request, localModelName) : callOllamaFast(request.text, localModelName));
        if (localResult) {
          localResult.session_id = sessionId;
          await safeRecordMessages(sessionId, request.text, request.model, localResult.reply, localResult.model);
          return localResult;
        }
      } catch (err) {
        console.warn(`Local model call failed for ${localModelName}:`, err);
      }
      const fallbackResult: AgentResponse = {
        reply: "The local model is not running right now.",
        actions: [],
        model: "local",
        session_id: sessionId,
      };
      await safeRecordMessages(sessionId, request.text, request.model, fallbackResult.reply, fallbackResult.model);
      return fallbackResult;
    }

    // 2. Explicit cloud specific model request (never overridden)
    if (validated.type === "cloud_specific") {
      const apiKey = getGroqApiKey();
      if (apiKey) {
        try {
          const specificResult = await (isAction ? callGroq(request, apiKey, validated.modelId) : callGroqFast(request.text, apiKey, validated.modelId));
          if (specificResult) {
            specificResult.session_id = sessionId;
            await safeRecordMessages(sessionId, request.text, request.model, specificResult.reply, specificResult.model);
            return specificResult;
          }
        } catch (err) {
          console.warn(`Groq specific model ${validated.modelId} failed:`, err);
        }
      }
      const fallbackResult: AgentResponse = {
        reply: "Cloud model is not reachable right now.",
        actions: [],
        model: "cloud",
        session_id: sessionId,
      };
      await safeRecordMessages(sessionId, request.text, request.model, fallbackResult.reply, fallbackResult.model);
      return fallbackResult;
    }

    // 3. Explicit cloud default request (never overridden)
    if (validated.type === "cloud_default") {
      const apiKey = getGroqApiKey();
      if (apiKey) {
        // Primary: openai/gpt-oss-120b
        try {
          const cloud120b = await (isAction ? callGroq(request, apiKey, "openai/gpt-oss-120b") : callGroqFast(request.text, apiKey, "openai/gpt-oss-120b"));
          if (cloud120b) {
            cloud120b.session_id = sessionId;
            await safeRecordMessages(sessionId, request.text, request.model, cloud120b.reply, cloud120b.model);
            return cloud120b;
          }
        } catch (err) {
          console.warn("Groq primary model openai/gpt-oss-120b failed:", err);
        }

        // Secondary fallback: openai/gpt-oss-20b
        try {
          const cloud20b = await (isAction ? callGroq(request, apiKey, "openai/gpt-oss-20b") : callGroqFast(request.text, apiKey, "openai/gpt-oss-20b"));
          if (cloud20b) {
            cloud20b.session_id = sessionId;
            await safeRecordMessages(sessionId, request.text, request.model, cloud20b.reply, cloud20b.model);
            return cloud20b;
          }
        } catch (err) {
          console.warn("Groq fallback model openai/gpt-oss-20b failed:", err);
        }
      }
      const fallbackResult: AgentResponse = {
        reply: "Cloud model is not reachable right now.",
        actions: [],
        model: "cloud",
        session_id: sessionId,
      };
      await safeRecordMessages(sessionId, request.text, request.model, fallbackResult.reply, fallbackResult.model);
      return fallbackResult;
    }

    // 4. Auto Mode (default when model is omitted or "auto"):
    // Try Cloud first (120b -> 20b); automatically fall back to Local Ollama on failure/timeout/missing key.
    const apiKey = getGroqApiKey();
    if (apiKey) {
      // 1. Primary Cloud: openai/gpt-oss-120b
      try {
        const cloud120b = await (isAction ? callGroq(request, apiKey, "openai/gpt-oss-120b") : callGroqFast(request.text, apiKey, "openai/gpt-oss-120b"));
        if (cloud120b) {
          cloud120b.session_id = sessionId;
          await safeRecordMessages(sessionId, request.text, request.model, cloud120b.reply, cloud120b.model);
          return cloud120b;
        }
      } catch (err) {
        console.warn("Auto mode: Groq primary model failed:", err);
      }

      // 2. Secondary Cloud: openai/gpt-oss-20b
      try {
        const cloud20b = await (isAction ? callGroq(request, apiKey, "openai/gpt-oss-20b") : callGroqFast(request.text, apiKey, "openai/gpt-oss-20b"));
        if (cloud20b) {
          cloud20b.session_id = sessionId;
          await safeRecordMessages(sessionId, request.text, request.model, cloud20b.reply, cloud20b.model);
          return cloud20b;
        }
      } catch (err) {
        console.warn("Auto mode: Groq secondary model failed:", err);
      }
    }

    // 3. Automatic fallback to local Ollama (ornith:9b)
    try {
      const localResult = await (isAction ? callOllama(request, "ornith:9b") : callOllamaFast(request.text, "ornith:9b"));
      if (localResult) {
        localResult.session_id = sessionId;
        await safeRecordMessages(sessionId, request.text, request.model, localResult.reply, localResult.model);
        return localResult;
      }
    } catch (err) {
      console.warn("Auto mode: Local Ollama fallback failed:", err);
    }

    // 4. Final safety net: never return an HTTP error when one or both brains are down
    const finalFallback: AgentResponse = {
      reply: "I'm having trouble reaching both cloud and local models right now.",
      actions: [],
      model: "local",
      session_id: sessionId,
    };
    await safeRecordMessages(sessionId, request.text, request.model, finalFallback.reply, finalFallback.model);
    return finalFallback;
  },
);

