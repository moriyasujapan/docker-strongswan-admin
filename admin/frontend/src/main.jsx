import React from 'react';
import { createRoot } from 'react-dom/client';
import { Theme } from '@astryxdesign/core/theme';
import { neutralTheme } from '@astryxdesign/theme-neutral/built';
import './globals.css';
import App from './App.jsx';

createRoot(document.getElementById('root')).render(
  <Theme theme={neutralTheme}>
    <App />
  </Theme>,
);
