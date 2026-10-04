# Rupkas — Rupiah Kas

Fresh Rupkas implementation based on the approved Rupkas PRD Master v1.0.

## Stack
- React + TypeScript + Vite
- Supabase Auth + PostgreSQL + RLS + RPC
- PWA + IndexedDB guest/local persistence
- IDR / Asia-Jakarta defaults

## Backend
Supabase project: `slmwoczmrplhypurkgvx` (Singapore).

## Local setup
```bash
npm install
cp .env.example .env.local
npm run dev
```

Never commit `.env.local` or service-role credentials.
