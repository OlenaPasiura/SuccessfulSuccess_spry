import React, { useState } from 'react';
import { createMeeting } from '@/api/meetings';
import { Button } from './ui/button';
import { Input } from './ui/input';
import { Label } from './ui/label';
import { Card, CardHeader, CardTitle, CardDescription, CardContent } from './ui/card';
import { PlusCircle, AlertCircle, Loader2 } from 'lucide-react';

interface MeetingFormProps {
  onMeetingCreated: () => void;
}

export const MeetingForm: React.FC<MeetingFormProps> = ({ onMeetingCreated }) => {
  const [title, setTitle] = useState('');
  const [startsAt, setStartsAt] = useState('');
  const [endsAt, setEndsAt] = useState('');
  const [attendeeCount, setAttendeeCount] = useState<number | ''>(1);
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

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
      await createMeeting({
        title: trimmedTitle,
        starts_at: startDate.toISOString(),
        ends_at: endDate.toISOString(),
        attendee_count: attendees,
      });

      // Clear form on success
      setTitle('');
      setStartsAt('');
      setEndsAt('');
      setAttendeeCount(1);
      setError(null);
      onMeetingCreated();
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : 'Failed to schedule meeting.');
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <Card className="shadow-sm">
      <CardHeader>
        <CardTitle className="text-xl flex items-center gap-2">
          <PlusCircle className="h-5 w-5 text-blue-600" />
          Schedule New Meeting
        </CardTitle>
        <CardDescription>Enter the details below to add a meeting to the schedule.</CardDescription>
      </CardHeader>
      <CardContent>
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
                onChange={(e) => setStartsAt(e.target.value)}
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
                onChange={(e) => setEndsAt(e.target.value)}
                disabled={submitting}
                required
              />
            </div>
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

          <Button type="submit" className="w-full" disabled={submitting}>
            {submitting ? (
              <>
                <Loader2 className="mr-2 h-4 w-4 animate-spin" />
                Scheduling...
              </>
            ) : (
              'Create Meeting'
            )}
          </Button>
        </form>
      </CardContent>
    </Card>
  );
};
