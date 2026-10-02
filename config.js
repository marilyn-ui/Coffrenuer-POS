// Public values only. The anon key is safe in the browser because row level security protects the data.
// NEVER put the service_role key here. It belongs only in Vercel environment variables.
window.COFFRENUER_CONFIG = {
  SUPABASE_URL: "https://YOUR-PROJECT.supabase.co",
  SUPABASE_ANON_KEY: "YOUR-ANON-KEY"
};
