export interface Meeting {
  id: number;
  title: string;
  starts_at: string;
  ends_at: string;
  attendee_count: number;
}

export interface CreateMeetingInput {
  title: string;
  starts_at: string;
  ends_at: string;
  attendee_count: number;
}

export interface AgendaItem {
  topic: string;
  owner: string | null;
  minutes: number | null;
}

export interface ActionItem {
  task: string;
  owner: string | null;
  due: string | null;
}

export interface ParsedAgenda {
  title: string | null;
  starts_at: string | null;
  duration_minutes: number | null;
  items: AgendaItem[];
  action_items: ActionItem[];
  language: string;
}

export interface ParseAgendaResponse {
  agenda: ParsedAgenda;
  model: string;
  prompt_version: string;
}

const getBaseUrl = (): string => {
  return import.meta.env.VITE_API_URL || 'http://localhost:8000';
};

const getAgendaParserUrl = (): string => {
  const configuredUrl = import.meta.env.VITE_AGENDA_PARSER_URL?.trim();
  if (configuredUrl) {
    return configuredUrl;
  }
  return `${getBaseUrl()}/api/agenda/parse`;
};

export async function fetchMeetings(token?: string): Promise<Meeting[]> {
  const baseUrl = getBaseUrl();
  const headers: Record<string, string> = {};
  if (token) {
    headers['Authorization'] = `Bearer ${token}`;
  }
  const response = await fetch(`${baseUrl}/api/meetings`, { headers });

  if (!response.ok) {
    const errorText = await response.text();
    throw new Error(errorText || `Failed to fetch meetings (${response.status})`);
  }

  return response.json();
}

export async function createMeeting(data: CreateMeetingInput, token?: string): Promise<Meeting> {
  const baseUrl = getBaseUrl();
  const headers: Record<string, string> = {
    'Content-Type': 'application/json',
  };
  if (token) {
    headers['Authorization'] = `Bearer ${token}`;
  }
  const response = await fetch(`${baseUrl}/api/meetings`, {
    method: 'POST',
    headers,
    body: JSON.stringify(data),
  });

  if (!response.ok) {
    let errorDetail = `Failed to create meeting (${response.status})`;
    try {
      const errorJson = await response.json();
      if (errorJson.detail) {
        if (Array.isArray(errorJson.detail)) {
          errorDetail = errorJson.detail
            .map((item: unknown) =>
              typeof item === 'object' && item !== null && 'msg' in item
                ? String((item as { msg: unknown }).msg)
                : JSON.stringify(item)
            )
            .join('; ');
        } else {
          errorDetail = String(errorJson.detail);
        }
      }
    } catch {
      // Use fallback errorDetail
    }
    throw new Error(errorDetail);
  }

  return response.json();
}

export async function updateMeeting(
  id: number,
  data: CreateMeetingInput,
  token?: string
): Promise<Meeting> {
  const baseUrl = getBaseUrl();
  const headers: Record<string, string> = {
    'Content-Type': 'application/json',
  };
  if (token) {
    headers['Authorization'] = `Bearer ${token}`;
  }
  const response = await fetch(`${baseUrl}/api/meetings/${id}`, {
    method: 'PUT',
    headers,
    body: JSON.stringify(data),
  });

  if (!response.ok) {
    let errorDetail = `Failed to update meeting (${response.status})`;
    try {
      const errorJson = await response.json();
      if (errorJson.detail) {
        errorDetail =
          typeof errorJson.detail === 'string'
            ? errorJson.detail
            : JSON.stringify(errorJson.detail);
      }
    } catch {
      // Use fallback errorDetail
    }
    throw new Error(errorDetail);
  }

  return response.json();
}

export async function parseAgenda(
  pastedText: string,
  idToken?: string
): Promise<ParseAgendaResponse> {
  const parserUrl = getAgendaParserUrl();
  const now = new Date();
  const year = now.getFullYear();
  const month = String(now.getMonth() + 1).padStart(2, '0');
  const day = String(now.getDate()).padStart(2, '0');
  const currentIsoDate = `${year}-${month}-${day}`;
  const currentTimeZone = Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC';

  const headers: Record<string, string> = {
    'Content-Type': 'application/json',
  };
  if (idToken) {
    headers['Authorization'] = `Bearer ${idToken}`;
  }

  const response = await fetch(parserUrl, {
    method: 'POST',
    headers,
    body: JSON.stringify({
      text: pastedText,
      today: currentIsoDate,
      tz: currentTimeZone,
    }),
  });

  if (!response.ok) {
    let serverMessage = '';
    try {
      const errBody = await response.json();
      serverMessage = errBody.error || errBody.detail || '';
    } catch {
      // Ignore JSON parse errors on error response
    }

    if (response.status === 401) {
      throw new Error(
        serverMessage || 'Unauthorized (401): Please sign in with Cognito to parse agendas.'
      );
    }
    if (response.status === 413) {
      throw new Error(
        serverMessage ||
          'Text too long (413): Pasted text must not exceed 10,000 characters.'
      );
    }
    if (response.status === 422) {
      throw new Error(
        serverMessage ||
          'Unparseable agenda (422): Could not extract a structured meeting agenda from the text.'
      );
    }
    throw new Error(
      serverMessage || `Failed to parse agenda (HTTP ${response.status})`
    );
  }

  return response.json();
}
