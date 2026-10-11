import { api } from "encore.dev/api";
import { getGroqApiKey } from "./agent";

export interface ModelsResponse {
  cloud: string[];
  local: string[];
}

export const fallbackCloudModels: string[] = [
  "openai/gpt-oss-120b",
  "openai/gpt-oss-20b",
  "llama-3.3-70b-versatile",
  "llama-3.1-8b-instant",
];

let cachedModels: { data: ModelsResponse; timestamp: number } | null = null;
const CACHE_TTL_MS = 10_000;

export async function fetchCloudModels(): Promise<string[]> {
  const apiKey = getGroqApiKey();
  if (!apiKey) return fallbackCloudModels;

  try {
    const res = await fetch("https://api.groq.com/openai/v1/models", {
      method: "GET",
      headers: {
        Authorization: `Bearer ${apiKey}`,
        "Content-Type": "application/json",
      },
      signal: AbortSignal.timeout(5_000),
    });
    if (!res.ok) return fallbackCloudModels;
    const json: unknown = await res.json();
    if (
      typeof json === "object" &&
      json !== null &&
      "data" in json &&
      Array.isArray(json.data)
    ) {
      const ids: string[] = [];
      for (const item of json.data) {
        if (
          typeof item === "object" &&
          item !== null &&
          "id" in item &&
          typeof item.id === "string" &&
          ("active" in item ? item.active !== false : true)
        ) {
          // Exclude whisper/audio speech-to-text models from chat models list
          if (!item.id.toLowerCase().includes("whisper")) {
            ids.push(item.id);
          }
        }
      }
      if (ids.length > 0) {
        // Prioritize primary models at top
        const priority = ["openai/gpt-oss-120b", "openai/gpt-oss-20b"];
        const sorted = [
          ...priority.filter((p) => ids.includes(p)),
          ...ids.filter((id) => !priority.includes(id)),
        ];
        return sorted;
      }
    }
    return fallbackCloudModels;
  } catch (err) {
    console.warn("Failed to fetch models from Groq:", err);
    return fallbackCloudModels;
  }
}

export async function fetchLocalModels(): Promise<string[]> {
  try {
    const res = await fetch("http://localhost:11434/api/tags", {
      method: "GET",
      headers: { "Content-Type": "application/json" },
      signal: AbortSignal.timeout(2_000),
    });
    if (!res.ok) return [];
    const json: unknown = await res.json();
    if (
      typeof json === "object" &&
      json !== null &&
      "models" in json &&
      Array.isArray(json.models)
    ) {
      const names: string[] = [];
      for (const m of json.models) {
        if (
          typeof m === "object" &&
          m !== null &&
          "name" in m &&
          typeof m.name === "string" &&
          m.name.trim().length > 0
        ) {
          names.push(m.name.trim());
        }
      }
      return names;
    }
    return [];
  } catch {
    return [];
  }
}

export async function fetchAvailableModels(forceRefresh = false): Promise<ModelsResponse> {
  const now = Date.now();
  if (!forceRefresh && cachedModels && now - cachedModels.timestamp < CACHE_TTL_MS) {
    return cachedModels.data;
  }

  const [cloud, local] = await Promise.all([
    fetchCloudModels(),
    fetchLocalModels(),
  ]);

  const data: ModelsResponse = { cloud, local };
  cachedModels = { data, timestamp: now };
  return data;
}

export const getModels = api(
  { expose: true, method: "GET", path: "/models" },
  async (): Promise<ModelsResponse> => {
    return fetchAvailableModels(true);
  },
);
