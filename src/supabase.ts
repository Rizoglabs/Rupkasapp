import { createClient } from '@supabase/supabase-js';

const supabaseUrl=import.meta.env.VITE_SUPABASE_URL;
const supabaseKey=import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY||import.meta.env.VITE_SUPABASE_ANON_KEY;

if(!supabaseUrl||!supabaseKey){
  throw new Error('Rupkas Supabase configuration is missing.');
}

export const db=createClient(supabaseUrl,supabaseKey);
