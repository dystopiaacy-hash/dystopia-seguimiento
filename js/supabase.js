/* Cliente único de Supabase.
   supabase-js se carga igual que en Dystopia: <script> UMD de jsdelivr (@supabase/supabase-js@2)
   en el HTML, antes de los módulos. Acá solo se crea el cliente sobre window.supabase. */
import { SUPABASE_URL, SUPABASE_KEY } from './config.js';

if (!window.supabase || !window.supabase.createClient) {
  throw new Error('supabase-js no cargó (revisar el <script> de jsdelivr en el HTML).');
}

export const sb = window.supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
