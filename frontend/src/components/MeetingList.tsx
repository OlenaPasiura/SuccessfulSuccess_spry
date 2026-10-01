import React from 'react';
import { Meeting } from '@/api/meetings';
import { Card, CardHeader, CardTitle, CardContent } from './ui/card';
import { Button } from './ui/button';
import { Calendar, Clock, Users, AlertCircle, RefreshCw, Loader2 } from 'lucide-react';

interface MeetingListProps {
  meetings: Meeting[];
  isLoading: boolean;
  error: string | null;
  onRetry: () => void;
}

function formatMeetingDateTime(isoString: string): string {
  try {
    const d = new Date(isoString);
    if (isNaN(d.getTime())) return isoString;
    return new Intl.DateTimeFormat(undefined, {
      month: 'short',
      day: 'numeric',
      year: 'numeric',
      hour: '2-digit',
      minute: '2-digit',
    }).format(d);
  } catch {
    return isoString;
  }
}

export const MeetingList: React.FC<MeetingListProps> = ({
  meetings,
  isLoading,
  error,
  onRetry,
}) => {
  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <div>
          <h2 className="text-xl font-bold tracking-tight text-gray-900">
            Scheduled Meetings
          </h2>
          <p className="text-sm text-gray-500">
            View all current meetings and participants
          </p>
        </div>
        <Button
          variant="outline"
          size="sm"
          onClick={onRetry}
          disabled={isLoading}
          className="flex items-center gap-1.5 text-gray-600 hover:text-gray-900"
        >
          <RefreshCw className={`h-3.5 w-3.5 ${isLoading ? 'animate-spin' : ''}`} />
          Refresh
        </Button>
      </div>

      {isLoading && meetings.length === 0 && (
        <Card className="p-8 text-center bg-white border-dashed">
          <div className="flex flex-col items-center justify-center space-y-3">
            <Loader2 className="h-8 w-8 animate-spin text-blue-600" />
            <p className="text-sm text-gray-500">Connecting to meetings service...</p>
          </div>
        </Card>
      )}

      {error && (
        <Card className="border-red-200 bg-red-50 p-4">
          <div className="flex items-start justify-between">
            <div className="flex items-start gap-3">
              <AlertCircle className="h-5 w-5 text-red-600 mt-0.5 shrink-0" />
              <div>
                <h4 className="text-sm font-semibold text-red-800">
                  Unable to load meetings
                </h4>
                <p className="text-sm text-red-700 mt-1">{error}</p>
              </div>
            </div>
            <Button
              variant="outline"
              size="sm"
              onClick={onRetry}
              className="border-red-300 text-red-800 hover:bg-red-100"
            >
              Retry
            </Button>
          </div>
        </Card>
      )}

      {!isLoading && !error && meetings.length === 0 && (
        <Card className="p-12 text-center bg-white border-dashed">
          <div className="flex flex-col items-center justify-center space-y-3">
            <div className="h-12 w-12 rounded-full bg-blue-50 flex items-center justify-center text-blue-600">
              <Calendar className="h-6 w-6" />
            </div>
            <h3 className="text-base font-medium text-gray-900">
              No meetings scheduled yet
            </h3>
            <p className="text-sm text-gray-500 max-w-sm">
              Use the form on the left to schedule your first meeting.
            </p>
          </div>
        </Card>
      )}

      <div className="grid grid-cols-1 gap-3">
        {meetings.map((meeting) => (
          <Card key={meeting.id} className="hover:shadow-md transition-shadow">
            <CardHeader className="py-4 px-5">
              <div className="flex items-start justify-between gap-4">
                <CardTitle className="text-base font-semibold text-gray-900">
                  {meeting.title}
                </CardTitle>
                <span className="inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full text-xs font-medium bg-blue-50 text-blue-700 border border-blue-200 shrink-0">
                  <Users className="h-3.5 w-3.5" />
                  {meeting.attendee_count} {meeting.attendee_count === 1 ? 'attendee' : 'attendees'}
                </span>
              </div>
            </CardHeader>
            <CardContent className="py-2 px-5 pb-4 text-sm text-gray-600 border-t border-gray-100 bg-gray-50/50 rounded-b-lg flex flex-wrap items-center gap-4">
              <div className="flex items-center gap-1.5">
                <Clock className="h-4 w-4 text-gray-400" />
                <span>
                  {formatMeetingDateTime(meeting.starts_at)} &ndash; {formatMeetingDateTime(meeting.ends_at)}
                </span>
              </div>
              <span className="text-xs text-gray-400 ml-auto font-mono">
                #{meeting.id}
              </span>
            </CardContent>
          </Card>
        ))}
      </div>
    </div>
  );
};
