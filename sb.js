// All Supabase access for the Bravo site. Load after supabase-js and config.js.
// Public pages only ever read published jobs and insert applications; everything else needs an admin session.

// Captured before the client consumes the URL hash, so the admin page knows it came from a recovery or invite link.
var AUTH_LINK_TYPE = new URLSearchParams(location.hash.slice(1)).get('type');
var sb = supabase.createClient(BRAVO_CONFIG.SB_URL, BRAVO_CONFIG.SB_ANON);

function must(r) { if (r.error) throw r.error; return r.data; }

// ---------- public site ----------
async function fetchPublicJobs() {
  return must(await sb.from('public_jobs').select('*').order('published_at', { ascending: false })) || [];
}

// Upload the CV (if any) then insert the application. The id is made here because anon can insert but not read back.
async function submitApplication(app, file) {
  var id = crypto.randomUUID(), cv_path = null;
  if (file) {
    var ext = (file.name.match(/\.(pdf|docx?)$/i) || ['.pdf'])[0].toLowerCase();
    cv_path = id + '/cv' + ext;
    must(await sb.storage.from('cvs').upload(cv_path, file, { contentType: file.type || undefined, upsert: false }));
  }
  must(await sb.from('applications').insert(Object.assign({ id: id, cv_path: cv_path }, app)));
}

// ---------- admin: auth ----------
// Returns the admin_users row for the signed-in user, null when signed out, false when signed in but not an admin.
async function currentAdmin() {
  var s = must(await sb.auth.getSession()).session;
  if (!s) return null;
  var me = must(await sb.from('admin_users').select('*').eq('id', s.user.id).maybeSingle());
  return me || false;
}
async function sendMagicLink(email) {
  must(await sb.auth.signInWithOtp({ email: email, options: { emailRedirectTo: location.origin + location.pathname } }));
}
async function signInWithPassword(email, password) {
  must(await sb.auth.signInWithPassword({ email: email, password: password }));
}
async function sendPasswordReset(email) {
  must(await sb.auth.resetPasswordForEmail(email, { redirectTo: location.origin + location.pathname }));
}
async function setPassword(password) { must(await sb.auth.updateUser({ password: password })); }
async function signOut() { await sb.auth.signOut(); }

// ---------- admin: jobs ----------
async function adminListJobs() {
  var res = await Promise.all([
    sb.from('jobs').select('*').order('created_at', { ascending: false }),
    sb.from('job_application_counts').select('*'),
  ]);
  var jobs = must(res[0]) || [], counts = must(res[1]) || [], by = {};
  counts.forEach(function (c) { by[c.job_id] = c; });
  return jobs.map(function (j) { j.apps = by[j.id] ? by[j.id].total : 0; j.newApps = by[j.id] ? by[j.id].new_count : 0; return j; });
}
async function adminSaveJob(row) {
  var id = row.id, rest = Object.assign({}, row);
  delete rest.id; delete rest.apps; delete rest.newApps; delete rest.created_at; delete rest.updated_at; delete rest.published_at; delete rest.ref;
  return id
    ? must(await sb.from('jobs').update(rest).eq('id', id).select().single())
    : must(await sb.from('jobs').insert(rest).select().single());
}
async function adminDeleteJob(id) { must(await sb.from('jobs').delete().eq('id', id)); }

// ---------- admin: applications ----------
async function adminListApplications() {
  return must(await sb.from('applications').select('*').order('created_at', { ascending: false }).limit(1000)) || [];
}
async function adminUpdateApplication(id, patch) {
  return must(await sb.from('applications').update(patch).eq('id', id).select().single());
}
async function adminDeleteApplication(app) {
  if (app.cv_path) await sb.storage.from('cvs').remove([app.cv_path]);
  must(await sb.from('applications').delete().eq('id', app.id));
}
async function adminCvUrl(path) {
  return must(await sb.storage.from('cvs').createSignedUrl(path, 300)).signedUrl;
}

// ---------- admin: team ----------
async function adminListTeam() {
  var res = await Promise.all([
    sb.from('admin_allowlist').select('*').order('added_at'),
    sb.from('admin_users').select('email'),
  ]);
  var allow = must(res[0]) || [], joined = {};
  (must(res[1]) || []).forEach(function (u) { joined[u.email.toLowerCase()] = true; });
  return allow.map(function (a) { a.joined = !!joined[a.email.toLowerCase()]; return a; });
}
async function adminAddTeam(email, full_name) {
  must(await sb.from('admin_allowlist').insert({ email: email.trim().toLowerCase(), full_name: full_name || null }));
}
async function adminRemoveTeam(email) { must(await sb.from('admin_allowlist').delete().eq('email', email)); }
