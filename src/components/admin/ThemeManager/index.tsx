/**
 * ThemeManager — admin page for all branding & landing page configuration.
 *
 * Tabs:
 *  1. Login Page     — logo, card logo, tagline, app name, favicon
 *  2. Landing Page   — hero banner image, illustrated graphic image, nav logo
 *  3. Announcements  — CRUD list + 5-step Create/Edit Banner wizard
 *  4. Manage Layout  — drag-and-drop skeleton to reorder landing page sections
 */

import { useState, useEffect, useRef } from 'react';
import { useNavigate } from 'react-router-dom';
import { supabase } from '../../../lib/supabase';
import './ThemeManager.css';

// ── Types ─────────────────────────────────────────────────────────────────────

interface ThemeSettings {
  login_brand_logo:      string | null;
  login_card_logo:       string | null;
  nav_logo:              string | null;
  favicon:               string | null;
  login_tagline:         string | null;
  app_name:              string | null;
  landing_hero_image:    string | null;
  landing_graphic_image: string | null;
  profile_hero_image:    string | null;
  profile_sections:      string | null;
}

interface ProfileSection {
  id:      string;
  label:   string;
  icon:    string;
  visible: boolean;
  order:   number;
}

const DEFAULT_PROFILE_SECTIONS: ProfileSection[] = [
  { id: 'personal',          label: 'Personal Information', icon: 'fa-circle-user',      visible: true, order: 1  },
  { id: 'contact',           label: 'Contact',              icon: 'fa-address-book',      visible: true, order: 2  },
  { id: 'employment',        label: 'Employment',           icon: 'fa-briefcase',         visible: true, order: 3  },
  { id: 'address',           label: 'Address',              icon: 'fa-location-dot',      visible: true, order: 4  },
  { id: 'passport',          label: 'Passport',             icon: 'fa-passport',          visible: true, order: 5  },
  { id: 'identification',    label: 'Identification',       icon: 'fa-id-card',           visible: true, order: 6  },
  { id: 'emergency',         label: 'Emergency Contact',    icon: 'fa-phone-volume',      visible: true, order: 7  },
  { id: 'bank',              label: 'Bank Accounts',        icon: 'fa-building-columns',  visible: true, order: 8  },
  { id: 'dependents',        label: 'Dependents',           icon: 'fa-people-group',      visible: true, order: 9  },
  { id: 'job_relationships', label: 'Job Relationships',    icon: 'fa-sitemap',           visible: true, order: 10 },
  { id: 'education',         label: 'Education',            icon: 'fa-graduation-cap',    visible: true, order: 11 },
  { id: 'termination',      label: 'Termination',          icon: 'fa-person-walking-arrow-right', visible: true, order: 12 },
];

type UploadKey =
  | 'login_brand_logo'
  | 'login_card_logo'
  | 'nav_logo'
  | 'favicon'
  | 'landing_hero_image'
  | 'landing_graphic_image'
  | 'profile_hero_image';

interface Announcement {
  id:                 string;
  name:               string;
  description:        string | null;
  is_active:          boolean;
  // Step 2 — Card
  card_type:          string;
  title:              string | null;
  subtitle:           string | null;
  image_url:          string | null;
  alt_text:           string | null;
  // Step 3 — Navigation
  nav_target:         string;
  rule_based:         boolean;
  open_new_tab:       boolean;
  url:                string | null;
  show_in_app:        string;
  // Step 4 — Assignments
  target_group_type:  string;
  target_groups:      string;
  folder:             string;
  active_period:      string;
  active_from:        string | null;
  active_to:          string | null;
  days_before_start:  number | null;
  days_after_start:   number | null;
  days_before_term:   number | null;
  days_after_term:    number | null;
  sort_order:         number;
}

type BannerStep = 1 | 2 | 3 | 4;

const BLANK_BANNER: Omit<Announcement, 'id' | 'sort_order'> = {
  name:               '',
  description:        '',
  is_active:          true,
  card_type:          'Image',
  title:              '',
  subtitle:           '',
  image_url:          null,
  alt_text:           '',
  nav_target:         'URL',
  rule_based:         false,
  open_new_tab:       false,
  url:                '',
  show_in_app:        'web_only',
  target_group_type:  'dynamic',
  target_groups:      'Everyone (All Employees)',
  folder:             'Default',
  active_period:      'always',
  active_from:        null,
  active_to:          null,
  days_before_start:  7,
  days_after_start:   14,
  days_before_term:   7,
  days_after_term:    14,
};

const DEFAULTS: ThemeSettings = {
  login_brand_logo:      null,
  login_card_logo:       null,
  nav_logo:              null,
  favicon:               null,
  login_tagline:         'Empowering people. Simplifying work.',
  app_name:              'Prowess Workforce',
  landing_hero_image:    null,
  landing_graphic_image: null,
  profile_hero_image:    null,
  profile_sections:      null,
};

interface LayoutItem {
  id:      string;
  label:   string;
  icon:    string;
  locked?: boolean;
}

interface SuggestedTask {
  id:      string;
  label:   string;
  path:    string;
  visible: boolean;
  order:   number;
}

const DEFAULT_SUGGESTED_TASKS: SuggestedTask[] = [
  { id: 'my_profile',         label: 'My Profile',            path: '/profile',              visible: true,  order: 1 },
  { id: 'my_expense_reports', label: 'My Expense Reports',    path: '/expense',              visible: true,  order: 2 },
  { id: 'create_expense',     label: 'Create Expense Report', path: '/expense?action=new',   visible: false, order: 3 },
  { id: 'org_chart',          label: 'Org Chart',             path: '/org-chart',            visible: false, order: 4 },
  { id: 'my_requests',        label: 'My Requests',           path: '/workflow/my-requests', visible: false, order: 5 },
  { id: 'inbox',              label: 'Inbox',                 path: '/workflow/inbox',       visible: false, order: 6 },
  { id: 'delegations',        label: 'Delegations',           path: '/workflow/delegations', visible: false, order: 7 },
];

interface MostUsedApp {
  id:      string;
  label:   string;
  icon:    string;
  path:    string;
  visible: boolean;
  order:   number;
}

const DEFAULT_MOST_USED_APPS: MostUsedApp[] = [
  { id: 'org_chart',   label: 'Org Chart',   icon: 'fa-diagram-project', path: '/org-chart',            visible: true,  order: 1 },
  { id: 'my_requests', label: 'My Requests', icon: 'fa-list-check',      path: '/workflow/my-requests', visible: true,  order: 2 },
  { id: 'inbox',       label: 'Inbox',       icon: 'fa-inbox',           path: '/workflow/inbox',       visible: true,  order: 3 },
  { id: 'delegations', label: 'Delegations', icon: 'fa-people-arrows',   path: '/workflow/delegations', visible: true,  order: 4 },
  { id: 'my_profile',  label: 'My Profile',  icon: 'fa-user',            path: '/profile',              visible: false, order: 5 },
  { id: 'expense',     label: 'My Expenses', icon: 'fa-receipt',         path: '/expense',              visible: false, order: 6 },
];

const DEFAULT_LAYOUT: LayoutItem[] = [
  { id: 'hero',          label: 'Hero Banner',     icon: 'fa-image',      locked: true },
  { id: 'suggested',     label: 'Suggested Tasks', icon: 'fa-list-check'               },
  { id: 'apps',          label: 'Most Used Apps',  icon: 'fa-grid-2'                   },
  { id: 'announcements', label: 'Announcements',   icon: 'fa-newspaper'                },
];

// ── Root ───────────────────────────────────────────────────────────────────────

export default function ThemeManager() {
  const navigate = useNavigate();
  const [tab, setTab] = useState<'login' | 'landing' | 'profile' | 'announcements' | 'layout'>('login');

  const [settings,      setSettings]      = useState<ThemeSettings>(DEFAULTS);
  const [loading,       setLoading]       = useState(true);
  const [uploading,     setUploading]     = useState<UploadKey | null>(null);
  const [error,         setError]         = useState<string | null>(null);

  const [tagline,       setTagline]       = useState('');
  const [taglineSaving, setTaglineSaving] = useState(false);
  const [taglineSaved,  setTaglineSaved]  = useState(false);
  const [appName,       setAppName]       = useState('');
  const [appNameSaving, setAppNameSaving] = useState(false);
  const [appNameSaved,  setAppNameSaved]  = useState(false);

  const [announcements, setAnnouncements] = useState<Announcement[]>([]);
  const [annLoading,    setAnnLoading]    = useState(false);
  const [editBanner,    setEditBanner]    = useState<Partial<Announcement> | null>(null);
  const [bannerStep,    setBannerStep]    = useState<BannerStep>(1);
  const [bannerSaving,  setBannerSaving]  = useState(false);
  const [bgUploading,   setBgUploading]   = useState(false);

  const [layout,   setLayout]   = useState<LayoutItem[]>(DEFAULT_LAYOUT);
  const [dragIdx,  setDragIdx]  = useState<number | null>(null);
  const [overIdx,  setOverIdx]  = useState<number | null>(null);

  const [suggestedTasks,    setSuggestedTasks]    = useState<SuggestedTask[]>(DEFAULT_SUGGESTED_TASKS);
  const [suggestedExpanded, setSuggestedExpanded] = useState(false);
  const [suggestedSaving,   setSuggestedSaving]   = useState(false);
  const [suggestedSaved,    setSuggestedSaved]    = useState(false);
  const [suggestedDragIdx,  setSuggestedDragIdx]  = useState<number | null>(null);

  const [mostUsedApps,    setMostUsedApps]    = useState<MostUsedApp[]>(DEFAULT_MOST_USED_APPS);
  const [appsExpanded,    setAppsExpanded]    = useState(false);
  const [appsSaving,      setAppsSaving]      = useState(false);
  const [appsSaved,       setAppsSaved]       = useState(false);
  const [appsDragIdx,     setAppsDragIdx]     = useState<number | null>(null);

  const [annExpanded,     setAnnExpanded]     = useState(false);
  const [annSaving,       setAnnSaving]       = useState(false);
  const [annSaved,        setAnnSaved]        = useState(false);
  const [annDragIdx,      setAnnDragIdx]      = useState<number | null>(null);

  // Profile tab
  const [profileSections,    setProfileSections]    = useState<ProfileSection[]>(DEFAULT_PROFILE_SECTIONS);
  const [profileSecDragIdx,  setProfileSecDragIdx]  = useState<number | null>(null);
  const [profileSecSaving,   setProfileSecSaving]   = useState(false);
  const [profileSecSaved,    setProfileSecSaved]    = useState(false);
  const profileHeroRef = useRef<HTMLInputElement>(null);

  // File refs
  const brandRef    = useRef<HTMLInputElement>(null);
  const cardRef     = useRef<HTMLInputElement>(null);
  const navRef      = useRef<HTMLInputElement>(null);
  const faviconRef  = useRef<HTMLInputElement>(null);
  const heroRef     = useRef<HTMLInputElement>(null);
  const graphicRef  = useRef<HTMLInputElement>(null);
  const bgImageRef  = useRef<HTMLInputElement>(null);

  // ── Load ──────────────────────────────────────────────────────────────────

  useEffect(() => {
    (async () => {
      const { data } = await supabase.rpc('get_theme_settings');
      if (data) {
        const s = { ...DEFAULTS, ...data } as ThemeSettings;
        setSettings(s);
        setTagline(s.login_tagline ?? DEFAULTS.login_tagline ?? '');
        setAppName(s.app_name     ?? DEFAULTS.app_name     ?? '');
        if (data.suggested_tasks) {
          try {
            const parsed: SuggestedTask[] = JSON.parse(data.suggested_tasks);
            setSuggestedTasks(parsed.sort((a, b) => a.order - b.order));
          } catch { /* use defaults */ }
        }
        if (data.most_used_apps) {
          try {
            const parsed: MostUsedApp[] = JSON.parse(data.most_used_apps);
            setMostUsedApps(parsed.sort((a, b) => a.order - b.order));
          } catch { /* use defaults */ }
        }
        if (data.profile_sections) {
          try {
            const parsed: ProfileSection[] = JSON.parse(data.profile_sections);
            setProfileSections(parsed.sort((a, b) => a.order - b.order));
          } catch { /* use defaults */ }
        }
      }
      setLoading(false);
    })();
  }, []);

  useEffect(() => {
    if (tab === 'announcements') loadAnnouncements();
  }, [tab]);

  async function loadAnnouncements() {
    setAnnLoading(true);
    const { data } = await supabase
      .from('landing_announcements')
      .select('*')
      .order('sort_order', { ascending: true })
      .order('created_at', { ascending: false });
    setAnnouncements((data ?? []) as Announcement[]);
    setAnnLoading(false);
  }

  // ── Theme helpers ──────────────────────────────────────────────────────────

  async function upsert(key: string, value: string) {
    const { error: err } = await supabase.rpc('upsert_theme_setting', { p_key: key, p_value: value });
    if (err) throw err;
  }

  async function handleUpload(key: UploadKey, file: File) {
    setError(null); setUploading(key);
    try {
      const ext  = file.name.split('.').pop();
      const path = `${key}.${ext}`;
      const { error: upErr } = await supabase.storage
        .from('theme').upload(path, file, { upsert: true, contentType: file.type });
      if (upErr) throw upErr;
      const { data: urlData } = supabase.storage.from('theme').getPublicUrl(path);
      const publicUrl = `${urlData.publicUrl}?t=${Date.now()}`;
      await upsert(key, publicUrl);
      setSettings(prev => ({ ...prev, [key]: publicUrl }));
    } catch (e: any) { setError(e.message ?? 'Upload failed'); }
    finally { setUploading(null); }
  }

  async function saveTagline() {
    setTaglineSaving(true);
    try { await upsert('login_tagline', tagline); setSettings(prev => ({ ...prev, login_tagline: tagline }));
      setTaglineSaved(true); setTimeout(() => setTaglineSaved(false), 2500); }
    catch (e: any) { setError(e.message); } finally { setTaglineSaving(false); }
  }

  async function saveAppName() {
    setAppNameSaving(true);
    try { await upsert('app_name', appName); setSettings(prev => ({ ...prev, app_name: appName }));
      document.title = appName; setAppNameSaved(true); setTimeout(() => setAppNameSaved(false), 2500); }
    catch (e: any) { setError(e.message); } finally { setAppNameSaving(false); }
  }

  // ── Banner CRUD ────────────────────────────────────────────────────────────

  function openCreateBanner() { setEditBanner({ ...BLANK_BANNER }); setBannerStep(1); }
  function openEditBanner(a: Announcement) { setEditBanner({ ...a }); setBannerStep(1); }
  function closeBanner() { setEditBanner(null); }

  function updateBanner<K extends keyof Announcement>(key: K, val: Announcement[K]) {
    setEditBanner(prev => prev ? { ...prev, [key]: val } : prev);
  }

  async function uploadBgImage(file: File) {
    setBgUploading(true);
    try {
      const ext  = file.name.split('.').pop();
      const path = `announcements/${Date.now()}.${ext}`;
      const { error: upErr } = await supabase.storage
        .from('theme').upload(path, file, { upsert: true, contentType: file.type });
      if (upErr) throw upErr;
      const { data: urlData } = supabase.storage.from('theme').getPublicUrl(path);
      updateBanner('image_url', `${urlData.publicUrl}?t=${Date.now()}`);
    } catch (e: any) { setError(e.message); } finally { setBgUploading(false); }
  }

  async function saveBanner() {
    if (!editBanner?.name?.trim()) return;
    setBannerSaving(true);
    try {
      const payload = {
        name:               editBanner.name!,
        description:        editBanner.description        || null,
        is_active:          editBanner.is_active          ?? true,
        card_type:          editBanner.card_type          || 'Image',
        title:              editBanner.title              || null,
        subtitle:           editBanner.subtitle           || null,
        image_url:          editBanner.image_url          || null,
        alt_text:           editBanner.alt_text           || null,
        nav_target:         editBanner.nav_target         || 'URL',
        rule_based:         editBanner.rule_based         ?? false,
        open_new_tab:       editBanner.open_new_tab       ?? false,
        url:                editBanner.url                || null,
        show_in_app:        editBanner.show_in_app        || 'web_only',
        target_group_type:  editBanner.target_group_type  || 'dynamic',
        target_groups:      editBanner.target_groups      || 'Everyone (All Employees)',
        folder:             editBanner.folder             || 'Default',
        active_period:      editBanner.active_period      || 'always',
        active_from:        editBanner.active_from        || null,
        active_to:          editBanner.active_to          || null,
        days_before_start:  editBanner.days_before_start  ?? null,
        days_after_start:   editBanner.days_after_start   ?? null,
        days_before_term:   editBanner.days_before_term   ?? null,
        days_after_term:    editBanner.days_after_term    ?? null,
        sort_order:         editBanner.sort_order         ?? announcements.length,
      };
      if (editBanner.id) {
        await supabase.from('landing_announcements').update(payload).eq('id', editBanner.id);
      } else {
        await supabase.from('landing_announcements').insert(payload);
      }
      closeBanner(); loadAnnouncements();
    } catch (e: any) { setError(e.message); } finally { setBannerSaving(false); }
  }

  async function toggleActive(a: Announcement) {
    await supabase.from('landing_announcements').update({ is_active: !a.is_active }).eq('id', a.id);
    setAnnouncements(prev => prev.map(x => x.id === a.id ? { ...x, is_active: !x.is_active } : x));
  }

  async function deleteAnn(id: string) {
    if (!window.confirm('Delete this announcement?')) return;
    await supabase.from('landing_announcements').delete().eq('id', id);
    setAnnouncements(prev => prev.filter(x => x.id !== id));
  }

  // ── Layout drag ────────────────────────────────────────────────────────────

  function onDragStart(i: number) { if (!layout[i].locked) setDragIdx(i); }
  function onDragOver(e: React.DragEvent, i: number) {
    e.preventDefault(); setOverIdx(i);
    if (dragIdx === null || dragIdx === i || layout[i].locked) return;
    const next = [...layout];
    const [moved] = next.splice(dragIdx, 1);
    next.splice(i, 0, moved);
    setLayout(next); setDragIdx(i);
  }
  function onDragEnd() { setDragIdx(null); setOverIdx(null); }

  // ── Suggested Tasks handlers ───────────────────────────────────────────────

  function toggleSuggestedTask(id: string) {
    setSuggestedTasks(prev => prev.map(t => t.id === id ? { ...t, visible: !t.visible } : t));
  }

  function onSuggestedDragStart(i: number) { setSuggestedDragIdx(i); }
  function onSuggestedDragOver(e: React.DragEvent, i: number) {
    e.preventDefault();
    if (suggestedDragIdx === null || suggestedDragIdx === i) return;
    const next = [...suggestedTasks];
    const [moved] = next.splice(suggestedDragIdx, 1);
    next.splice(i, 0, moved);
    // re-assign order
    const reordered = next.map((t, idx) => ({ ...t, order: idx + 1 }));
    setSuggestedTasks(reordered);
    setSuggestedDragIdx(i);
  }
  function onSuggestedDragEnd() { setSuggestedDragIdx(null); }

  function toggleMostUsedApp(id: string) {
    setMostUsedApps(prev => prev.map(a => a.id === id ? { ...a, visible: !a.visible } : a));
  }
  function onAppsDragStart(i: number) { setAppsDragIdx(i); }
  function onAppsDragOver(e: React.DragEvent, i: number) {
    e.preventDefault();
    if (appsDragIdx === null || appsDragIdx === i) return;
    const next = [...mostUsedApps];
    const [moved] = next.splice(appsDragIdx, 1);
    next.splice(i, 0, moved);
    setMostUsedApps(next.map((a, idx) => ({ ...a, order: idx + 1 })));
    setAppsDragIdx(i);
  }
  function onAppsDragEnd() { setAppsDragIdx(null); }

  // ── Announcements layout handlers ──────────────────────────────────────────

  function toggleAnnVisibility(id: string) {
    setAnnouncements(prev => prev.map(a => a.id === id ? { ...a, is_active: !a.is_active } : a));
  }
  function onAnnDragStart(i: number) { setAnnDragIdx(i); }
  function onAnnDragOver(e: React.DragEvent, i: number) {
    e.preventDefault();
    if (annDragIdx === null || annDragIdx === i) return;
    const next = [...announcements];
    const [moved] = next.splice(annDragIdx, 1);
    next.splice(i, 0, moved);
    setAnnouncements(next.map((a, idx) => ({ ...a, sort_order: idx + 1 })));
    setAnnDragIdx(i);
  }
  function onAnnDragEnd() { setAnnDragIdx(null); }
  async function saveAnnLayout() {
    setAnnSaving(true);
    try {
      // Update sort_order and is_active for each announcement
      await Promise.all(announcements.map(a =>
        supabase.from('landing_announcements')
          .update({ sort_order: a.sort_order, is_active: a.is_active })
          .eq('id', a.id)
      ));
      setAnnSaved(true);
      setTimeout(() => setAnnSaved(false), 2000);
    } catch { /* ignore */ }
    setAnnSaving(false);
  }
  async function saveMostUsedApps() {
    setAppsSaving(true);
    try {
      await upsert('most_used_apps', JSON.stringify(mostUsedApps));
      setAppsSaved(true);
      setTimeout(() => setAppsSaved(false), 2000);
    } catch { /* ignore */ }
    setAppsSaving(false);
  }

  async function saveSuggestedTasks() {
    setSuggestedSaving(true);
    try {
      await upsert('suggested_tasks', JSON.stringify(suggestedTasks));
      setSuggestedSaved(true);
      setTimeout(() => setSuggestedSaved(false), 2000);
    } catch { /* ignore */ }
    setSuggestedSaving(false);
  }

  // ── Profile Section handlers ───────────────────────────────────────────────

  function toggleProfileSection(id: string) {
    setProfileSections(prev => prev.map(s => s.id === id ? { ...s, visible: !s.visible } : s));
  }
  function onProfileSecDragStart(i: number) { setProfileSecDragIdx(i); }
  function onProfileSecDragOver(e: React.DragEvent, i: number) {
    e.preventDefault();
    if (profileSecDragIdx === null || profileSecDragIdx === i) return;
    const next = [...profileSections];
    const [moved] = next.splice(profileSecDragIdx, 1);
    next.splice(i, 0, moved);
    setProfileSections(next.map((s, idx) => ({ ...s, order: idx + 1 })));
    setProfileSecDragIdx(i);
  }
  function onProfileSecDragEnd() { setProfileSecDragIdx(null); }
  async function saveProfileSections() {
    setProfileSecSaving(true);
    try {
      await upsert('profile_sections', JSON.stringify(profileSections));
      setProfileSecSaved(true);
      setTimeout(() => setProfileSecSaved(false), 2000);
    } catch { /* ignore */ }
    setProfileSecSaving(false);
  }

  // ── Render ─────────────────────────────────────────────────────────────────

  if (loading) return <div className="tm-loading">Loading theme settings…</div>;

  return (
    <div className="tm-page">
      <div className="tm-header">
        <h1 className="tm-title">Theme Manager</h1>
        <p className="tm-subtitle">Customise branding, landing page content, and announcements.</p>
      </div>

      {error && (
        <div className="tm-error">
          <i className="fa-solid fa-circle-exclamation" /> {error}
          <button className="tm-error-close" onClick={() => setError(null)}>×</button>
        </div>
      )}

      {/* ── Sidebar + Content layout ──────────────────────────────────────── */}
      <div className="tm-layout">

        {/* Sidebar nav */}
        <nav className="tm-sidebar">
          {/* Back to Admin */}
          <button className="admin-section-back" onClick={() => navigate('/admin')}>
            <i className="fa-solid fa-chevron-left" />
            <span>Admin</span>
          </button>
          <div className="admin-section-divider" />
          <p className="admin-section-group-label">Theme Manager</p>

          {(['login', 'landing', 'profile', 'announcements', 'layout'] as const).map(t => (
            <button key={t} className={`tm-sidebar-item ${tab === t ? 'active' : ''}`} onClick={() => { setTab(t); closeBanner(); }}>
              {t === 'login'         && <><i className="fa-solid fa-right-to-bracket" /><span>Login Page</span></>}
              {t === 'landing'       && <><i className="fa-solid fa-house" /><span>Landing Page</span></>}
              {t === 'profile'       && <><i className="fa-solid fa-circle-user" /><span>Employee Profile</span></>}
              {t === 'announcements' && <><i className="fa-solid fa-newspaper" /><span>Announcements</span></>}
              {t === 'layout'        && <><i className="fa-solid fa-table-columns" /><span>Manage Layout</span></>}
            </button>
          ))}
        </nav>

        {/* Main content */}
        <div className="tm-content">

      {/* ── TAB 1: Login Page ─────────────────────────────────────────────── */}
      {tab === 'login' && (
        <div className="tm-grid">
          <UploadCard title="Login page logo" desc="Shown on the left side of the login page background."
            hint="Recommended: PNG or SVG, ~420 × 100 px, transparent background."
            previewUrl={settings.login_brand_logo} uploading={uploading === 'login_brand_logo'}
            inputRef={brandRef} onPick={() => brandRef.current?.click()}
            onChange={f => handleUpload('login_brand_logo', f)} icon="fa-image" previewBg="dark" />

          <UploadCard title="Login card logo" desc="Logo shown inside the sign-in card."
            hint="Recommended: PNG or SVG, ~300 × 34 px, dark logo on transparent background."
            previewUrl={settings.login_card_logo} uploading={uploading === 'login_card_logo'}
            inputRef={cardRef} onPick={() => cardRef.current?.click()}
            onChange={f => handleUpload('login_card_logo', f)} icon="fa-id-card" previewBg="white" />

          <div className="tm-card">
            <div className="tm-card-header">
              <i className="fa-solid fa-pen-to-square" />
              <div><p className="tm-card-title">Login page tagline</p>
                <p className="tm-card-desc">Subtitle shown below the logo on the login page.</p></div>
            </div>
            <div className="tm-tagline-preview">{tagline || <span className="tm-preview-empty">No tagline set</span>}</div>
            <input className="tm-tagline-input" type="text" value={tagline}
              onChange={e => setTagline(e.target.value)} maxLength={100}
              placeholder="e.g. Empowering people. Simplifying work." />
            <button className="tm-upload-btn" onClick={saveTagline}
              disabled={taglineSaving || tagline === settings.login_tagline}>
              {taglineSaving ? <><i className="fa-solid fa-spinner fa-spin" /> Saving…</>
                : taglineSaved ? <><i className="fa-solid fa-circle-check" /> Saved!</>
                : <><i className="fa-solid fa-floppy-disk" /> Save tagline</>}
            </button>
          </div>

          <div className="tm-card">
            <div className="tm-card-header">
              <i className="fa-solid fa-browser" />
              <div><p className="tm-card-title">App name</p>
                <p className="tm-card-desc">Shown in the browser tab and window title bar.</p></div>
            </div>
            <div className="tm-tagline-preview" style={{ fontFamily: 'monospace', fontSize: 13 }}>
              {appName || <span className="tm-preview-empty">No app name set</span>}
            </div>
            <input className="tm-tagline-input" type="text" value={appName}
              onChange={e => setAppName(e.target.value)} maxLength={60}
              placeholder="e.g. Prowess Workforce" />
            <button className="tm-upload-btn" onClick={saveAppName}
              disabled={appNameSaving || appName === settings.app_name}>
              {appNameSaving ? <><i className="fa-solid fa-spinner fa-spin" /> Saving…</>
                : appNameSaved ? <><i className="fa-solid fa-circle-check" /> Saved!</>
                : <><i className="fa-solid fa-floppy-disk" /> Save app name</>}
            </button>
            <p className="tm-hint">Applied immediately — no page reload needed.</p>
          </div>

          <UploadCard title="Nav logo" desc="Logo shown in the top-left of the app navigation bar."
            hint="Recommended: PNG or SVG, ~300 × 36 px, transparent background."
            previewUrl={settings.nav_logo} uploading={uploading === 'nav_logo'}
            inputRef={navRef} onPick={() => navRef.current?.click()}
            onChange={f => handleUpload('nav_logo', f)} icon="fa-bars" previewBg="white" />

          <UploadCard title="Favicon" desc="Icon shown in the browser tab."
            hint="Recommended: PNG or SVG, 270 × 270 px. Applied on next page reload."
            previewUrl={settings.favicon} uploading={uploading === 'favicon'}
            inputRef={faviconRef} onPick={() => faviconRef.current?.click()}
            onChange={f => handleUpload('favicon', f)} icon="fa-earth-asia" previewBg="white" isFavicon />
        </div>
      )}

      {/* ── TAB 2: Landing Page ───────────────────────────────────────────── */}
      {tab === 'landing' && (
        <div className="tm-grid">
          <UploadCard title="Hero banner image"
            desc="Full-width background image at the top of the landing page."
            hint="Recommended: JPEG or PNG, 1440 × 330 px. City landscape works great."
            previewUrl={settings.landing_hero_image} uploading={uploading === 'landing_hero_image'}
            inputRef={heroRef} onPick={() => heroRef.current?.click()}
            onChange={f => handleUpload('landing_hero_image', f)} icon="fa-panorama" previewBg="dark" />

          <UploadCard title="Greeting card background"
            desc="Full background image for the greeting card. Text overlays the image."
            hint="Recommended: JPEG or PNG, 952 × 300 px. Used as full greeting card background with text overlay."
            previewUrl={settings.landing_graphic_image} uploading={uploading === 'landing_graphic_image'}
            inputRef={graphicRef} onPick={() => graphicRef.current?.click()}
            onChange={f => handleUpload('landing_graphic_image', f)} icon="fa-mountain-sun" previewBg="dark" />
        </div>
      )}

      {/* ── TAB 3: Employee Profile ──────────────────────────────────────── */}
      {tab === 'profile' && (
        <div className="tm-section">

          {/* Banner image */}
          <div className="tm-card">
            <h2 className="tm-card-title">Profile Banner Image</h2>
            <p className="tm-card-desc">
              Shown as the hero banner at the top of every employee profile page.
            </p>

            <UploadCard
              title="Banner image"
              desc="Recommended: 1440 × 200 px, JPEG or PNG, max 3 MB."
              previewUrl={settings.profile_hero_image}
              uploading={uploading === 'profile_hero_image'}
              onChange={f => handleUpload('profile_hero_image', f)}
              icon="fa-image"
              previewBg="dark"
              coverPreview
              onRemove={settings.profile_hero_image ? () => {
                setSettings(s => ({ ...s, profile_hero_image: null }));
                upsert('profile_hero_image', null as any);
              } : undefined}
            />
          </div>

          {/* Section visibility & order */}
          <div className="tm-card" style={{ marginTop: 24 }}>
            <h2 className="tm-card-title">Profile Sections</h2>
            <p className="tm-card-desc">
              Drag to reorder. Toggle to show or hide sections on the employee profile page.
            </p>

            <div className="tm-suggested-list" style={{ marginTop: 16 }}>
              {profileSections.map((sec, i) => (
                <div
                  key={sec.id}
                  className={`tm-suggested-item ${profileSecDragIdx === i ? 'dragging' : ''}`}
                  draggable
                  onDragStart={() => onProfileSecDragStart(i)}
                  onDragOver={e => onProfileSecDragOver(e, i)}
                  onDragEnd={onProfileSecDragEnd}
                >
                  <i className="fa-solid fa-grip-lines tm-suggested-grip" />
                  <i className={`fa-solid ${sec.icon}`} style={{ color: '#005CB9', width: 18, textAlign: 'center' }} />
                  <span className="tm-suggested-label">{sec.label}</span>
                  <label className="tm-toggle">
                    <input type="checkbox" checked={sec.visible} onChange={() => toggleProfileSection(sec.id)} />
                    <span className="tm-toggle-slider" />
                  </label>
                </div>
              ))}
            </div>

            <div className="tm-suggested-footer" style={{ marginTop: 16 }}>
              <span className="tm-suggested-count">
                {profileSections.filter(s => s.visible).length} of {profileSections.length} sections visible
              </span>
              <button className="tm-btn-primary" onClick={saveProfileSections} disabled={profileSecSaving}>
                {profileSecSaved ? '✓ Saved' : profileSecSaving ? 'Saving…' : 'Save'}
              </button>
            </div>
          </div>
        </div>
      )}

      {/* ── TAB 3: Announcements ─────────────────────────────────────────── */}
      {tab === 'announcements' && !editBanner && (
        <div className="tm-ann-tab">
          <div className="tm-ann-toolbar">
            <p className="tm-ann-count">
              {annLoading ? 'Loading…' : `${announcements.length} announcement${announcements.length !== 1 ? 's' : ''}`}
            </p>
            <button className="tm-btn-primary" onClick={openCreateBanner}>
              <i className="fa-solid fa-plus" /> Create Banner
            </button>
          </div>

          {annLoading && <div className="tm-loading">Loading announcements…</div>}

          {!annLoading && announcements.length === 0 && (
            <div className="tm-ann-empty">
              <i className="fa-solid fa-newspaper" />
              <p>No announcements yet. Create one to display it on the landing page.</p>
            </div>
          )}

          {!annLoading && announcements.map(a => (
            <div key={a.id} className="tm-ann-row">
              <div className="tm-ann-thumb" style={{
                backgroundImage:    a.image_url ? `url(${a.image_url})` : undefined,
                backgroundColor:    a.image_url ? undefined : '#1565c0',
                backgroundSize:     'cover', backgroundPosition: 'center',
              }} />
              <div className="tm-ann-info">
                <p className="tm-ann-name">{a.name}</p>
                <p className="tm-ann-meta">
                  {a.title && <span>{a.title}</span>}
                  {a.active_from && <span> · {a.active_from}{a.active_to ? ` → ${a.active_to}` : ''}</span>}
                  <span className={`tm-ann-badge ${a.is_active ? 'active' : 'inactive'}`}>
                    {a.is_active ? 'Active' : 'Inactive'}
                  </span>
                </p>
              </div>
              <div className="tm-ann-actions">
                <button className="tm-icon-btn" title="Edit" onClick={() => openEditBanner(a)}>
                  <i className="fa-solid fa-pen" />
                </button>
                <button className="tm-icon-btn" title={a.is_active ? 'Deactivate' : 'Activate'}
                  onClick={() => toggleActive(a)}>
                  <i className={`fa-solid ${a.is_active ? 'fa-eye-slash' : 'fa-eye'}`} />
                </button>
                <button className="tm-icon-btn danger" title="Delete" onClick={() => deleteAnn(a.id)}>
                  <i className="fa-solid fa-trash" />
                </button>
              </div>
            </div>
          ))}
        </div>
      )}

      {tab === 'announcements' && editBanner && (
        <BannerWizard
          banner={editBanner}
          step={bannerStep}
          saving={bannerSaving}
          bgUploading={bgUploading}
          bgImageRef={bgImageRef}
          onUpdate={updateBanner}
          onStep={setBannerStep}
          onUploadBg={uploadBgImage}
          onSave={saveBanner}
          onCancel={closeBanner}
        />
      )}

      {/* ── TAB 4: Manage Layout ─────────────────────────────────────────── */}
      {tab === 'layout' && (
        <div className="tm-layout-tab">
          <p className="tm-layout-hint">
            Drag sections to reorder them on the landing page.
            The <strong>Hero Banner</strong> is always first.
          </p>
          <div className="tm-layout-skeleton">
            {layout.map((item, i) => (
              <div key={item.id}>
                <div
                  className={`tm-layout-item ${item.locked ? 'locked' : ''} ${dragIdx === i ? 'dragging' : ''} ${overIdx === i && dragIdx !== i ? 'over' : ''}`}
                  draggable={!item.locked}
                  onDragStart={() => onDragStart(i)}
                  onDragOver={e => onDragOver(e, i)}
                  onDragEnd={onDragEnd}
                  onClick={() => {
                    if (item.id === 'suggested')     setSuggestedExpanded(v => !v);
                    if (item.id === 'apps')          setAppsExpanded(v => !v);
                    if (item.id === 'announcements') setAnnExpanded(v => !v);
                  }}
                  style={(item.id === 'suggested' || item.id === 'apps' || item.id === 'announcements') ? { cursor: 'pointer' } : undefined}
                >
                  <i className={`fa-solid ${item.icon} tm-layout-icon`} />
                  <span className="tm-layout-label">{item.label}</span>
                  {item.locked
                    ? <i className="fa-solid fa-lock tm-layout-lock" title="Always first" />
                    : item.id === 'suggested'
                      ? <i className={`fa-solid fa-chevron-${suggestedExpanded ? 'up' : 'down'} tm-layout-grip`} />
                      : item.id === 'apps'
                        ? <i className={`fa-solid fa-chevron-${appsExpanded ? 'up' : 'down'} tm-layout-grip`} />
                        : item.id === 'announcements'
                          ? <i className={`fa-solid fa-chevron-${annExpanded ? 'up' : 'down'} tm-layout-grip`} />
                          : <i className="fa-solid fa-grip-lines tm-layout-grip" />
                  }
                </div>

                {/* ── Most Used Apps expanded config ────────────────────── */}
                {item.id === 'apps' && appsExpanded && (
                  <div className="tm-suggested-config">
                    <p className="tm-suggested-hint">
                      Toggle which apps appear in the Most Used Apps card. Drag to reorder.
                    </p>
                    <div className="tm-suggested-list">
                      {mostUsedApps.map((app, ai) => (
                        <div
                          key={app.id}
                          className={`tm-suggested-item ${appsDragIdx === ai ? 'dragging' : ''}`}
                          draggable
                          onDragStart={() => onAppsDragStart(ai)}
                          onDragOver={e => onAppsDragOver(e, ai)}
                          onDragEnd={onAppsDragEnd}
                        >
                          <i className="fa-solid fa-grip-lines tm-suggested-grip" />
                          <i className={`fa-solid ${app.icon}`} style={{ color: '#005CB9', width: 18, textAlign: 'center' }} />
                          <span className="tm-suggested-label">{app.label}</span>
                          <span className="tm-suggested-path">{app.path}</span>
                          <label className="tm-toggle">
                            <input type="checkbox" checked={app.visible} onChange={() => toggleMostUsedApp(app.id)} />
                            <span className="tm-toggle-slider" />
                          </label>
                        </div>
                      ))}
                    </div>
                    <div className="tm-suggested-footer">
                      <span className="tm-suggested-count">
                        {mostUsedApps.filter(a => a.visible).length} of {mostUsedApps.length} visible
                      </span>
                      <button className="tm-btn-primary" onClick={saveMostUsedApps} disabled={appsSaving}>
                        {appsSaved ? '✓ Saved' : appsSaving ? 'Saving…' : 'Save'}
                      </button>
                    </div>
                  </div>
                )}

                {/* ── Announcements expanded config ─────────────────────── */}
                {item.id === 'announcements' && annExpanded && (
                  <div className="tm-suggested-config">
                    {announcements.length === 0
                      ? <p className="tm-suggested-hint">No announcements yet. Create one in the Announcements tab.</p>
                      : <>
                          <p className="tm-suggested-hint">
                            Toggle visibility and drag to reorder how cards appear on the landing page.
                          </p>
                          <div className="tm-suggested-list">
                            {announcements.map((ann, ai) => (
                              <div
                                key={ann.id}
                                className={`tm-suggested-item ${annDragIdx === ai ? 'dragging' : ''}`}
                                draggable
                                onDragStart={() => onAnnDragStart(ai)}
                                onDragOver={e => onAnnDragOver(e, ai)}
                                onDragEnd={onAnnDragEnd}
                              >
                                <i className="fa-solid fa-grip-lines tm-suggested-grip" />
                                <i className="fa-solid fa-image" style={{ color: '#005CB9', width: 18, textAlign: 'center' }} />
                                <span className="tm-suggested-label">{ann.name}</span>
                                {ann.title && <span className="tm-suggested-path">{ann.title}</span>}
                                <label className="tm-toggle">
                                  <input type="checkbox" checked={ann.is_active} onChange={() => toggleAnnVisibility(ann.id)} />
                                  <span className="tm-toggle-slider" />
                                </label>
                              </div>
                            ))}
                          </div>
                          <div className="tm-suggested-footer">
                            <span className="tm-suggested-count">
                              {announcements.filter(a => a.is_active).length} of {announcements.length} visible
                            </span>
                            <button className="tm-btn-primary" onClick={saveAnnLayout} disabled={annSaving}>
                              {annSaved ? '✓ Saved' : annSaving ? 'Saving…' : 'Save'}
                            </button>
                          </div>
                        </>
                    }
                  </div>
                )}

                {/* ── Suggested Tasks expanded config ───────────────────── */}
                {item.id === 'suggested' && suggestedExpanded && (
                  <div className="tm-suggested-config">
                    <p className="tm-suggested-hint">
                      Toggle which pages appear as pills in the greeting card. Drag to reorder.
                    </p>
                    <div className="tm-suggested-list">
                      {suggestedTasks.map((task, ti) => (
                        <div
                          key={task.id}
                          className={`tm-suggested-item ${suggestedDragIdx === ti ? 'dragging' : ''}`}
                          draggable
                          onDragStart={() => onSuggestedDragStart(ti)}
                          onDragOver={e => onSuggestedDragOver(e, ti)}
                          onDragEnd={onSuggestedDragEnd}
                        >
                          <i className="fa-solid fa-grip-lines tm-suggested-grip" />
                          <span className="tm-suggested-label">{task.label}</span>
                          <span className="tm-suggested-path">{task.path}</span>
                          <label className="tm-toggle">
                            <input
                              type="checkbox"
                              checked={task.visible}
                              onChange={() => toggleSuggestedTask(task.id)}
                            />
                            <span className="tm-toggle-slider" />
                          </label>
                        </div>
                      ))}
                    </div>
                    <div className="tm-suggested-footer">
                      <span className="tm-suggested-count">
                        {suggestedTasks.filter(t => t.visible).length} of {suggestedTasks.length} visible
                      </span>
                      <button
                        className="tm-btn-primary"
                        onClick={saveSuggestedTasks}
                        disabled={suggestedSaving}
                      >
                        {suggestedSaved ? '✓ Saved' : suggestedSaving ? 'Saving…' : 'Save'}
                      </button>
                    </div>
                  </div>
                )}
              </div>
            ))}
          </div>

          <p className="tm-layout-preview-label">Landing page order preview</p>
          <div className="tm-layout-preview">
            {layout.map((item, i) => (
              <div key={item.id} className="tm-layout-preview-item">
                <span className="tm-layout-preview-num">{i + 1}</span>
                <i className={`fa-solid ${item.icon}`} />
                <span>{item.label}</span>
              </div>
            ))}
          </div>
        </div>
      )}

        </div>{/* end tm-content */}
      </div>{/* end tm-layout */}
    </div>
  );
}

// ── Upload Card ────────────────────────────────────────────────────────────────

function UploadCard({
  title, desc, hint, previewUrl, uploading, inputRef: externalRef, onPick, onChange, onRemove, icon, previewBg, isFavicon, coverPreview,
}: {
  title: string; desc: string; hint?: string;
  previewUrl: string | null; uploading: boolean;
  inputRef?: React.RefObject<HTMLInputElement | null>;
  onPick?: () => void; onChange: (f: File) => void; onRemove?: () => void;
  icon: string; previewBg: 'dark' | 'white'; isFavicon?: boolean; coverPreview?: boolean;
}) {
  const internalRef = useRef<HTMLInputElement | null>(null);
  const inputRef = externalRef ?? internalRef;
  const handlePick = onPick ?? (() => inputRef.current?.click());
  return (
    <div className="tm-card">
      <div className="tm-card-header">
        <i className={`fa-solid ${icon}`} />
        <div>
          <p className="tm-card-title">{title}</p>
          <p className="tm-card-desc">{desc}</p>
        </div>
      </div>
      <div className={isFavicon ? 'tm-favicon-preview' : previewBg === 'dark' ? 'tm-preview-bg' : 'tm-preview-white'}
           style={coverPreview && previewUrl ? { padding: 0, overflow: 'hidden' } : undefined}>
        {previewUrl
          ? <img src={previewUrl} alt={title}
              className={isFavicon ? 'tm-favicon-img' : coverPreview ? 'tm-preview-img--cover' : 'tm-preview-img'} />
          : <span className="tm-preview-empty">No image uploaded</span>
        }
      </div>
      <input ref={inputRef} type="file"
        accept="image/png,image/svg+xml,image/jpeg,image/webp,image/x-icon"
        style={{ display: 'none' }}
        onChange={e => { const f = e.target.files?.[0]; if (f) onChange(f); }}
      />
      <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
        <button className="tm-upload-btn" onClick={handlePick} disabled={uploading}>
          {uploading
            ? <><i className="fa-solid fa-spinner fa-spin" /> Uploading…</>
            : <><i className="fa-solid fa-arrow-up-from-bracket" /> Upload image</>
          }
        </button>
        {onRemove && previewUrl && (
          <button className="tm-remove-btn" onClick={onRemove}>
            <i className="fa-solid fa-xmark" /> Remove
          </button>
        )}
      </div>
      {hint && <p className="tm-hint">{hint}</p>}
    </div>
  );
}

// ── Banner Wizard (4-step Create Card) ────────────────────────────────────────

function BannerWizard({
  banner, step, saving, bgUploading, bgImageRef,
  onUpdate, onStep, onUploadBg, onSave, onCancel,
}: {
  banner:             Partial<Announcement>;
  step:               BannerStep;
  saving:             boolean;
  bgUploading:        boolean;
  bgImageRef:         React.RefObject<HTMLInputElement | null>;
  onUpdate:           <K extends keyof Announcement>(key: K, val: Announcement[K]) => void;
  onStep:             (s: BannerStep) => void;
  onUploadBg:         (f: File) => void;
  onSave:             () => void;
  onCancel:           () => void;
}) {
  const STEPS = ['General', 'Card', 'Navigation', 'Assignments'];

  const canNext1 = !!banner.name?.trim();
  const canNext2 = true;
  const canNext3 = !!banner.url?.trim() || banner.nav_target !== 'URL';
  const canSave  = !!banner.name?.trim();

  // ── Role picker state (loaded when step 4 opens) ──────────────────────────
  const [roles,        setRoles]        = useState<{ id: string; code: string; name: string }[]>([]);
  const [roleSearch,   setRoleSearch]   = useState('');
  const [rolePickerOpen, setRolePickerOpen] = useState(false);

  useEffect(() => {
    if (step !== 4 || roles.length > 0) return;
    supabase.from('roles').select('id, code, name').order('name').then(({ data }) => {
      if (data) setRoles(data);
    });
  }, [step]);

  const selectedGroups = (banner.target_groups ?? 'Everyone (All Employees)')
    .split(',').map(g => g.trim()).filter(Boolean);

  function addGroup(name: string) {
    const current = selectedGroups.filter(g => g !== 'Everyone (All Employees)' && g !== '');
    if (current.includes(name)) return;
    onUpdate('target_groups', [...current, name].join(', '));
    setRoleSearch('');
    setRolePickerOpen(false);
  }

  function removeGroup(name: string) {
    const remaining = selectedGroups.filter(g => g !== name);
    onUpdate('target_groups', remaining.length ? remaining.join(', ') : 'Everyone (All Employees)');
  }

  function setEveryone() {
    onUpdate('target_group_type', 'dynamic');
    onUpdate('target_groups', 'Everyone (All Employees)');
  }

  const filteredRoles = roles.filter(r =>
    r.name.toLowerCase().includes(roleSearch.toLowerCase()) ||
    r.code.toLowerCase().includes(roleSearch.toLowerCase())
  );

  const isEveryone = (banner.target_group_type ?? 'dynamic') !== 'roles';

  return (
    <div className="tm-wizard">
      {/* Step progress */}
      <div className="tm-wizard-steps">
        {STEPS.map((s, i) => (
          <div key={s} className="tm-step-wrap">
            <button
              className={`tm-step-btn ${step === i + 1 ? 'active' : ''} ${step > i + 1 ? 'done' : ''}`}
              onClick={() => onStep((i + 1) as BannerStep)}
            >
              <span className="tm-step-num">{step > i + 1 ? <i className="fa-solid fa-check" /> : i + 1}</span>
              <span className="tm-step-label">{s}</span>
            </button>
            {i < STEPS.length - 1 && <span className={`tm-step-line ${step > i + 1 ? 'done' : ''}`} />}
          </div>
        ))}
      </div>

      {/* Step content */}
      <div className="tm-wizard-body">

        {/* ── Step 1: General ── */}
        {step === 1 && (
          <div className="tm-wizard-section">
            <h3 className="tm-wizard-section-title">General</h3>
            <p className="tm-wizard-section-desc">Provide a card name and description for internal reference.</p>

            <label className="tm-field-label">Card Name <span className="tm-required">*</span></label>
            <input className="tm-field-input" type="text" value={banner.name ?? ''}
              onChange={e => onUpdate('name', e.target.value)}
              placeholder="e.g. Q3 Open Enrollment" autoFocus />

            <label className="tm-field-label" style={{ marginTop: 16 }}>Description</label>
            <textarea className="tm-field-textarea" rows={3} value={banner.description ?? ''}
              onChange={e => onUpdate('description', e.target.value)}
              placeholder="Optional internal notes about this card" />

            <div className="tm-toggle-row" style={{ marginTop: 20 }}>
              <span className="tm-field-label" style={{ margin: 0 }}>Enabled</span>
              <label className="tm-toggle">
                <input type="checkbox" checked={banner.is_active ?? true}
                  onChange={e => onUpdate('is_active', e.target.checked)} />
                <span className="tm-toggle-slider" />
              </label>
            </div>
            <p className="tm-hint">When enabled, this card is visible to targeted employees.</p>
          </div>
        )}

        {/* ── Step 2: Card ── */}
        {step === 2 && (
          <div className="tm-wizard-section tm-wizard-section--two-col">
            <div className="tm-wizard-form-col">
              <h3 className="tm-wizard-section-title">Card</h3>
              <p className="tm-wizard-section-desc">Configure the visual appearance of the card.</p>

              <label className="tm-field-label">Type</label>
              <select className="tm-field-select" value={banner.card_type ?? 'Image'}
                onChange={e => onUpdate('card_type', e.target.value)}>
                <option value="Image">Image</option>
                <option value="Text">Text Only</option>
              </select>

              <label className="tm-field-label" style={{ marginTop: 16 }}>
                Title <span className="tm-required">*</span>
              </label>
              <input className="tm-field-input" type="text" value={banner.title ?? ''}
                onChange={e => onUpdate('title', e.target.value)}
                placeholder="Card headline" maxLength={80} />
              <p className="tm-hint">{80 - (banner.title?.length ?? 0)} characters remaining</p>

              <label className="tm-field-label">Subtitle</label>
              <input className="tm-field-input" type="text" value={banner.subtitle ?? ''}
                onChange={e => onUpdate('subtitle', e.target.value)}
                placeholder="Optional supporting text" maxLength={160} />

              {banner.card_type !== 'Text' && (
                <>
                  <label className="tm-field-label" style={{ marginTop: 16 }}>Image</label>
                  <div className="tm-upload-row">
                    <input className="tm-field-input tm-field-input--url" type="text"
                      value={banner.image_url ?? ''}
                      onChange={e => onUpdate('image_url', e.target.value)}
                      placeholder="https://… or browse to upload" />
                    <button className="tm-btn-secondary tm-btn-sm"
                      onClick={() => bgImageRef.current?.click()} disabled={bgUploading}>
                      {bgUploading
                        ? <i className="fa-solid fa-spinner fa-spin" />
                        : <><i className="fa-solid fa-folder-open" /> Browse</>}
                    </button>
                  </div>
                  <input ref={bgImageRef} type="file" accept="image/jpeg,image/png,image/webp"
                    style={{ display: 'none' }}
                    onChange={e => { const f = e.target.files?.[0]; if (f) onUploadBg(f); }} />
                  <p className="tm-hint">JPEG, PNG, or WebP. Recommended 900 × 270 px, max 2 MB.</p>

                  <label className="tm-field-label">Alt Text</label>
                  <input className="tm-field-input" type="text" value={banner.alt_text ?? ''}
                    onChange={e => onUpdate('alt_text', e.target.value)}
                    placeholder="Describe the image for accessibility" />
                </>
              )}
            </div>

            {/* Right preview panel */}
            <div className="tm-wizard-preview-col">
              <p className="tm-preview-label">Preview</p>
              <BannerPreview banner={banner} />
            </div>
          </div>
        )}

        {/* ── Step 3: Navigation ── */}
        {step === 3 && (
          <div className="tm-wizard-section">
            <h3 className="tm-wizard-section-title">Navigation</h3>
            <p className="tm-wizard-section-desc">Define where employees go when they click this card.</p>

            <label className="tm-field-label">Target</label>
            <select className="tm-field-select" value={banner.nav_target ?? 'URL'}
              onChange={e => onUpdate('nav_target', e.target.value)}>
              <option value="URL">URL</option>
              <option value="None">No link</option>
            </select>

            {banner.nav_target !== 'None' && (
              <>


                <label className="tm-check-label" style={{ marginTop: 12 }}>
                  <input type="checkbox" checked={banner.open_new_tab ?? false}
                    onChange={e => onUpdate('open_new_tab', e.target.checked)} />
                  Open link in new window or tab
                </label>

                <label className="tm-field-label" style={{ marginTop: 16 }}>
                  URL <span className="tm-required">*</span>
                </label>
                <input className="tm-field-input" type="url" value={banner.url ?? ''}
                  onChange={e => onUpdate('url', e.target.value)}
                  placeholder="https://…" />
              </>
            )}

          </div>
        )}

        {/* ── Step 4: Assignments ── */}
        {step === 4 && (
          <div className="tm-wizard-section">
            <h3 className="tm-wizard-section-title">Assignments</h3>
            <p className="tm-wizard-section-desc">Choose who sees this card and when it should be active.</p>

            <label className="tm-field-label">Target Group</label>

            {/* Everyone shortcut */}
            <div className="tm-tgt-everyone">
              <label className="tm-radio-label">
                <input type="radio" name="tgt_everyone"
                  checked={isEveryone}
                  onChange={setEveryone} />
                Everyone (All Employees)
              </label>
            </div>

            {/* Specific roles / groups */}
            <div className="tm-tgt-specific">
              <label className="tm-radio-label" style={{ marginBottom: 10 }}>
                <input type="radio" name="tgt_everyone"
                  checked={!isEveryone}
                  onChange={() => {
                    onUpdate('target_group_type', 'roles');
                    onUpdate('target_groups', '');
                  }} />
                Specific Permission Roles or Groups
              </label>

              {/* Selected chips */}
              {!isEveryone && (
                <div className="tm-tag-row" style={{ marginBottom: 8 }}>
                  {selectedGroups.map(g => (
                    <span key={g} className="tm-tag">
                      {g}
                      <button className="tm-tag-remove" onClick={() => removeGroup(g)}>
                        <i className="fa-solid fa-xmark" />
                      </button>
                    </span>
                  ))}
                </div>
              )}

              {/* Role search + dropdown */}
              {!isEveryone && (
                <div className="tm-role-picker">
                  <input
                    className="tm-field-input"
                    type="text"
                    placeholder="Search roles…"
                    value={roleSearch}
                    onChange={e => { setRoleSearch(e.target.value); setRolePickerOpen(true); }}
                    onFocus={() => setRolePickerOpen(true)}
                  />
                  {rolePickerOpen && filteredRoles.length > 0 && (
                    <div className="tm-role-dropdown">
                      {filteredRoles.map(r => (
                        <button
                          key={r.id}
                          className={`tm-role-option ${selectedGroups.includes(r.name) ? 'selected' : ''}`}
                          onMouseDown={e => { e.preventDefault(); addGroup(r.name); }}
                        >
                          <span className="tm-role-name">{r.name}</span>
                          <span className="tm-role-code">{r.code}</span>
                          {selectedGroups.includes(r.name) && <i className="fa-solid fa-check" />}
                        </button>
                      ))}
                    </div>
                  )}
                </div>
              )}
            </div>

            <label className="tm-field-label" style={{ marginTop: 20 }}>Active Period</label>
            <div className="tm-radio-group">
              {[
                { val: 'always',         label: 'Always' },
                { val: 'date_range',     label: 'Date Range' },
                { val: 'start_date',     label: 'Based on Start Date' },
                { val: 'term_date',      label: 'Based on Termination Date' },
              ].map(opt => (
                <label key={opt.val} className="tm-radio-label">
                  <input type="radio" name="active_period"
                    value={opt.val}
                    checked={(banner.active_period ?? 'always') === opt.val}
                    onChange={() => onUpdate('active_period', opt.val)} />
                  {opt.label}
                </label>
              ))}
            </div>

            {banner.active_period === 'date_range' && (
              <div className="tm-date-row" style={{ marginTop: 12 }}>
                <div className="tm-date-field">
                  <label className="tm-field-label">From</label>
                  <input className="tm-field-input" type="date"
                    value={banner.active_from ?? ''}
                    onChange={e => onUpdate('active_from', e.target.value || null)} />
                </div>
                <div className="tm-date-field">
                  <label className="tm-field-label">To</label>
                  <input className="tm-field-input" type="date"
                    value={banner.active_to ?? ''}
                    onChange={e => onUpdate('active_to', e.target.value || null)} />
                </div>
              </div>
            )}

            {banner.active_period === 'start_date' && (
              <div className="tm-date-row" style={{ marginTop: 12 }}>
                <div className="tm-date-field">
                  <label className="tm-field-label">Days before start</label>
                  <input className="tm-field-input" type="number" min={0}
                    value={banner.days_before_start ?? 7}
                    onChange={e => onUpdate('days_before_start', Number(e.target.value))} />
                </div>
                <div className="tm-date-field">
                  <label className="tm-field-label">Days after start</label>
                  <input className="tm-field-input" type="number" min={0}
                    value={banner.days_after_start ?? 14}
                    onChange={e => onUpdate('days_after_start', Number(e.target.value))} />
                </div>
              </div>
            )}

            {banner.active_period === 'term_date' && (
              <div className="tm-date-row" style={{ marginTop: 12 }}>
                <div className="tm-date-field">
                  <label className="tm-field-label">Days before termination</label>
                  <input className="tm-field-input" type="number" min={0}
                    value={banner.days_before_term ?? 7}
                    onChange={e => onUpdate('days_before_term', Number(e.target.value))} />
                </div>
                <div className="tm-date-field">
                  <label className="tm-field-label">Days after termination</label>
                  <input className="tm-field-input" type="number" min={0}
                    value={banner.days_after_term ?? 14}
                    onChange={e => onUpdate('days_after_term', Number(e.target.value))} />
                </div>
              </div>
            )}
          </div>
        )}
      </div>

      {/* Wizard footer */}
      <div className="tm-wizard-footer">
        <button className="tm-btn-ghost" onClick={onCancel}>
          <i className="fa-solid fa-arrow-left" /> Back to list
        </button>
        <div className="tm-wizard-nav">
          {step > 1 && (
            <button className="tm-btn-secondary" onClick={() => onStep((step - 1) as BannerStep)}>
              Previous
            </button>
          )}
          {step < 4 && (
            <button className="tm-btn-primary"
              onClick={() => onStep((step + 1) as BannerStep)}
              disabled={
                (step === 1 && !canNext1) ||
                (step === 2 && !canNext2) ||
                (step === 3 && !canNext3)
              }>
              Next <i className="fa-solid fa-arrow-right" />
            </button>
          )}
          {step === 4 && (
            <button className="tm-btn-primary" onClick={onSave}
              disabled={saving || !canSave}>
              {saving
                ? <><i className="fa-solid fa-spinner fa-spin" /> Saving…</>
                : <><i className="fa-solid fa-floppy-disk" /> Save Card</>}
            </button>
          )}
        </div>
      </div>
    </div>
  );
}

// ── Banner Preview ─────────────────────────────────────────────────────────────

function BannerPreview({ banner }: { banner: Partial<Announcement> }) {
  const hasImage = !!banner.image_url;
  const style: React.CSSProperties = {
    backgroundImage:    hasImage ? `url(${banner.image_url})` : undefined,
    backgroundColor:    hasImage ? undefined : '#1565c0',
    backgroundSize:     'cover',
    backgroundPosition: 'center',
    borderRadius:       10,
    minHeight:          160,
    position:           'relative',
    overflow:           'hidden',
    display:            'flex',
    alignItems:         'flex-end',
    marginTop:          12,
  };
  return (
    <div style={style}>
      {hasImage && (
        <div style={{ position: 'absolute', inset: 0,
          background: 'linear-gradient(0deg,rgba(0,0,0,.6) 0%,rgba(0,0,0,.05) 60%,transparent 100%)',
          pointerEvents: 'none' }} />
      )}
      <div style={{ position: 'relative', padding: '20px 24px', width: '100%' }}>
        {banner.title && (
          <p style={{ fontSize: 18, fontWeight: 700, color: '#fff', margin: '0 0 6px' }}>
            {banner.title}
          </p>
        )}
        {banner.subtitle && (
          <p style={{ fontSize: 13, color: 'rgba(255,255,255,0.85)', margin: 0, lineHeight: 1.5 }}>
            {banner.subtitle}
          </p>
        )}
        {!banner.title && !banner.subtitle && (
          <p style={{ color: 'rgba(255,255,255,0.4)', fontSize: 13, margin: 0, fontStyle: 'italic' }}>
            Card preview — add a title or image to see it here
          </p>
        )}
      </div>
    </div>
  );
}
