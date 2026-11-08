# 3D Prints

A small web app for a home 3D printer: a print queue, saved models for later, a history of finished prints and a shelf of filament spools. Two people can share one workshop and see each other's changes live.

- **Queue** with print time and cost per model, and a warning when a spool runs short.
- **How much time do you have?** picks the queued prints that fit before a given time.
- **New model** reads time, filament weight, colour and a preview from a sliced 3MF or G-code file.
- **Spools** track grams left; marking a print as done subtracts its filament.

It is a single `index.html` with no build step. Data, sign-in and photos live in [Supabase](https://supabase.com); the page is hosted on GitHub Pages.

## Setup

1. **Database.** In a Supabase project, open the SQL Editor and run [`supabase/schema.sql`](supabase/schema.sql). It creates the tables, row level security, the RPC functions, realtime and the `model-images` storage bucket.
2. **Secrets.** In this repository go to *Settings → Secrets and variables → Actions* and add:
   - `SUPABASE_URL`: the project URL, e.g. `https://your-project-ref.supabase.co`
   - `SUPABASE_KEY`: the **publishable** (anon) key. Never use the `service_role` or secret key.
3. **Pages.** In *Settings → Pages*, set *Source* to **GitHub Actions**. Every push to `main` deploys the site; you can also run the *Deploy to GitHub Pages* workflow by hand.
4. **Auth redirects.** In Supabase, *Authentication → URL Configuration*: set *Site URL* to the Pages address and add `https://<user>.github.io/<repo>/**` to *Redirect URLs*.

The deploy workflow writes `config.js` from the secrets, so no keys are stored in the repository. Without it, the app asks for the URL and key on first launch and remembers them on that device.

## Local development

```sh
cp config.example.js config.js   # fill in your project values
python3 -m http.server 8000
```

Open <http://localhost:8000>, or <http://localhost:8000/?demo> for example data that is never saved.
