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
  const envUrl = import.meta.env.VITE_API_URL || 'http://localhost:8000';
  if (
    typeof window !== 'undefined' &&
    window.location.protocol === 'https:' &&
    envUrl.startsWith('http://')
  ) {
    return window.location.origin;
  }
  return envUrl;
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
    Authorization: `Bearer ${idToken || 'demo-guest-token'}`,
  };

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

export function getIsoWeekString(dateObj: Date = new Date()): string {
  const d = new Date(Date.UTC(dateObj.getFullYear(), dateObj.getMonth(), dateObj.getDate()));
  const dayNum = d.getUTCDay() || 7;
  d.setUTCDate(d.getUTCDate() + 4 - dayNum);
  const yearStart = new Date(Date.UTC(d.getUTCFullYear(), 0, 1));
  const weekNo = Math.ceil(((d.getTime() - yearStart.getTime()) / 86400000 + 1) / 7);
  return `${d.getUTCFullYear()}-W${String(weekNo).padStart(2, '0')}`;
}

function getIsoWeekBoundsUtc(weekStr: string): {
  start: Date;
  end: Date;
  prevStart: Date;
  prevEnd: Date;
  prevLabel: string;
} {
  const match = /^(\d{4})-[Ww](\d{1,2})$/.exec(weekStr.trim());
  const year = match ? parseInt(match[1], 10) : new Date().getUTCFullYear();
  const week = match ? parseInt(match[2], 10) : 1;
  const jan4 = new Date(Date.UTC(year, 0, 4));
  const jan4Day = jan4.getUTCDay() || 7;
  const week1Monday = new Date(jan4.getTime() - (jan4Day - 1) * 86400000);
  const start = new Date(week1Monday.getTime() + (week - 1) * 7 * 86400000);
  const end = new Date(start.getTime() + 7 * 86400000);
  const prevStart = new Date(start.getTime() - 7 * 86400000);
  const prevEnd = start;
  const prevLabel = getIsoWeekString(prevStart);
  return { start, end, prevStart, prevEnd, prevLabel };
}

function buildFallbackReportLines(week: string, meetings: Meeting[]): string[][] {
  const { start, end, prevStart, prevEnd, prevLabel } = getIsoWeekBoundsUtc(week);
  const curr = meetings.filter((m) => {
    const t = new Date(m.starts_at).getTime();
    return t >= start.getTime() && t < end.getTime();
  });
  const prev = meetings.filter((m) => {
    const t = new Date(m.starts_at).getTime();
    return t >= prevStart.getTime() && t < prevEnd.getTime();
  });
  const durHours = (m: Meeting) =>
    Math.max(0, (new Date(m.ends_at).getTime() - new Date(m.starts_at).getTime()) / 3600000);
  const currHours = curr.reduce((s, m) => s + durHours(m), 0);
  const prevHours = prev.reduce((s, m) => s + durHours(m), 0);
  const countDiff = curr.length - prev.length;
  const hoursDiff = currHours - prevHours;
  const top5 = [...curr].sort((a, b) => durHours(b) - durHours(a)).slice(0, 5);
  const fmtDate = (d: Date) => d.toISOString().slice(0, 10);
  const sunday = new Date(end.getTime() - 86400000);
  const prevSunday = new Date(prevEnd.getTime() - 86400000);

  const rows: string[][] = [
    ['Weekly Meeting Report', week],
    ['Period', `${fmtDate(start)} to ${fmtDate(sunday)}`],
    ['Previous Week', `${prevLabel} (${fmtDate(prevStart)} to ${fmtDate(prevSunday)})`],
    [],
    ['Metric', `Current Week (${week})`, `Previous Week (${prevLabel})`, 'Change'],
    [
      'Meeting Count',
      String(curr.length),
      String(prev.length),
      countDiff > 0 ? `+${countDiff}` : String(countDiff),
    ],
    [
      'Total Duration (hours)',
      currHours.toFixed(2),
      prevHours.toFixed(2),
      hoursDiff > 0 ? `+${hoursDiff.toFixed(2)}` : hoursDiff.toFixed(2),
    ],
    [],
    ['Top 5 Longest Meetings'],
    ['Rank', 'Title', 'Start Time', 'Duration (hours)', 'Participant Count'],
  ];
  top5.forEach((m, i) => {
    rows.push([
      String(i + 1),
      m.title,
      m.starts_at,
      durHours(m).toFixed(2),
      String(m.attendee_count),
    ]);
  });
  return rows;
}

function buildPdfStringFromRows(rows: string[][]): string {
  const esc = (s: string) =>
    s
      .replace(/[^\x20-\x7E]/g, '?')
      .replace(/\\/g, '\\\\')
      .replace(/\(/g, '\\(')
      .replace(/\)/g, '\\)');
  const cmds = ['BT', '/F1 16 Tf', '50 760 Td'];
  rows.forEach((row, idx) => {
    if (idx === 1) {
      cmds.push('/F1 10 Tf', '0 -22 Td');
    } else if (idx > 1) {
      cmds.push('0 -16 Td');
    }
    const line = row.length === 0 ? '' : row.join(' | ');
    cmds.push(`(${esc(line)}) Tj`);
  });
  cmds.push('ET');
  const stream = cmds.join('\n');

  const objs = [
    '1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n',
    '2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n',
    '3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>\nendobj\n',
    '4 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n',
    `5 0 obj\n<< /Length ${stream.length} >>\nstream\n${stream}\nendstream\nendobj\n`,
  ];

  let out = '%PDF-1.4\n';
  const offsets: number[] = [];
  for (const o of objs) {
    offsets.push(out.length);
    out += o;
  }
  const xref = out.length;
  out += `xref\n0 ${objs.length + 1}\n0000000000 65535 f \n`;
  for (const off of offsets) {
    out += `${String(off).padStart(10, '0')} 00000 n \n`;
  }
  out += `trailer\n<< /Size ${objs.length + 1} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`;
  return out;
}

export async function downloadWeeklyReport(
  week: string,
  format: 'pdf' | 'csv',
  meetings: Meeting[],
  token?: string
): Promise<void> {
  const baseUrl = getBaseUrl();
  const headers: Record<string, string> = {};
  if (token) {
    headers['Authorization'] = `Bearer ${token}`;
  }

  let blob: Blob | null = null;
  try {
    const res = await fetch(
      `${baseUrl}/api/reports/weekly?week=${encodeURIComponent(week)}&format=${format}`,
      { headers }
    );
    if (res.ok) {
      blob = await res.blob();
    }
  } catch {
    // Fallback to client-side report generation if endpoint is unreachable
  }

  if (!blob) {
    const rows = buildFallbackReportLines(week, meetings);
    if (format === 'csv') {
      const csvContent = rows
        .map((r) => r.map((cell) => `"${cell.replace(/"/g, '""')}"`).join(','))
        .join('\n');
      blob = new Blob([csvContent], { type: 'text/csv;charset=utf-8;' });
    } else {
      const pdfContent = buildPdfStringFromRows(rows);
      blob = new Blob([pdfContent], { type: 'application/pdf' });
    }
  }

  const url = URL.createObjectURL(blob);
  const link = document.createElement('a');
  link.href = url;
  link.download = `weekly-report-${week}.${format}`;
  document.body.appendChild(link);
  link.click();
  document.body.removeChild(link);
  URL.revokeObjectURL(url);
}
