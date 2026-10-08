import { AuthProviderProps, AuthContextProps } from 'react-oidc-context';
import { WebStorageStateStore } from 'oidc-client-ts';

const cognitoRegion = import.meta.env.VITE_COGNITO_REGION || 'us-east-1';
const userPoolId = import.meta.env.VITE_COGNITO_USER_POOL_ID || '';
const clientId = import.meta.env.VITE_COGNITO_CLIENT_ID || '';
const redirectUri = import.meta.env.VITE_COGNITO_REDIRECT_URI || `${window.location.origin}/`;

export const cognitoAuthConfig: AuthProviderProps = {
  authority: `https://cognito-idp.${cognitoRegion}.amazonaws.com/${userPoolId}`,
  client_id: clientId,
  redirect_uri: redirectUri,
  response_type: 'code',
  scope: 'openid email profile',
  userStore: new WebStorageStateStore({ store: window.localStorage }),
  onSigninCallback: () => {
    window.history.replaceState({}, document.title, window.location.pathname);
  },
};

export const signOut = async (auth: AuthContextProps) => {
  await auth.removeUser();
  const domain = import.meta.env.VITE_COGNITO_DOMAIN || '';
  const currentClientId = import.meta.env.VITE_COGNITO_CLIENT_ID || '';
  const appUrl = import.meta.env.VITE_COGNITO_REDIRECT_URI || `${window.location.origin}/`;

  if (domain && currentClientId) {
    const logoutUrl = `https://${domain}/logout?client_id=${encodeURIComponent(currentClientId)}&logout_uri=${encodeURIComponent(appUrl)}`;
    window.location.href = logoutUrl;
  } else {
    window.location.href = appUrl;
  }
};

export const signInWithGoogle = async (auth: AuthContextProps) => {
  await auth.signinRedirect({
    extraQueryParams: {
      identity_provider: 'Google',
    },
  });
};
