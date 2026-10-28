import React, { useState } from 'react';
import {
  ActionItem,
  AgendaItem,
  createMeeting,
  Meeting,
  ParseAgendaResponse,
  updateMeeting,
} from '@/api/meetings';
import { Button } from './ui/button';
import { Input } from './ui/input';
import { Label } from './ui/label';
import { Card, CardHeader, CardTitle, CardDescription, CardContent } from './ui/card';
import { PasteAgendaModal } from './PasteAgendaModal';
import {
  PlusCircle,
  AlertCircle,
  Loader2,
  Sparkles,
  Trash2,
  Plus,
  CheckSquare,
  ListChecks,
  X,
} from 'lucide-react';

interface MeetingFormProps {
  onMeetingCreated: () => void;
  token?: string;
  editingMeeting?: Meeting | null;
  onCancelEdit?: () => void;
}

function toLocalDateTimeInputValue(isoOrDateStr: string): string {
  const parsed = new Date(isoOrDateStr);
  if (!isNaN(parsed.getTime())) {
    const year = parsed.getFullYear();
    const month = String(parsed.getMonth() + 1).padStart(2, '0');
    const day = String(parsed.getDate()).padStart(2, '0');
    const hours = String(parsed.getHours()).padStart(2, '0');
    const minutes = String(parsed.getMinutes()).padStart(2, '0');
    return `${year}-${month}-${day}T${hours}:${minutes}`;
  }
  if (/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}/.test(isoOrDateStr)) {
    return isoOrDateStr.slice(0, 16);
  }
  return '';
}

function computeEndFromDuration(startsAtLocal: string, durationMinutes: number): string {
  const start = new Date(startsAtLocal);
  if (isNaN(start.getTime()) || durationMinutes <= 0) return '';
  const end = new Date(start.getTime() + durationMinutes * 60_000);
  return toLocalDateTimeInputValue(end.toISOString());
}

export const MeetingForm: React.FC<MeetingFormProps> = ({
  onMeetingCreated,
  token,
  editingMeeting,
  onCancelEdit,
}) => {
  const [title, setTitle] = useState(() => editingMeeting?.title ?? '');
  const [startsAt, setStartsAt] = useState(() =>
    editingMeeting ? toLocalDateTimeInputValue(editingMeeting.starts_at) : ''
  );
  const [endsAt, setEndsAt] = useState(() =>
    editingMeeting ? toLocalDateTimeInputValue(editingMeeting.ends_at) : ''
  );
  const [durationMinutes, setDurationMinutes] = useState<number | ''>(() => {
    if (!editingMeeting) return '';
    const diffMin = Math.round(
      (new Date(editingMeeting.ends_at).getTime() -
        new Date(editingMeeting.starts_at).getTime()) /
        60_000
    );
    return diffMin > 0 ? diffMin : '';
  });
  const [attendeeCount, setAttendeeCount] = useState<number | ''>(() =>
    editingMeeting ? editingMeeting.attendee_count : 1
  );
  const [agendaItems, setAgendaItems] = useState<AgendaItem[]>([]);
  const [actionItems, setActionItems] = useState<ActionItem[]>([]);
  const [parsedMeta, setParsedMeta] = useState<{
    language: string;
    model: string;
  } | null>(null);
  const [isPasteModalOpen, setIsPasteModalOpen] = useState(false);
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const handleStartsAtChange = (nextStart: string) => {
    setStartsAt(nextStart);
    if (nextStart && typeof durationMinutes === 'number' && durationMinutes > 0) {
      const computedEnd = computeEndFromDuration(nextStart, durationMinutes);
      if (computedEnd) {
        setEndsAt(computedEnd);
      }
    } else if (nextStart && endsAt) {
      const diff = Math.round(
        (new Date(endsAt).getTime() - new Date(nextStart).getTime()) / 60_000
      );
      if (diff > 0) {
        setDurationMinutes(diff);
      }
    }
  };

  const handleDurationChange = (val: string) => {
    const parsed = val === '' ? '' : parseInt(val, 10);
    setDurationMinutes(parsed);
    if (typeof parsed === 'number' && parsed > 0 && startsAt) {
      const computedEnd = computeEndFromDuration(startsAt, parsed);
      if (computedEnd) {
        setEndsAt(computedEnd);
      }
    }
  };

  const handleEndsAtChange = (nextEnd: string) => {
    setEndsAt(nextEnd);
    if (startsAt && nextEnd) {
      const diff = Math.round(
        (new Date(nextEnd).getTime() - new Date(startsAt).getTime()) / 60_000
      );
      if (diff > 0) {
        setDurationMinutes(diff);
      }
    }
  };

  const handleAgendaParsed = (result: ParseAgendaResponse) => {
    const { agenda, model } = result;
    if (agenda.title) {
      setTitle(agenda.title);
    }

    const itemMinutesSum = (agenda.items || []).reduce(
      (sum, item) => sum + (item.minutes || 0),
      0
    );
    const resolvedDuration =
      agenda.duration_minutes ?? (itemMinutesSum > 0 ? itemMinutesSum : 30);
    setDurationMinutes(resolvedDuration);

    let resolvedStartLocal = startsAt;
    if (agenda.starts_at) {
      const converted = toLocalDateTimeInputValue(agenda.starts_at);
      if (converted) {
        resolvedStartLocal = converted;
        setStartsAt(converted);
      }
    } else if (!resolvedStartLocal) {
      const nextHour = new Date();
      nextHour.setMinutes(0, 0, 0);
      nextHour.setHours(nextHour.getHours() + 1);
      resolvedStartLocal = toLocalDateTimeInputValue(nextHour.toISOString());
      setStartsAt(resolvedStartLocal);
    }

    if (resolvedStartLocal && resolvedDuration > 0) {
      const computedEnd = computeEndFromDuration(resolvedStartLocal, resolvedDuration);
      if (computedEnd) {
        setEndsAt(computedEnd);
      }
    }

    const owners = new Set<string>();
    (agenda.items || []).forEach((item) => {
      if (item.owner?.trim()) owners.add(item.owner.trim().toLowerCase());
    });
    (agenda.action_items || []).forEach((act) => {
      if (act.owner?.trim()) owners.add(act.owner.trim().toLowerCase());
    });
    if (owners.size > 0) {
      setAttendeeCount(owners.size);
    }

    setAgendaItems(agenda.items || []);
    setActionItems(agenda.action_items || []);
    setParsedMeta({ language: agenda.language, model });
    setError(null);
  };

  const updateAgendaItem = (idx: number, patch: Partial<AgendaItem>) => {
    setAgendaItems((prev) =>
      prev.map((item, i) => (i === idx ? { ...item, ...patch } : item))
    );
  };

  const removeAgendaItem = (idx: number) => {
    setAgendaItems((prev) => prev.filter((_, i) => i !== idx));
  };

  const addAgendaItem = () => {
    setAgendaItems((prev) => [...prev, { topic: '', owner: null, minutes: null }]);
  };

  const updateActionItem = (idx: number, patch: Partial<ActionItem>) => {
    setActionItems((prev) =>
      prev.map((item, i) => (i === idx ? { ...item, ...patch } : item))
    );
  };

  const removeActionItem = (idx: number) => {
    setActionItems((prev) => prev.filter((_, i) => i !== idx));
  };

  const addActionItem = () => {
    setActionItems((prev) => [...prev, { task: '', owner: null, due: null }]);
  };

  const resetForm = () => {
    setTitle('');
    setStartsAt('');
    setEndsAt('');
    setDurationMinutes('');
    setAttendeeCount(1);
    setAgendaItems([]);
    setActionItems([]);
    setParsedMeta(null);
    setError(null);
    if (onCancelEdit) {
      onCancelEdit();
    }
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError(null);

    const trimmedTitle = title.trim();
    if (!trimmedTitle) {
      setError('Title is required and non-empty.');
      return;
    }

    if (!startsAt || !endsAt) {
      setError('Both start and end dates/times are required.');
      return;
    }

    const startDate = new Date(startsAt);
    const endDate = new Date(endsAt);

    if (isNaN(startDate.getTime()) || isNaN(endDate.getTime())) {
      setError('Invalid date/time format.');
      return;
    }

    if (startDate >= endDate) {
      setError('Start time must be earlier than end time.');
      return;
    }

    const attendees = attendeeCount === '' ? 0 : Number(attendeeCount);
    if (attendees < 0 || !Number.isInteger(attendees)) {
      setError('Attendee count must be a non-negative integer.');
      return;
    }

    setSubmitting(true);
    try {
      const payload = {
        title: trimmedTitle,
        starts_at: startDate.toISOString(),
        ends_at: endDate.toISOString(),
        attendee_count: attendees,
      };

      if (editingMeeting) {
        await updateMeeting(editingMeeting.id, payload, token);
      } else {
        await createMeeting(payload, token);
      }

      resetForm();
      onMeetingCreated();
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : 'Failed to save meeting.');
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <>
      <Card className="shadow-sm">
        <CardHeader>
          <div className="flex items-start justify-between gap-2">
            <div>
              <CardTitle className="text-xl flex items-center gap-2">
                <PlusCircle className="h-5 w-5 text-blue-600" />
                {editingMeeting ? `Edit Meeting #${editingMeeting.id}` : 'Schedule New Meeting'}
              </CardTitle>
              <CardDescription className="mt-1">
                Enter the details below or paste notes to pre-fill with AI.
              </CardDescription>
            </div>
            <Button
              type="button"
              variant="outline"
              size="sm"
              onClick={() => setIsPasteModalOpen(true)}
              disabled={submitting}
              className="shrink-0 border-blue-200 bg-blue-50/70 text-blue-700 hover:bg-blue-100 hover:text-blue-800 font-medium"
            >
              <Sparkles className="h-3.5 w-3.5 mr-1.5 text-blue-600" />
              Paste an agenda
            </Button>
          </div>
        </CardHeader>
        <CardContent>
          {parsedMeta && (
            <div className="mb-4 px-3 py-2 bg-blue-50 border border-blue-200 text-blue-800 rounded-md text-xs flex items-center justify-between">
              <span>
                Pre-filled by AI (<strong>{parsedMeta.language}</strong>) &bull; Review and edit any
                field before saving.
              </span>
              <button
                type="button"
                onClick={() => setParsedMeta(null)}
                className="text-blue-600 hover:text-blue-900 ml-2"
                aria-label="Dismiss AI banner"
              >
                <X className="h-3.5 w-3.5" />
              </button>
            </div>
          )}

          {error && (
            <div className="mb-4 p-3 bg-red-50 border border-red-200 text-red-700 rounded-md text-sm flex items-start gap-2">
              <AlertCircle className="h-4 w-4 mt-0.5 shrink-0" />
              <span>{error}</span>
            </div>
          )}

          <form onSubmit={handleSubmit} className="space-y-4">
            <div className="space-y-1.5">
              <Label htmlFor="title">Meeting Title</Label>
              <Input
                id="title"
                type="text"
                placeholder="e.g. Architecture Review"
                value={title}
                onChange={(e) => setTitle(e.target.value)}
                disabled={submitting}
                required
              />
            </div>

            <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
              <div className="space-y-1.5">
                <Label htmlFor="starts_at">Starts At</Label>
                <Input
                  id="starts_at"
                  type="datetime-local"
                  value={startsAt}
                  onChange={(e) => handleStartsAtChange(e.target.value)}
                  disabled={submitting}
                  required
                />
              </div>

              <div className="space-y-1.5">
                <Label htmlFor="ends_at">Ends At</Label>
                <Input
                  id="ends_at"
                  type="datetime-local"
                  value={endsAt}
                  onChange={(e) => handleEndsAtChange(e.target.value)}
                  disabled={submitting}
                  required
                />
              </div>
            </div>

            <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
              <div className="space-y-1.5">
                <Label htmlFor="duration_minutes">Duration (minutes)</Label>
                <Input
                  id="duration_minutes"
                  type="number"
                  min="1"
                  max="600"
                  step="1"
                  placeholder="e.g. 45"
                  value={durationMinutes}
                  onChange={(e) => handleDurationChange(e.target.value)}
                  disabled={submitting}
                />
              </div>

              <div className="space-y-1.5">
                <Label htmlFor="attendee_count">Attendee Count</Label>
                <Input
                  id="attendee_count"
                  type="number"
                  min="0"
                  step="1"
                  value={attendeeCount}
                  onChange={(e) =>
                    setAttendeeCount(e.target.value === '' ? '' : parseInt(e.target.value, 10))
                  }
                  disabled={submitting}
                  required
                />
              </div>
            </div>

            {/* Agenda Items Section */}
            <div className="space-y-2 pt-2 border-t border-gray-100">
              <div className="flex items-center justify-between">
                <Label className="flex items-center gap-1.5 text-xs font-semibold uppercase tracking-wider text-gray-600">
                  <ListChecks className="h-3.5 w-3.5 text-blue-600" />
                  Agenda Items ({agendaItems.length})
                </Label>
                <button
                  type="button"
                  onClick={addAgendaItem}
                  disabled={submitting}
                  className="text-xs text-blue-600 hover:text-blue-800 font-medium inline-flex items-center gap-1"
                >
                  <Plus className="h-3 w-3" />
                  Add item
                </button>
              </div>

              {agendaItems.map((item, idx) => (
                <div
                  key={idx}
                  className="grid grid-cols-12 gap-2 items-center bg-gray-50 p-2 rounded-md border border-gray-200"
                >
                  <div className="col-span-6">
                    <Input
                      type="text"
                      placeholder="Topic"
                      value={item.topic}
                      onChange={(e) => updateAgendaItem(idx, { topic: e.target.value })}
                      disabled={submitting}
                      className="h-8 text-xs"
                    />
                  </div>
                  <div className="col-span-3">
                    <Input
                      type="text"
                      placeholder="Owner"
                      value={item.owner ?? ''}
                      onChange={(e) =>
                        updateAgendaItem(idx, { owner: e.target.value || null })
                      }
                      disabled={submitting}
                      className="h-8 text-xs"
                    />
                  </div>
                  <div className="col-span-2">
                    <Input
                      type="number"
                      min="1"
                      max="480"
                      placeholder="Min"
                      value={item.minutes ?? ''}
                      onChange={(e) =>
                        updateAgendaItem(idx, {
                          minutes: e.target.value ? parseInt(e.target.value, 10) : null,
                        })
                      }
                      disabled={submitting}
                      className="h-8 text-xs"
                    />
                  </div>
                  <div className="col-span-1 flex justify-end">
                    <button
                      type="button"
                      onClick={() => removeAgendaItem(idx)}
                      disabled={submitting}
                      className="text-gray-400 hover:text-red-600 p-1"
                      aria-label="Remove agenda item"
                    >
                      <Trash2 className="h-3.5 w-3.5" />
                    </button>
                  </div>
                </div>
              ))}
            </div>

            {/* Action Items Section */}
            <div className="space-y-2 pt-2 border-t border-gray-100">
              <div className="flex items-center justify-between">
                <Label className="flex items-center gap-1.5 text-xs font-semibold uppercase tracking-wider text-gray-600">
                  <CheckSquare className="h-3.5 w-3.5 text-indigo-600" />
                  Action Items ({actionItems.length})
                </Label>
                <button
                  type="button"
                  onClick={addActionItem}
                  disabled={submitting}
                  className="text-xs text-blue-600 hover:text-blue-800 font-medium inline-flex items-center gap-1"
                >
                  <Plus className="h-3 w-3" />
                  Add action
                </button>
              </div>

              {actionItems.map((act, idx) => (
                <div
                  key={idx}
                  className="grid grid-cols-12 gap-2 items-center bg-gray-50 p-2 rounded-md border border-gray-200"
                >
                  <div className="col-span-5">
                    <Input
                      type="text"
                      placeholder="Task"
                      value={act.task}
                      onChange={(e) => updateActionItem(idx, { task: e.target.value })}
                      disabled={submitting}
                      className="h-8 text-xs"
                    />
                  </div>
                  <div className="col-span-3">
                    <Input
                      type="text"
                      placeholder="Owner"
                      value={act.owner ?? ''}
                      onChange={(e) =>
                        updateActionItem(idx, { owner: e.target.value || null })
                      }
                      disabled={submitting}
                      className="h-8 text-xs"
                    />
                  </div>
                  <div className="col-span-3">
                    <Input
                      type="date"
                      value={act.due ?? ''}
                      onChange={(e) =>
                        updateActionItem(idx, { due: e.target.value || null })
                      }
                      disabled={submitting}
                      className="h-8 text-xs"
                    />
                  </div>
                  <div className="col-span-1 flex justify-end">
                    <button
                      type="button"
                      onClick={() => removeActionItem(idx)}
                      disabled={submitting}
                      className="text-gray-400 hover:text-red-600 p-1"
                      aria-label="Remove action item"
                    >
                      <Trash2 className="h-3.5 w-3.5" />
                    </button>
                  </div>
                </div>
              ))}
            </div>

            <div className="flex items-center gap-2 pt-2">
              {editingMeeting && (
                <Button
                  type="button"
                  variant="outline"
                  className="w-1/3"
                  onClick={resetForm}
                  disabled={submitting}
                >
                  Cancel
                </Button>
              )}
              <Button type="submit" className="flex-1" disabled={submitting}>
                {submitting ? (
                  <>
                    <Loader2 className="mr-2 h-4 w-4 animate-spin" />
                    Saving...
                  </>
                ) : editingMeeting ? (
                  'Save Changes'
                ) : (
                  'Create Meeting'
                )}
              </Button>
            </div>
          </form>
        </CardContent>
      </Card>

      <PasteAgendaModal
        isOpen={isPasteModalOpen}
        onClose={() => setIsPasteModalOpen(false)}
        onParsed={handleAgendaParsed}
        token={token}
      />
    </>
  );
};
