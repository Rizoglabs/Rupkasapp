import React from 'react';
import { createRoot } from 'react-dom/client';
import App from './App';
import './styles.css';

function registerServiceWorker() {
  if (!('serviceWorker' in navigator)) return;
  window.addEventListener('load', () => {
    navigator.serviceWorker.register('/sw.js').catch(() => {});
  });
}
registerServiceWorker();

createRoot(document.getElementById('root')!).render(
  <React.StrictMode><App /></React.StrictMode>
);
