import React from 'react';
import { createRoot } from 'react-dom/client';
import App from './App';
import './family-modal-fix';
import '@fontsource-variable/material-symbols-rounded/wght.css';
import './styles.css';

function registerServiceWorker(){
  if(!('serviceWorker' in navigator))return;
  window.addEventListener('load',()=>{
    navigator.serviceWorker.register(`${import.meta.env.BASE_URL}sw.js`).catch(()=>{});
  });
}
registerServiceWorker();

createRoot(document.getElementById('root')!).render(
  <React.StrictMode><App /></React.StrictMode>
);
