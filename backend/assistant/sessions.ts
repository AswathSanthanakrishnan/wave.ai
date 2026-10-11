import * as crypto from "node:crypto";
import { api } from "encore.dev/api";
import { db } from "./db";

export interface SessionSummary {
  id: string;
  title: string;
  created_at: string;
}

export interface GetSessionsResponse {
  sessions: SessionSummary[];
}

export interface MessageItem {
  id: string;
  session_id: string;
  role: "user" | "wave";
  text: string;
  model: string | null;
  created_at: string;
}

export interface GetSessionMessagesResponse {
  messages: MessageItem[];
}

export interface DeleteSessionResponse {
  success: boolean;
}

export const UUID_REGEX =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export function isValidUUID(id?: string): boolean {
  return typeof id === "string" && UUID_REGEX.test(id.trim());
}

export async function resolveOrCreateSession(
  requestedSessionId?: string,
  userText = "",
): Promise<string> {
  if (isValidUUID(requestedSessionId)) {
    const existing = await db.queryRow<{ id: string }>`
      SELECT id FROM sessions WHERE id = ${requestedSessionId!.trim()}
    `;
    if (existing?.id) {
      return existing.id;
    }
  }

  // Create new session titled with first 40 characters of user text
  const newId = crypto.randomUUID();
  const trimmed = userText.trim();
  const title = trimmed.length > 0 ? trimmed.slice(0, 40) : "New Session";

  await db.exec`
    INSERT INTO sessions (id, title, created_at)
    VALUES (${newId}, ${title}, NOW())
  `;

  return newId;
}

export async function recordMessages(
  sessionId: string,
  userText: string,
  requestedModel: string | undefined,
  replyText: string,
  responseModel: string,
): Promise<void> {
  const userMsgId = crypto.randomUUID();
  const waveMsgId = crypto.randomUUID();

  await db.exec`
    INSERT INTO messages (id, session_id, role, text, model, created_at)
    VALUES (${userMsgId}, ${sessionId}, 'user', ${userText}, ${requestedModel ?? null}, NOW())
  `;

  await db.exec`
    INSERT INTO messages (id, session_id, role, text, model, created_at)
    VALUES (${waveMsgId}, ${sessionId}, 'wave', ${replyText}, ${responseModel}, NOW())
  `;
}

// GET /sessions - returns latest 50 sessions
export const getSessions = api(
  { expose: true, method: "GET", path: "/sessions" },
  async (): Promise<GetSessionsResponse> => {
    const rows = await db.queryAll<{
      id: string;
      title: string;
      created_at: Date | string;
    }>`
      SELECT id, title, created_at
      FROM sessions
      ORDER BY created_at DESC
      LIMIT 50
    `;

    const sessions: SessionSummary[] = rows.map((r) => ({
      id: r.id,
      title: r.title,
      created_at:
        r.created_at instanceof Date
          ? r.created_at.toISOString()
          : new Date(r.created_at).toISOString(),
    }));

    return { sessions };
  },
);

// GET /sessions/:id/messages - returns all messages in chronological order
export const getSessionMessages = api(
  { expose: true, method: "GET", path: "/sessions/:id/messages" },
  async ({ id }: { id: string }): Promise<GetSessionMessagesResponse> => {
    if (!isValidUUID(id)) {
      return { messages: [] };
    }

    const rows = await db.queryAll<{
      id: string;
      session_id: string;
      role: "user" | "wave";
      text: string;
      model: string | null;
      created_at: Date | string;
    }>`
      SELECT id, session_id, role, text, model, created_at
      FROM messages
      WHERE session_id = ${id}
      ORDER BY created_at ASC
    `;

    const messages: MessageItem[] = rows.map((r) => ({
      id: r.id,
      session_id: r.session_id,
      role: r.role,
      text: r.text,
      model: r.model ?? null,
      created_at:
        r.created_at instanceof Date
          ? r.created_at.toISOString()
          : new Date(r.created_at).toISOString(),
    }));

    return { messages };
  },
);

// DELETE /sessions/:id - deletes the session and its messages (cascade)
export const deleteSession = api(
  { expose: true, method: "DELETE", path: "/sessions/:id" },
  async ({ id }: { id: string }): Promise<DeleteSessionResponse> => {
    if (!isValidUUID(id)) {
      return { success: false };
    }

    await db.exec`
      DELETE FROM sessions
      WHERE id = ${id}
    `;

    return { success: true };
  },
);
