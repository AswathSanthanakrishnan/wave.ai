import { api } from "encore.dev/api";

interface AskRequest {
  text: string;
}

interface AskResponse {
  reply: string;
}

const fallback = "The local model is not running right now.";
const systemPrompt =
  "You are Wave, a concise voice assistant on the user's Mac. Keep replies short and speakable: 1-3 sentences, no lists, no markdown, no emojis.";

export const ask = api(
  { expose: true, method: "POST", path: "/ask" },
  async ({ text }: AskRequest): Promise<AskResponse> => {
    try {
      const response = await fetch("http://127.0.0.1:11434/api/chat", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          model: "ornith:9b",
          stream: false,
          messages: [
            { role: "system", content: systemPrompt },
            { role: "user", content: text },
          ],
        }),
        signal: AbortSignal.timeout(60_000),
      });

      if (!response.ok) return { reply: fallback };

      const data: unknown = await response.json();
      if (
        typeof data !== "object" || data === null || "error" in data ||
        !("message" in data) || typeof data.message !== "object" ||
        data.message === null || !("content" in data.message) ||
        typeof data.message.content !== "string" ||
        !data.message.content.trim()
      ) {
        return { reply: fallback };
      }

      return { reply: data.message.content.trim() };
    } catch {
      return { reply: fallback };
    }
  },
);
