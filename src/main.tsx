import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { BrowserRouter } from 'react-router-dom';
import { AuthProvider } from './contexts/AuthContext';
import { PermissionProvider } from './contexts/PermissionContext';
import { ErrorBoundary } from './components/shared/ErrorBoundary';
import { installStaleBuildNotice } from './lib/staleBuild';
import './assets/style.css';
import App from './App';

/* Before React, because the thing it watches for is a CHUNK failing to load --
 * which can happen to the app shell itself, at a moment when mounting a
 * component to say so is the one thing that may not work. */
installStaleBuildNotice();

/**
 * Provider hierarchy (order matters):
 *
 *  ErrorBoundary          — top-level catch-all (prevents blank screen on provider crash)
 *   └─ BrowserRouter      — routing context
 *       └─ AuthProvider   — who the user is (session, profile, roles)
 *           └─ PermissionProvider  — what the user can do (can / canAny / canAll)
 *               └─ App    — the application
 *
 * PermissionProvider must be INSIDE AuthProvider because it calls useAuth()
 * to read the current user and wait for profileLoading to settle before
 * fetching permissions.
 */
createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <ErrorBoundary scope="app" heading="Application Error">
      <BrowserRouter>
        <AuthProvider>
          <PermissionProvider>
            <App />
          </PermissionProvider>
        </AuthProvider>
      </BrowserRouter>
    </ErrorBoundary>
  </StrictMode>,
);
