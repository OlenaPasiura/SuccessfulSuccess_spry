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

const getBaseUrl = (): string => {
  return import.meta.env.VITE_API_URL || 'http://localhost:8000';
};

export async function fetchMeetings(): Promise<Meeting[]> {
  const baseUrl = getBaseUrl();
  const response = await fetch(`${baseUrl}/api/meetings`);

  if (!response.ok) {
    const errorText = await response.text();
    throw new Error(errorText || `Failed to fetch meetings (${response.status})`);
  }

  return response.json();
}

export async function createMeeting(data: CreateMeetingInput): Promise<Meeting> {
  const baseUrl = getBaseUrl();
  const response = await fetch(`${baseUrl}/api/meetings`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
    },
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
