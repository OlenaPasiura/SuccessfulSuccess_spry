import React, { useState, useEffect, useCallback } from 'react';
import { Meeting, fetchMeetings } from '@/api/meetings';
import { MeetingForm } from '@/components/MeetingForm';
import { MeetingList } from '@/components/MeetingList';
import { CalendarCheck2 } from 'lucide-react';

export const App: React.FC = () => {
  const [meetings, setMeetings] = useState<Meeting[]>([]);
  const [isLoading, setIsLoading] = useState<boolean>(true);
  const [error, setError] = useState<string | null>(null);

  const loadMeetings = useCallback(async () => {
    setIsLoading(true);
    setError(null);
    try {
      const data = await fetchMeetings();
      setMeetings(data);
    } catch (err: any) {
      setError(err.message || 'Unable to connect to meetings service.');
    } finally {
      setIsLoading(false);
    }
  }, []);

  useEffect(() => {
    loadMeetings();
  }, [loadMeetings]);

  return (
    <div className="min-h-screen bg-gray-50 flex flex-col">
      {/* Top Navigation / Header */}
      <header className="bg-white border-b border-gray-200 sticky top-0 z-10">
        <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 h-16 flex items-center justify-between">
          <div className="flex items-center gap-2.5">
            <div className="h-9 w-9 rounded-lg bg-blue-600 flex items-center justify-center text-white shadow-sm">
              <CalendarCheck2 className="h-5 w-5" />
            </div>
            <div>
              <h1 className="text-lg font-bold text-gray-900 leading-tight">
                SuccessfulSuccess
              </h1>
              <p className="text-xs text-gray-500 font-mono">spry</p>
            </div>
          </div>
          <span className="text-xs px-2.5 py-1 bg-green-50 text-green-700 border border-green-200 rounded-full font-medium">
            Active
          </span>
        </div>
      </header>

      {/* Main Content */}
      <main className="flex-1 max-w-7xl w-full mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <div className="grid grid-cols-1 lg:grid-cols-12 gap-8 items-start">
          {/* Meeting Creation Form */}
          <div className="lg:col-span-5">
            <div className="sticky top-24">
              <MeetingForm onMeetingCreated={loadMeetings} />
            </div>
          </div>

          {/* Meeting List */}
          <div className="lg:col-span-7">
            <MeetingList
              meetings={meetings}
              isLoading={isLoading}
              error={error}
              onRetry={loadMeetings}
            />
          </div>
        </div>
      </main>

      {/* Footer */}
      <footer className="bg-white border-t border-gray-200 py-4 text-center text-xs text-gray-500">
        SuccessfulSuccess_spry &bull; Monorepo Meeting Manager
      </footer>
    </div>
  );
};

export default App;
