import React from 'react';
import { useAuth } from 'react-oidc-context';
import { CalendarCheck2, LogIn, LogOut, User as UserIcon, Loader2 } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { signOut, signInWithGoogle } from '@/lib/auth';

interface HeaderProps {
  onNavigateLogin?: () => void;
}

export const Header: React.FC<HeaderProps> = ({ onNavigateLogin }) => {
  const auth = useAuth();

  const handleSignIn = () => {
    if (onNavigateLogin) {
      onNavigateLogin();
    } else {
      auth.signinRedirect().catch((err) => {
        console.error('Failed to redirect to sign-in:', err);
      });
    }
  };

  const handleGoogleSignIn = () => {
    signInWithGoogle(auth).catch((err) => {
      console.error('Failed to redirect to Google sign-in:', err);
    });
  };

  const handleSignOut = () => {
    signOut(auth).catch((err) => {
      console.error('Failed to sign out:', err);
    });
  };

  return (
    <header className="bg-white border-b border-gray-200 sticky top-0 z-10 shadow-sm">
      <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 h-16 flex items-center justify-between">
        {/* Logo and Brand */}
        <div className="flex items-center gap-2.5">
          <div className="h-9 w-9 rounded-lg bg-blue-600 flex items-center justify-center text-white shadow-sm">
            <CalendarCheck2 className="h-5 w-5" />
          </div>
          <div>
            <h1 className="text-lg font-bold text-gray-900 leading-tight">SuccessfulSuccess</h1>
            <p className="text-xs text-gray-500 font-mono">spry &bull; Lab 3</p>
          </div>
        </div>

        {/* Auth Section */}
        <div className="flex items-center gap-3">
          {auth.isLoading ? (
            <div className="flex items-center gap-2 text-sm text-gray-500">
              <Loader2 className="h-4 w-4 animate-spin text-blue-600" />
              <span className="hidden sm:inline">Checking auth...</span>
            </div>
          ) : auth.isAuthenticated ? (
            <div className="flex items-center gap-3">
              <div className="flex items-center gap-2 px-3 py-1.5 bg-gray-50 border border-gray-200 rounded-full text-xs font-medium text-gray-700">
                <div className="h-6 w-6 rounded-full bg-blue-100 text-blue-700 flex items-center justify-center">
                  <UserIcon className="h-3.5 w-3.5" />
                </div>
                <span className="max-w-[180px] sm:max-w-[240px] truncate">
                  {auth.user?.profile?.email || auth.user?.profile?.name || 'User'}
                </span>
              </div>
              <Button
                variant="outline"
                size="sm"
                onClick={handleSignOut}
                className="text-red-600 border-red-200 hover:bg-red-50 hover:text-red-700"
              >
                <LogOut className="h-3.5 w-3.5 mr-1.5" />
                Sign out
              </Button>
            </div>
          ) : (
            <div className="flex items-center gap-2">
              <Button
                variant="outline"
                size="sm"
                onClick={handleGoogleSignIn}
                className="hidden sm:inline-flex items-center gap-1.5 border-gray-300 hover:bg-gray-50"
              >
                <svg className="w-3.5 h-3.5" viewBox="0 0 24 24">
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
              <Button size="sm" onClick={handleSignIn} className="bg-blue-600 hover:bg-blue-700">
                <LogIn className="h-3.5 w-3.5 mr-1.5" />
                Sign in
              </Button>
            </div>
          )}
        </div>
      </div>
    </header>
  );
};
