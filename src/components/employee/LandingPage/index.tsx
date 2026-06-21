/**
 * LandingPage — Workday-matched layout.
 *
 * Key structural truth (from Workday screenshot):
 *   - Greeting card is a SINGLE white card
 *   - The mountain illustration is INSIDE the card, absolutely positioned on the right
 *   - The illustration overflows ABOVE the card top into the blue hero
 *   - Text content occupies the left portion of the card (with right padding for illustration)
 */
import { useState, useEffect }      from 'react';
import { useNavigate }              from 'react-router-dom';
import { useAuth }                  from '../../../contexts/AuthContext';
import { supabase }                 from '../../../lib/supabase';
import './LandingPage.css';

// ── Types ─────────────────────────────────────────────────────────────────────

interface SuggestedTask {
  id:      string;
  label:   string;
  path:    string;
  visible: boolean;
  order:   number;
}

const DEFAULT_SUGGESTED_TASKS: SuggestedTask[] = [
  { id: 'my_profile',         label: 'My Profile',         path: '/profile', visible: true,  order: 1 },
  { id: 'my_expense_reports', label: 'My Expense Reports', path: '/expense', visible: true,  order: 2 },
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
  { id: 'org_chart',   label: 'Org Chart',   icon: 'fa-diagram-project', path: '/org-chart',            visible: true, order: 1 },
  { id: 'my_requests', label: 'My Requests', icon: 'fa-list-check',      path: '/workflow/my-requests', visible: true, order: 2 },
  { id: 'inbox',       label: 'Inbox',       icon: 'fa-inbox',           path: '/workflow/inbox',       visible: true, order: 3 },
  { id: 'delegations', label: 'Delegations', icon: 'fa-people-arrows',   path: '/workflow/delegations', visible: true, order: 4 },
];

interface ThemeSettings {
  landing_hero_image:    string | null;
  landing_graphic_image: string | null;
  suggested_tasks:       string | null;
  most_used_apps:        string | null;
}

interface Announcement {
  id:          string;
  title:       string | null;
  subtitle:    string | null;
  image_url:   string | null;
  url:         string | null;
  open_new_tab: boolean;
  nav_target:  string;
}

// ── Helpers ───────────────────────────────────────────────────────────────────

function getGreeting(): string {
  const h = new Date().getHours();
  if (h < 12) return 'Good Morning';
  if (h < 17) return 'Good Afternoon';
  return 'Good Evening';
}

function formatDate(): string {
  return new Date().toLocaleDateString('en-US', {
    weekday: 'long', month: 'long', day: 'numeric',
  });
}


const DEFAULT_HERO = '/Human AI.png';

// ── Component ─────────────────────────────────────────────────────────────────

export default function LandingPage() {
  const { employee }                      = useAuth();
  const navigate                          = useNavigate();
  const [theme, setTheme]                 = useState<ThemeSettings>({ landing_hero_image: null, landing_graphic_image: null, suggested_tasks: null });
  const [suggestedTasks, setSuggestedTasks] = useState<SuggestedTask[]>(DEFAULT_SUGGESTED_TASKS);
  const [mostUsedApps,   setMostUsedApps]   = useState<MostUsedApp[]>(DEFAULT_MOST_USED_APPS);
  const [themeLoaded, setThemeLoaded]     = useState(false);
  const [announcements, setAnnouncements] = useState<Announcement[]>([]);
  const [annPage, setAnnPage]             = useState(0);
  const [showAllApps, setShowAllApps]     = useState(false);

  const MAX_APPS = 5;

  // Wait for employee name from auth — avoid "there" flash
  const firstName = employee?.name?.split(' ')[0] ?? '';

  useEffect(() => {
    (async () => {
      const { data } = await supabase.rpc('get_theme_settings');
      if (data) {
        setTheme({
          landing_hero_image:    data.landing_hero_image    ?? null,
          landing_graphic_image: data.landing_graphic_image ?? null,
          suggested_tasks:       data.suggested_tasks       ?? null,
          most_used_apps:        data.most_used_apps        ?? null,
        });
        if (data.most_used_apps) {
          try {
            const parsed: MostUsedApp[] = JSON.parse(data.most_used_apps);
            setMostUsedApps(parsed.filter(a => a.visible).sort((a, b) => a.order - b.order));
          } catch { /* use defaults */ }
        }
        if (data.suggested_tasks) {
          try {
            const parsed: SuggestedTask[] = JSON.parse(data.suggested_tasks);
            // Normalise legacy paths that no longer exist
            const pathFixes: Record<string, string> = { '/expense/new': '/expense?action=new' };
            setSuggestedTasks(
              parsed
                .filter(t => t.visible)
                .sort((a, b) => a.order - b.order)
                .map(t => ({ ...t, path: pathFixes[t.path] ?? t.path }))
            );
          } catch { /* use defaults */ }
        }
      }
      setThemeLoaded(true);
    })();
    (async () => {
      const today = new Date().toISOString().slice(0, 10);
      const { data } = await supabase
        .from('landing_announcements')
        .select('*')
        .eq('is_active', true)
        .or(`active_from.is.null,active_from.lte.${today}`)
        .or(`active_to.is.null,active_to.gte.${today}`)
        .order('sort_order')
        .order('created_at', { ascending: false });
      if (data) setAnnouncements(data as Announcement[]);
    })();
  }, []);

  useEffect(() => {
    if (announcements.length <= 3) return;
    const pages = Math.ceil(announcements.length / 3);
    const t = setInterval(() => setAnnPage(p => ((p / 3 + 1) % pages) * 3), 6000);
    return () => clearInterval(t);
  }, [announcements.length]);

  const heroUrl  = theme.landing_hero_image ?? DEFAULT_HERO;
  const heroStyle: React.CSSProperties = {
    background: heroUrl
      ? `linear-gradient(rgba(17,48,97,0.45),rgba(17,48,97,0.45)), url(${heroUrl}) center 30% / cover no-repeat #113061`
      : '#113061',
  };

  // Show up to 3 real announcements per page; remainder are placeholders
  const pageAnns = [0, 1, 2].map(i => {
    const idx = annPage + i;
    return idx < announcements.length ? announcements[idx] : null;
  });

  return (
    <div className="lp-page">

      {/* ── Full-bleed hero strip ─────────────────────────────────────────── */}
      <div className="lp-hero" style={heroStyle} />

      {/* ── Greeting card — straddles hero/body boundary ──────────────────── */}
      <div className="lp-card-wrap" style={!themeLoaded || !firstName ? { visibility: 'hidden' } : undefined}>
        {/*
          Single white card. The mountain illustration lives INSIDE this card,
          absolutely positioned to the right. overflow:visible lets the sun
          poke above the card top into the blue hero zone.
        */}
        <div
          className={`lp-card${theme.landing_graphic_image ? ' lp-card--bg' : ''}`}
          style={theme.landing_graphic_image ? {
            backgroundImage: `url(${theme.landing_graphic_image})`,
            backgroundSize: 'cover',
            backgroundPosition: 'center',
          } : undefined}
        >
          {/* No overlay — bg image has white left region, text is dark */}

          {/* Text */}
          <div className="lp-card-text">
            <h2 className="lp-greeting">{firstName ? `${getGreeting()}, ${firstName}` : getGreeting()}</h2>
            <p className="lp-date">{`It's ${formatDate()}`}</p>
            <p className="lp-tasks-label">Suggested Tasks</p>
            <div className="lp-tasks">
              {suggestedTasks.map(task => (
                <button key={task.id} className="lp-pill" onClick={() => navigate(task.path)}>
                  {task.label}
                </button>
              ))}
            </div>
          </div>

          {/* Illustration — only shown when no bg image */}
          {!theme.landing_graphic_image && (
            <div className="lp-card-graphic">
              <WorkdayMountains />
            </div>
          )}
        </div>
      </div>

      {/* ── Body ──────────────────────────────────────────────────────────── */}
      <div className="lp-body">

        <p className="lp-section-label">Most Used Apps</p>
        <div className="lp-apps-card">
          {mostUsedApps.slice(0, MAX_APPS).map(app => (
            <button key={app.id} className="lp-app" onClick={() => navigate(app.path)}>
              <div className="lp-app-icon">
                <i className={`fa-solid ${app.icon}`} />
              </div>
              <span className="lp-app-label">{app.label}</span>
            </button>
          ))}
          {mostUsedApps.length > MAX_APPS && (
            <button className="lp-app lp-app--more" onClick={() => setShowAllApps(true)}>
              <div className="lp-app-icon lp-app-icon--more">
                <i className="fa-solid fa-grid-2" />
              </div>
              <span className="lp-app-label">View More Apps</span>
            </button>
          )}
        </div>

        {/* ── All Apps modal ──────────────────────────────────────────────── */}
        {showAllApps && (
          <div className="lp-modal-backdrop" onClick={() => setShowAllApps(false)}>
            <div className="lp-modal" onClick={e => e.stopPropagation()}>
              <div className="lp-modal-header">
                <h3 className="lp-modal-title">All Apps</h3>
                <button className="lp-modal-close" onClick={() => setShowAllApps(false)}>
                  <i className="fa-solid fa-xmark" />
                </button>
              </div>
              <div className="lp-modal-grid">
                {mostUsedApps.map(app => (
                  <button key={app.id} className="lp-app" onClick={() => { navigate(app.path); setShowAllApps(false); }}>
                    <div className="lp-app-icon">
                      <i className={`fa-solid ${app.icon}`} />
                    </div>
                    <span className="lp-app-label">{app.label}</span>
                  </button>
                ))}
              </div>
            </div>
          </div>
        )}

        <p className="lp-section-label">Announcements</p>
        {announcements.length > 0 && (
          <div className="lp-ann-grid">
            {pageAnns.filter(Boolean).map((ann, i) => <AnnCard key={`${ann!.id}-${i}`} ann={ann!} />)}
          </div>
        )}

        {announcements.length > 3 && (
          <div className="lp-dots">
            {Array.from({ length: Math.ceil(announcements.length / 3) }, (_, i) => (
              <button
                key={i}
                className={`lp-dot ${Math.floor(annPage / 3) === i ? 'active' : ''}`}
                onClick={() => setAnnPage(i * 3)}
              />
            ))}
          </div>
        )}
      </div>
    </div>
  );
}

// ── Sub-components ────────────────────────────────────────────────────────────

function AnnCard({ ann }: { ann: Announcement }) {
  const hasImage = !!ann.image_url;
  const style: React.CSSProperties = {
    backgroundImage:    hasImage ? `url(${ann.image_url})` : undefined,
    backgroundColor:    hasImage ? undefined : '#1565c0',
    backgroundSize:     'cover',
    backgroundPosition: 'center',
  };
  const inner = (
    <div className="lp-ann-card" style={style}>
      {hasImage && <div className="lp-ann-overlay" />}
      <div className="lp-ann-body">
        {ann.title    && <p className="lp-ann-title">{ann.title}</p>}
        {ann.subtitle && <p className="lp-ann-content">{ann.subtitle}</p>}
      </div>
    </div>
  );
  if (ann.nav_target !== 'None' && ann.url) {
    return (
      <a href={ann.url} target={ann.open_new_tab ? '_blank' : '_self'} rel="noreferrer"
        style={{ textDecoration: 'none', display: 'contents' }}>
        {inner}
      </a>
    );
  }
  return inner;
}


// Mountain illustration — transparent bg, floats right inside the card
function WorkdayMountains() {
  return (
    <svg
      viewBox="0 0 300 170"
      xmlns="http://www.w3.org/2000/svg"
      style={{ width: '100%', height: '100%', display: 'block' }}
      preserveAspectRatio="xMidYMax meet"
    >
      {/* Sun */}
      <circle cx="240" cy="30" r="34" fill="#f7c948" />
      {/* Cloud */}
      <ellipse cx="92"  cy="44" rx="48" ry="22" fill="#dce8f0" />
      <ellipse cx="136" cy="34" rx="36" ry="22" fill="#dce8f0" />
      <ellipse cx="62"  cy="42" rx="32" ry="18" fill="#dce8f0" />
      {/* Back mountain — blue-grey */}
      <polygon points="10,170  140,40  270,170" fill="#9bb8cc" />
      {/* Right mountain — lime */}
      <polygon points="120,170 230,58  300,170" fill="#7bbf3e" />
      {/* Front mountain — bright lime */}
      <polygon points="0,170   128,42  228,170" fill="#5cb62b" />
      {/* Ground */}
      <rect x="0" y="164" width="300" height="6" fill="#9dd46a" />
    </svg>
  );
}
