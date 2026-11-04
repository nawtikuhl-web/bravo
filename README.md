# Bravo Outsourcing website

Flat HTML site for bravo-os.com. Hosted on Netlify (site `bravo-os`, deploys from the `main` branch of this repo). The careers page reads from and writes to Supabase.

- Pages are plain `.html` files at the root. Shared styles live in `assets/site.css`.
- `enquiry.html` posts to Netlify Forms.
- `careers.html` lists published roles from Supabase and saves applications (with an optional CV) to Supabase.
- `careers-admin.html` is the people team's admin for roles and applications. It is public to load but everything behind it needs an admin sign-in.

## Careers data (Supabase)

Project: `bravo` (`qykzxwhxxnvradnyxvqk`). Schema is in `supabase/migrations/`; apply changes with `supabase db push`.

- `jobs`: one row per role. Only `status = 'published'` rows show on the site (via the `public_jobs` view). Refs like `BR-1042` are assigned automatically.
- `applications`: one row per application. `job_id` is null for "register your interest". CVs go in the private `cvs` storage bucket.
- `admin_allowlist`: emails allowed into the admin. Adding an email here (or from the Team tab in the admin) lets that person sign in with a magic link; removing it revokes access.

`config.js` holds the Supabase URL and the publishable (anon) key. That key is public by design: row-level security limits it to reading published jobs and inserting applications. Never put the service-role key in the site.

## Admin sign-in

Open `/careers-admin.html`, type your email and choose "Email me a sign-in link". Once in, you can set a password from the Team tab. Auth redirect URLs are set in `supabase/config.toml` and pushed with `supabase config push`.

## Local preview

```bash
python3 -m http.server 8888
```

Then open http://localhost:8888/careers.html. The local address is on the Supabase redirect allowlist, so admin sign-in links work locally too.
