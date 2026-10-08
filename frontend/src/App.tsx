import React, { useState, useEffect, useCallback } from 'react';
import { useAuth } from 'react-oidc-context';
import { Meeting, fetchMeetings } from '@/api/meetings';
import { Header } from '@/components/Header';
import { LoginPage } from '@/components/LoginPage';
import { MeetingForm } from '@/components/MeetingForm';
import { MeetingList } from '@/components/MeetingList';
import { Button } from '@/components/ui/button';
import { signInWithGoogle } from '@/lib/auth';
import { AlertCircle, Loader2, LogIn, Sparkles } from 'lucide-react';

export const App: React.FC = () => {
  const auth = useAuth();
  const [currentPath, setCurrentPath] = useState<string>(() => window.location.pathname);
  const [meetings, setMeetings] = useState<Meeting[]>([]);
  const [isLoading, setIsLoading] = useState<boolean>(true);
  const [error, setError] = useState<string | null>(null);
  const [authErrorDismissed, setAuthErrorDismissed] = useState<boolean>(false);

  // Sync client-side route
  useEffect(() => {
    const handlePopState = () => {
      setCurrentPath(window.location.pathname);
    };
    window.addEventListener('popstate', handlePopState);
    return () => {
      window.removeEventListener('popstate', handlePopState);
    };
  }, []);

  const navigate = (path: string) => {
    window.history.pushState({}, '', path);
    setCurrentPath(path);
  };

  const accessToken = auth.user?.access_token;

  const loadMeetings = useCallback(async () => {
    setIsLoading(true);
    setError(null);
    try {
      const data = await fetchMeetings(accessToken);
      setMeetings(data);
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : 'Unable to connect to meetings service.');
    } finally {
      setIsLoading(false);
    }
  }, [accessToken]);

  useEffect(() => {
    let ignore = false;
    async function init() {
      try {
        const data = await fetchMeetings(accessToken);
        if (!ignore) {
          setMeetings(data);
        }
      } catch (err: unknown) {
        if (!ignore) {
          setError(err instanceof Error ? err.message : 'Unable to connect to meetings service.');
        }
      } finally {
        if (!ignore) {
          setIsLoading(false);
        }
      }
    }
    init();
    return () => {
      ignore = true;
    };
  }, [accessToken]);

  // If user navigated to /login, render the dedicated LoginPage
  if (currentPath === '/login') {
    return <LoginPage onBackToApp={() => navigate('/')} />;
  }

  return (
    <div className="min-h-screen bg-gray-50 flex flex-col">
      {/* Top Navigation / Header */}
      <Header onNavigateLogin={() => navigate('/login')} />

      {/* Auth Callback In-Progress Banner */}
      {auth.isLoading && (
        <div className="bg-blue-50 border-b border-blue-200 px-4 py-2.5 text-sm text-blue-800 flex items-center justify-center gap-2">
          <Loader2 className="h-4 w-4 animate-spin text-blue-600" />
          <span>Verifying authentication tokens with Cognito...</span>
        </div>
      )}

      {/* Auth Error Banner */}
      {auth.error && !authErrorDismissed && (
        <div className="bg-red-50 border-b border-red-200 px-4 py-2.5 text-sm text-red-800 flex items-center justify-between">
          <div className="flex items-center gap-2">
            <AlertCircle className="h-4 w-4 text-red-600 flex-shrink-0" />
            <span>Authentication error: {auth.error.message}</span>
          </div>
          <button
            onClick={() => setAuthErrorDismissed(true)}
            className="text-xs text-red-600 hover:text-red-800 font-medium ml-4 underline"
          >
            Dismiss
          </button>
        </div>
      )}

      {/* Main Content */}
      <main className="flex-1 max-w-7xl w-full mx-auto px-4 sm:px-6 lg:px-8 py-8">
        {/* Welcome / Sign-in Callout if not authenticated */}
        {!auth.isAuthenticated && !auth.isLoading && (
          <div className="mb-8 p-6 bg-gradient-to-r from-blue-600 to-indigo-700 rounded-xl text-white shadow-sm flex flex-col sm:flex-row items-start sm:items-center justify-between gap-4">
            <div>
              <div className="flex items-center gap-2 mb-1">
                <Sparkles className="h-5 w-5 text-yellow-300" />
                <h2 className="text-lg font-bold">Sign in with Cognito or Google</h2>
              </div>
              <p className="text-sm text-blue-100 max-w-2xl">
                Sign in to manage and schedule meetings. Supports email/password or seamless Google
                OAuth 2.0.
              </p>
            </div>
            <div className="flex items-center gap-2.5 flex-shrink-0">
              <Button
                variant="outline"
                size="sm"
                onClick={() => signInWithGoogle(auth)}
                className="bg-white text-gray-800 hover:bg-gray-100 border-none font-medium"
              >
                <svg className="w-4 h-4 mr-1.5" viewBox="0 0 24 24">
                  <path
                    fill="#4285F4"
                    d="M22.56 12.25c0-.78-.07-1.53-.2-2.25H12v4.26h5.92c-.26 1.37-1.04 2.53-2.21 3.31v2.77h3.57c2.08-1.92 3.28-4.74 3.28-8.09z"
                  />
                  <path
                    fill="#34A853"
                    d="M12 23c2.97 0 5.46-.98 7.28-2.66l-3.57-2.77c-.98.66-2.23 1.06-3.71 1.06-2.86 0-5.29-1.93-6.16-4.53H2.18v2.84C3.99 20.53 7.7 23 12 23z"
                  />
                  <path
                    fill="#FBBC05"
                    d="M5.84 14.09c-.22-.66-.35-1.36-.35-2.09s.13-1.43.35-2.09V7.06H2.18C1.43 8.55 1 10.22 1 12s.43 3.45 1.18 4.94l2.85-2.22.81-.63z"
                  />
                  <path
                    fill="#EA4335"
                    d="M12 5.38c1.62 0 3.06.56 4.21 1.64l3.15-3.15C17.45 2.09 14.97 1 12 1 7.7 1 3.99 3.47 2.18 7.06l3.66 2.84c.87-2.6 3.3-4.52 6.16-4.52z"
                  />
                </svg>
                Google
              </Button>
              <Button
                size="sm"
                onClick={() => auth.signinRedirect()}
                className="bg-blue-900 hover:bg-blue-950 text-white font-medium"
              >
                <LogIn className="h-4 w-4 mr-1.5" />
                Sign in
              </Button>
            </div>
          </div>
        )}

        <div className="grid grid-cols-1 lg:grid-cols-12 gap-8 items-start">
          {/* Meeting Creation Form */}
          <div className="lg:col-span-5">
            <div className="sticky top-24">
              <MeetingForm onMeetingCreated={loadMeetings} token={auth.user?.access_token} />
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
