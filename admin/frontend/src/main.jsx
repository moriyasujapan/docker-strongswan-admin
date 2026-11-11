import React from 'react';
import { createRoot } from 'react-dom/client';
import { Theme } from '@astryxdesign/core/theme';
import { neutralTheme } from '@astryxdesign/theme-neutral/built';
import './globals.css';
import App from './App.jsx';

// URLに埋め込まれた認証情報は、履歴やブックマークに残らないよう除去する (認証済みのBasic認証はブラウザが保持)
if (window.location.username || window.location.password) {
  const u = new URL(window.location.href);
  u.username = ''; u.password = '';
  window.history.replaceState(null, '', u.toString());
}

createRoot(document.getElementById('root')).render(
  <Theme theme={neutralTheme}>
    <App />
  </Theme>,
);
