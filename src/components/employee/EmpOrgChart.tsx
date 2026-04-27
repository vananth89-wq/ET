import {
  useState, useMemo, useEffect,
  useRef, useCallback,
} from 'react';
import { useAuth } from '../../contexts/AuthContext';
import { useEmployees } from '../../hooks/useEmployees';
import { useDepartments } from '../../hooks/useDepartments';
import { usePicklistValues } from '../../hooks/usePicklistValues';

// ─────────────────────────────────────────────────────────────────────────────
// Types
// ─────────────────────────────────────────────────────────────────────────────
interface Emp {
  id?: string;             // UUID primary key (matches employees.id; used for manager FK lookups)
  employeeId: string;
  name: string;
  designation?: string;
  deptId?: string;
  departmentId?: string;   // legacy alias
  managerId?: string;
  photo?: string;
  hireDate?: string;
  endDate?: string;
  status?: string;
  businessEmail?: string;
  mobile?: string;
  workLocation?: string;
  role?: string;
  [key: string]: unknown;
}

interface EmpNode extends Emp {
  children: EmpNode[];
}

interface Dept {
  id?: string;     // UUID primary key (matches employees.dept_id FK)
  deptId: string;  // human-readable code
  name: string;
}

interface PlVal {
  picklistId: string;
  id: string | number;
  value: string;
}

interface ProfileData {
  name?: string;
  employeeId?: string;
}

// ─────────────────────────────────────────────────────────────────────────────
// Dept colour palette (stable hash → colour)
// ─────────────────────────────────────────────────────────────────────────────
const DEPT_COLOURS = [
  '#3B82F6', // blue
  '#22C55E', // green
  '#F97316', // orange
  '#A855F7', // purple
  '#EF4444', // red
  '#14B8A6', // teal
  '#EAB308', // yellow
  '#8B5CF6', // violet
  '#06B6D4', // cyan
  '#F43F5E', // rose
];

function deptColour(deptId: string, allDeptIds: string[]): string {
  const idx = allDeptIds.indexOf(deptId);
  if (idx === -1) return '#6B7280';
  return DEPT_COLOURS[idx % DEPT_COLOURS.length];
}

// ─────────────────────────────────────────────────────────────────────────────
// Avatar colour (name-hash)
// ─────────────────────────────────────────────────────────────────────────────
const AVATAR_COLORS = [
  '#2F77B5','#4CAF50','#E91E63','#FF9800','#9C27B0',
  '#00BCD4','#795548','#607D8B','#3F51B5','#009688',
];
function avatarColor(name: string): string {
  let n = 0;
  for (const c of String(name || 'A')) n += c.charCodeAt(0);
  return AVATAR_COLORS[Math.abs(n) % AVATAR_COLORS.length];
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────
function todayStr(): string { return new Date().toISOString().slice(0, 10); }

function fmtDate(val?: string): string {
  if (!val) return '—';
  if (val === '9999-12-31') return 'Open-ended';
  return new Date(val + 'T00:00:00').toLocaleDateString('en-GB', {
    day: '2-digit', month: 'short', year: 'numeric',
  });
}

/** Is this employee "active" as of the given date? */
function isActiveOn(emp: Emp, date: string): boolean {
  if (emp.status === 'Draft' || emp.status === 'Incomplete') return false;
  const hired = emp.hireDate;
  const end   = emp.endDate;
  if (hired && hired > date) return false;
  if (end && end !== '9999-12-31' && end < date) return false;
  return true;
}

/** Resolve employee's department ID (handles both field names) */
function empDeptId(emp: Emp): string {
  return (emp.deptId || emp.departmentId || '') as string;
}

/** Build manager→reports tree
 *
 * empMap is keyed by BOTH the UUID (e.id) AND the text code (e.employeeId)
 * so that UUID-based managerId lookups AND text-code-based UI lookups both work.
 *
 * Background: employees.manager_id is a UUID FK → employees.id, but UI state
 * (selectedId, focusId, collapsed, onToggle callbacks) all use the human-readable
 * employeeId text code.  Dual-indexing bridges the two worlds without changing
 * every call site.
 */
function buildEmpTree(
  emps: Emp[],
): { empMap: Record<string, EmpNode>; roots: EmpNode[] } {
  const empMap: Record<string, EmpNode> = {};
  emps.forEach(e => {
    const node: EmpNode = { ...e, children: [] };
    // Index by text code (for UI lookups)
    empMap[e.employeeId] = node;
    // Index by UUID (for manager_id FK lookups); skip if same as employeeId
    if (e.id && e.id !== e.employeeId) {
      empMap[e.id] = node;
    }
  });

  const roots: EmpNode[] = [];
  emps.forEach(e => {
    // managerId is a UUID FK → employees.id; empMap[managerId] now resolves correctly
    if (e.managerId && empMap[e.managerId]) {
      empMap[e.managerId].children.push(empMap[e.employeeId]);
    } else {
      roots.push(empMap[e.employeeId]);
    }
  });

  function sortChildren(node: EmpNode) {
    node.children.sort((a, b) => a.name.localeCompare(b.name));
    node.children.forEach(sortChildren);
  }
  roots.sort((a, b) => a.name.localeCompare(b.name));
  roots.forEach(sortChildren);

  return { empMap, roots };
}

/** Count all subordinates recursively */
function teamSize(empId: string, empMap: Record<string, EmpNode>): number {
  const node = empMap[empId];
  if (!node) return 0;
  return node.children.reduce((sum, c) => sum + 1 + teamSize(c.employeeId, empMap), 0);
}

/** Reporting chain from root down to this employee */
function reportingChain(empId: string, empMap: Record<string, EmpNode>): string[] {
  const chain: string[] = [];
  const visited = new Set<string>();
  let cur: EmpNode | undefined = empMap[empId];
  while (cur && !visited.has(cur.employeeId)) {
    visited.add(cur.employeeId);
    chain.unshift(cur.employeeId);
    cur = cur.managerId ? empMap[cur.managerId] : undefined;
  }
  return chain;
}

/** All subordinates recursively */
function allSubs(empId: string, empMap: Record<string, EmpNode>): string[] {
  const node = empMap[empId];
  if (!node) return [];
  return node.children.flatMap(c => [c.employeeId, ...allSubs(c.employeeId, empMap)]);
}

// ─────────────────────────────────────────────────────────────────────────────
// OrgNode — recursive card renderer
// ─────────────────────────────────────────────────────────────────────────────
interface OrgNodeProps {
  node: EmpNode;
  collapsed: Set<string>;
  highlightMap: Record<string, string>;
  empMap: Record<string, EmpNode>;
  deptMap: Record<string, Dept>;
  orderedDeptIds: string[];
  profileEmpId: string | null;
  plVals: PlVal[];
  onToggle: (id: string) => void;
  onSelect: (id: string) => void;
  onFocus:  (id: string) => void;
}

function OrgNode({
  node, collapsed, highlightMap, empMap, deptMap, orderedDeptIds,
  profileEmpId, plVals, onToggle, onSelect, onFocus,
}: OrgNodeProps) {
  const hasChildren = node.children.length > 0;
  const isCollapsed = collapsed.has(node.employeeId);
  const isYou       = node.employeeId === profileEmpId;
  const dId         = empDeptId(node);
  const deptName    = deptMap[dId]?.name || dId || '—';
  const colour      = dId ? deptColour(dId, orderedDeptIds) : '#6B7280';
  const highlight   = highlightMap[node.employeeId] || '';
  const initial     = (node.name || '?').charAt(0).toUpperCase();
  const size        = teamSize(node.employeeId, empMap);

  // Resolve designation label
  const desigLabel = (() => {
    const v = plVals.find(
      p => p.picklistId === 'DESIGNATION' &&
        (String(p.id) === String(node.designation) || p.value === node.designation)
    );
    return v ? v.value : (node.designation as string | undefined) || '—';
  })();

  const sharedCardProps = {
    'data-emp-id': node.employeeId,
  } as React.HTMLAttributes<HTMLDivElement> & { 'data-emp-id': string };

  return (
    <div className="eoc-node-wrap" data-emp-id={node.employeeId}>
      {/* ── Card ── */}
      <div
        className={`eoc-card${highlight ? ' ' + highlight : ''}`}
        {...sharedCardProps}
        style={{
          borderTop: `3px solid ${colour}`,
          position: 'relative',
        } as React.CSSProperties}
        onClick={e  => { e.stopPropagation(); onSelect(node.employeeId); }}
        onDoubleClick={e => { e.preventDefault(); e.stopPropagation(); onFocus(node.employeeId); }}
        title={`${node.name} — click for details, double-click to focus`}
      >
        {/* YOU badge */}
        {isYou && (
          <span className="eoc-you-badge">YOU</span>
        )}

        {/* Avatar */}
        {node.photo
          ? <img src={node.photo as string} alt={node.name}
              className="eoc-avatar eoc-avatar--photo"
              style={{ background: 'transparent' }} />
          : <div className="eoc-avatar" style={{ background: avatarColor(node.name) }}>{initial}</div>
        }

        {/* Body */}
        <div className="eoc-card-body">
          <div className="eoc-card-name">{node.name}</div>
          <div className="eoc-card-desg" style={{ color: colour }}>{desigLabel}</div>
          <div className="eoc-card-dept">{deptName}</div>
          <div className="eoc-card-id">{node.employeeId}</div>
        </div>

        {/* Team badge */}
        {size > 0 && (
          <div className="eoc-team-badge" title={`${size} total report${size !== 1 ? 's' : ''}`}>
            <i className="fa-solid fa-users" /> {size}
          </div>
        )}
      </div>

      {/* ── Toggle btn ── */}
      {hasChildren && (
        <button
          className="eoc-toggle-btn"
          data-emp-id={node.employeeId}
          title={isCollapsed ? 'Expand' : 'Collapse'}
          onClick={e => { e.stopPropagation(); onToggle(node.employeeId); }}
        >
          <i className={`fa-solid ${isCollapsed ? 'fa-plus' : 'fa-minus'}`} />
        </button>
      )}

      {/* ── Children ── */}
      {hasChildren && !isCollapsed && (
        <div className="eoc-children-row" data-parent-id={node.employeeId}>
          {node.children.map(child => (
            <div key={child.employeeId} className="eoc-child-wrap">
              <OrgNode
                node={child}
                collapsed={collapsed}
                highlightMap={highlightMap}
                empMap={empMap}
                deptMap={deptMap}
                orderedDeptIds={orderedDeptIds}
                profileEmpId={profileEmpId}
                plVals={plVals}
                onToggle={onToggle}
                onSelect={onSelect}
                onFocus={onFocus}
              />
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Details side panel
// ─────────────────────────────────────────────────────────────────────────────
function DetailsPanel({ empId, empMap, deptMap, plVals, onClose, onFocus }: {
  empId: string | null;
  empMap: Record<string, EmpNode>;
  deptMap: Record<string, Dept>;
  plVals: PlVal[];
  onClose: () => void;
  onFocus: (id: string) => void;
}) {
  const emp  = empId ? empMap[empId] : null;
  const open = !!emp;

  const dId      = emp ? empDeptId(emp) : '';
  const deptName = deptMap[dId]?.name || dId || '—';
  const initial  = (emp?.name || '?').charAt(0).toUpperCase();
  const colour   = emp && dId ? '#2F77B5' : '#6B7280';

  const desigLabel = (() => {
    if (!emp) return '—';
    const v = plVals.find(
      p => p.picklistId === 'DESIGNATION' &&
        (String(p.id) === String(emp.designation) || p.value === emp.designation)
    );
    return v ? v.value : (emp.designation as string | undefined) || '—';
  })();

  const manager = emp?.managerId ? empMap[emp.managerId] : null;
  const directs = emp ? emp.children.length : 0;

  function row(icon: string, label: string, value: React.ReactNode) {
    return (
      <div className="eoc-det-row" key={label}>
        <div className="eoc-det-icon"><i className={`fa-solid fa-${icon}`} /></div>
        <div>
          <div className="eoc-det-label">{label}</div>
          <div className="eoc-det-value">{value}</div>
        </div>
      </div>
    );
  }

  const chain = empId ? reportingChain(empId, empMap) : [];

  return (
    <div className={`oc-details-panel${open ? ' eoc-details-panel--open' : ''}`}>
      <div className="oc-details-header">
        <span className="oc-details-title">Employee Details</span>
        <button className="oc-details-close" title="Close" onClick={onClose}>
          <i className="fa-solid fa-xmark" />
        </button>
      </div>

      {emp && (
        <div className="oc-details-body">
          {/* Hero */}
          <div className="eoc-det-hero">
            {emp.photo
              ? <img src={emp.photo as string} alt={emp.name}
                  style={{ width: 56, height: 56, borderRadius: '50%', objectFit: 'cover', marginBottom: 10 }} />
              : <div className="eoc-det-avatar" style={{ background: avatarColor(emp.name) }}>{initial}</div>
            }
            <div className="eoc-det-name">{emp.name}</div>
            <div className="eoc-det-desg" style={{ color: colour }}>{desigLabel}</div>
            <div className="eoc-det-id">{emp.employeeId}</div>
          </div>

          {/* Details grid */}
          <div className="eoc-det-grid">
            {row('sitemap',        'Department',   deptName)}
            {row('user-tie',       'Manager',      manager ? manager.name : 'No Manager')}
            {row('users',          'Direct Reports', directs > 0 ? `${directs} person${directs !== 1 ? 's' : ''}` : 'None')}
            {row('calendar-check', 'Hire Date',    fmtDate(emp.hireDate))}
            {row('calendar-xmark', 'End Date',     fmtDate(emp.endDate))}
            {emp.businessEmail && row('envelope',  'Email',       String(emp.businessEmail))}
            {emp.mobile && row('phone',            'Mobile',      String(emp.mobile))}
            {emp.workLocation && row('location-dot', 'Location', (() => {
              const v = plVals.find(p => p.picklistId === 'LOCATION' && String(p.id) === String(emp.workLocation));
              return v ? v.value : String(emp.workLocation);
            })())}
          </div>

          {/* Reporting chain */}
          {chain.length > 1 && (
            <div className="eoc-det-section">
              <div className="eoc-det-section-title">
                <i className="fa-solid fa-route" /> Reporting Chain
              </div>
              <div className="eoc-chain-row">
                {chain.map((id, idx) => {
                  const n = empMap[id];
                  return n ? (
                    <span key={id} style={{ display: 'contents' }}>
                      {idx > 0 && <i className="fa-solid fa-angle-right eoc-chain-arrow" />}
                      <span className="eoc-chain-pill">{n.name}</span>
                    </span>
                  ) : null;
                })}
              </div>
            </div>
          )}

          {/* Actions */}
          <div className="eoc-det-actions">
            <button
              style={{ flex: 1, padding: '9px 0', borderRadius: 7, fontSize: 12, fontWeight: 600,
                cursor: 'pointer', background: '#18345B', color: '#fff', border: '1px solid #18345B' }}
              onClick={() => onFocus(emp.employeeId)}
            >
              <i className="fa-solid fa-crosshairs" /> Focus on this person
            </button>
          </div>
        </div>
      )}
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Legend
// ─────────────────────────────────────────────────────────────────────────────
function Legend({ depts, orderedDeptIds, activeDeptIds }: {
  depts: Dept[];
  orderedDeptIds: string[];
  activeDeptIds: Set<string>;
}) {
  const visible = depts.filter(d => activeDeptIds.has(d.deptId));
  if (visible.length === 0) return null;

  return (
    <div className="oc-legend" style={{ display: 'flex', flexWrap: 'wrap', gap: '8px 16px', padding: '8px 0 2px' }}>
      {visible.map(d => (
        <div key={d.deptId} style={{ display: 'flex', alignItems: 'center', gap: 6, fontSize: 12.5 }}>
          <span style={{
            width: 10, height: 10, borderRadius: '50%',
            background: deptColour(d.deptId, orderedDeptIds),
            flexShrink: 0, display: 'inline-block',
          }} />
          {d.name}
        </div>
      ))}
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Main Component — exported, used by both /org-chart and /admin/emp-org-chart
// ─────────────────────────────────────────────────────────────────────────────
export default function EmpOrgChart() {
  const { employee: authEmployee }     = useAuth();
  const { employees: supabaseEmps }    = useEmployees();
  const { departments: supabaseDepts } = useDepartments();
  const { picklistValues: plVals }     = usePicklistValues();

  // Cast to local Emp/Dept shapes (compatible supersets)
  const allEmployees = supabaseEmps as unknown as Emp[];
  const departments  = supabaseDepts as unknown as Dept[];

  const todayVal = todayStr();
  const [viewDate, setViewDate]   = useState(todayVal);
  const [searchQ,  setSearchQ]    = useState('');
  const [deptFilter, setDeptFilter] = useState('');
  const [collapsed,  setCollapsed]  = useState<Set<string>>(new Set());
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [focusId,    setFocusId]    = useState<string | null>(null);
  const [focusName,  setFocusName]  = useState('');

  // DOM refs for zoom/pan
  const viewportRef  = useRef<HTMLDivElement>(null);
  const canvasRef    = useRef<HTMLDivElement>(null);
  const zoomLabelRef = useRef<HTMLSpanElement>(null);
  const zoomRef      = useRef(1);
  const panRef       = useRef({ x: 0, y: 0 });

  // ── Current user's employee ID (from AuthContext) ──────────────────────────
  const profileEmpId = useMemo<string | null>(() => {
    // authEmployee.employeeId is the human-readable text code (e.g. EMP001)
    return authEmployee?.employeeId ?? null;
  }, [authEmployee]);

  // ── Ordered dept IDs (for consistent colour assignment) ────────────────────
  const orderedDeptIds = useMemo(
    () => departments.map(d => d.deptId),
    [departments]
  );

  const deptMap = useMemo<Record<string, Dept>>(() => {
    const m: Record<string, Dept> = {};
    // Index by both UUID (id) and text code (deptId) so employee.deptId (UUID) resolves correctly
    departments.forEach(d => {
      m[d.id]    = d;  // UUID FK match (Supabase employees store dept_id as UUID)
      m[d.deptId] = d;          // text code match (legacy compatibility)
    });
    return m;
  }, [departments]);

  // ── Active employees on the selected date ──────────────────────────────────
  const activeEmps = useMemo(
    () => allEmployees.filter(e => isActiveOn(e, viewDate)),
    [allEmployees, viewDate]
  );

  // ── Unique dept IDs actually used in this snapshot ─────────────────────────
  // Employees store dept_id as a UUID, but departments have both id (UUID) and
  // deptId (text code).  Collect both so activeDeptIds.has() works for either.
  const activeDeptIds = useMemo(() => {
    const ids = new Set<string>();
    activeEmps.forEach(e => {
      const uuid = empDeptId(e);        // UUID from employees.dept_id
      if (!uuid) return;
      ids.add(uuid);
      // Also add the matching text code so d.deptId comparisons work in legend/filter
      const dept = deptMap[uuid];
      if (dept?.deptId) ids.add(dept.deptId);
    });
    return ids;
  }, [activeEmps, deptMap]);

  // ── Apply dept filter + search ─────────────────────────────────────────────
  const filteredEmps = useMemo(() => {
    let list = activeEmps;
    if (deptFilter) list = list.filter(e => empDeptId(e) === deptFilter);
    if (searchQ.trim()) {
      const q = searchQ.trim().toLowerCase();
      // keep matched + their ancestors (for coherence)
      const { empMap: tmpMap } = buildEmpTree(list);
      const matchIds = new Set(
        list.filter(e =>
          e.name.toLowerCase().includes(q) ||
          e.employeeId.toLowerCase().includes(q)
        ).map(e => e.employeeId)
      );
      matchIds.forEach(id => {
        reportingChain(id, tmpMap).forEach(aid => matchIds.add(aid));
      });
      list = list.filter(e => matchIds.has(e.employeeId));
    }
    return list;
  }, [activeEmps, deptFilter, searchQ]);

  // ── Focus filter: if focusId set, restrict to that subtree ────────────────
  const displayEmps = useMemo(() => {
    if (!focusId) return filteredEmps;
    const { empMap: tmpMap } = buildEmpTree(filteredEmps);
    const subs = new Set([focusId, ...allSubs(focusId, tmpMap)]);
    // also include ancestors for context
    reportingChain(focusId, tmpMap).forEach(id => subs.add(id));
    return filteredEmps.filter(e => subs.has(e.employeeId));
  }, [filteredEmps, focusId]);

  // ── Build tree ─────────────────────────────────────────────────────────────
  const { empMap, roots } = useMemo(() => buildEmpTree(displayEmps), [displayEmps]);

  // ── Highlight map ──────────────────────────────────────────────────────────
  const highlightMap = useMemo<Record<string, string>>(() => {
    const map: Record<string, string> = {};
    const target = focusId || selectedId;
    if (!target || !empMap[target]) return map;

    const chain = reportingChain(target, empMap);
    const subs  = allSubs(target, empMap);

    Object.keys(empMap).forEach(id => {
      if (id === target)              map[id] = 'eoc-card--selected';
      else if (chain.includes(id))    map[id] = 'eoc-card--chain';
      else if (subs.includes(id))     map[id] = 'eoc-card--sub';
      else                            map[id] = 'eoc-card--dimmed';
    });
    return map;
  }, [focusId, selectedId, empMap]);

  // ── Transform helpers ──────────────────────────────────────────────────────
  const applyTransform = useCallback(() => {
    if (canvasRef.current) {
      canvasRef.current.style.transform =
        `translate(${panRef.current.x}px,${panRef.current.y}px) scale(${zoomRef.current})`;
      canvasRef.current.style.transformOrigin = '0 0';
    }
    if (zoomLabelRef.current) {
      zoomLabelRef.current.textContent = Math.round(zoomRef.current * 100) + '%';
    }
  }, []);

  const resetView = useCallback(() => {
    setTimeout(() => {
      const vp = viewportRef.current;
      const cv = canvasRef.current;
      if (!vp || !cv) return;
      const vw = vp.clientWidth;
      const cw = cv.scrollWidth;
      zoomRef.current  = 1;
      panRef.current.x = Math.max(0, (vw - cw) / 2);
      panRef.current.y = 40;
      applyTransform();
    }, 80);
  }, [applyTransform]);

  // ── Zoom/pan events ────────────────────────────────────────────────────────
  useEffect(() => {
    if (!viewportRef.current) return;
    const viewport = viewportRef.current!;
    let dragging  = false;
    let dragStart = { x: 0, y: 0, px: 0, py: 0 };

    function onWheel(e: WheelEvent) {
      e.preventDefault();
      const factor  = e.deltaY > 0 ? 0.9 : 1.1;
      const newZoom = Math.max(0.25, Math.min(2.5, zoomRef.current * factor));
      const rect    = viewport.getBoundingClientRect();
      panRef.current.x = (e.clientX - rect.left) - ((e.clientX - rect.left) - panRef.current.x) * (newZoom / zoomRef.current);
      panRef.current.y = (e.clientY - rect.top)  - ((e.clientY - rect.top)  - panRef.current.y) * (newZoom / zoomRef.current);
      zoomRef.current  = newZoom;
      applyTransform();
    }

    function onMouseDown(e: MouseEvent) {
      const t = e.target as Element;
      if (t.closest('.eoc-card') || t.closest('.eoc-toggle-btn')) return;
      dragging         = true;
      dragStart        = { x: e.clientX, y: e.clientY, px: panRef.current.x, py: panRef.current.y };
      viewport.style.cursor = 'grabbing';
      e.preventDefault();
    }

    function onMouseMove(e: MouseEvent) {
      if (!dragging) return;
      panRef.current.x = dragStart.px + (e.clientX - dragStart.x);
      panRef.current.y = dragStart.py + (e.clientY - dragStart.y);
      applyTransform();
    }

    function onMouseUp() {
      if (!dragging) return;
      dragging = false;
      viewport.style.cursor = 'grab';
    }

    viewport.addEventListener('wheel', onWheel, { passive: false });
    viewport.addEventListener('mousedown', onMouseDown);
    document.addEventListener('mousemove', onMouseMove);
    document.addEventListener('mouseup', onMouseUp);

    return () => {
      viewport.removeEventListener('wheel', onWheel);
      viewport.removeEventListener('mousedown', onMouseDown);
      document.removeEventListener('mousemove', onMouseMove);
      document.removeEventListener('mouseup', onMouseUp);
    };
  }, [applyTransform]);

  // ── SVG connector lines ────────────────────────────────────────────────────
  //
  // requestAnimationFrame — lets the browser finish layout before reading
  // positions. Newly expanded/collapsed subtrees may not have their final
  // getBoundingClientRect values until the next frame.
  //
  // Divide by zoomRef.current — getBoundingClientRect is viewport-space;
  // the SVG lives inside the transformed canvas (canvas-local = pre-scale).
  // Without the division lines drift at any zoom other than 100%.
  //
  // Explicit deps array — previously missing, causing a redraw on every
  // render including unrelated state changes.
  useEffect(() => {
    let rafId: number;

    function drawLines() {
      const canvas = canvasRef.current;
      if (!canvas) return;

      const oldSvg = canvas.querySelector('#eoc-svg-lines');
      if (oldSvg) oldSvg.remove();

      const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
      svg.id = 'eoc-svg-lines';
      svg.style.cssText =
        'position:absolute;top:0;left:0;width:1px;height:1px;pointer-events:none;overflow:visible;z-index:0;';

      const canvasRect = canvas.getBoundingClientRect();
      const zoom       = zoomRef.current;

      canvas.querySelectorAll<HTMLElement>('.eoc-children-row[data-parent-id]').forEach(row => {
        const parentId   = row.dataset.parentId;
        if (!parentId) return;
        const parentCard = canvas.querySelector<HTMLElement>(`.eoc-card[data-emp-id="${parentId}"]`);
        if (!parentCard) return;
        const childCards = Array.from(
          row.querySelectorAll<HTMLElement>(':scope > .eoc-child-wrap > .eoc-node-wrap > .eoc-card')
        );
        if (!childCards.length) return;

        const pr  = parentCard.getBoundingClientRect();
        // Convert viewport coords → canvas-local coords by dividing by zoom
        const px  = (pr.left + pr.width / 2 - canvasRect.left) / zoom;
        const py  = (pr.bottom               - canvasRect.top)  / zoom;
        const gap = 24;

        const pts = childCards.map(c => {
          const r = c.getBoundingClientRect();
          return {
            x: (r.left + r.width / 2 - canvasRect.left) / zoom,
            y: (r.top                - canvasRect.top)  / zoom,
          };
        });

        const onChain = parentCard.classList.contains('eoc-card--chain') ||
                        parentCard.classList.contains('eoc-card--selected');
        const lineCol = onChain ? '#3B82F6' : '#C8D8EA';
        const lineW   = onChain ? '2.5' : '1.5';

        function mkLine(x1: number, y1: number, x2: number, y2: number) {
          const el = document.createElementNS('http://www.w3.org/2000/svg', 'line');
          el.setAttribute('x1', String(x1)); el.setAttribute('y1', String(y1));
          el.setAttribute('x2', String(x2)); el.setAttribute('y2', String(y2));
          el.setAttribute('stroke', lineCol);
          el.setAttribute('stroke-width', lineW);
          el.setAttribute('stroke-linecap', 'round');
          svg.appendChild(el);
        }

        const barY = py + gap;
        if (pts.length === 1) {
          mkLine(px, py, pts[0].x, pts[0].y);
        } else {
          mkLine(px, py, px, barY);
          const minX = Math.min(...pts.map(p => p.x));
          const maxX = Math.max(...pts.map(p => p.x));
          mkLine(minX, barY, maxX, barY);
          pts.forEach(p => mkLine(p.x, barY, p.x, p.y));
        }
      });

      canvas.insertBefore(svg, canvas.firstChild);
    }

    rafId = requestAnimationFrame(drawLines);
    return () => cancelAnimationFrame(rafId);
  }, [collapsed, searchQ, viewDate, deptFilter, displayEmps, selectedId, focusId]);

  // ── Reset view when tree changes ───────────────────────────────────────────
  useEffect(() => { resetView(); }, [roots.length, focusId, resetView]);

  // ── Close details panel on outside click ───────────────────────────────────
  useEffect(() => {
    function onClickOutside(e: MouseEvent) {
      const t = e.target as Element;
      if (t.closest('.oc-details-panel') || t.closest('.eoc-card')) return;
      if (selectedId) setSelectedId(null);
    }
    document.addEventListener('click', onClickOutside);
    return () => document.removeEventListener('click', onClickOutside);
  }, [selectedId]);

  // ── Handlers ───────────────────────────────────────────────────────────────
  function handleToggle(id: string) {
    setCollapsed(prev => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id); else next.add(id);
      return next;
    });
  }

  function handleSelect(id: string) {
    setSelectedId(prev => prev === id ? null : id);
  }

  function handleFocus(id: string) {
    const emp = empMap[id];
    setFocusId(id);
    setFocusName(emp?.name || id);
    setSelectedId(null);
  }

  function clearFocus() { setFocusId(null); setFocusName(''); }

  function expandAll() {
    setCollapsed(new Set());
  }

  function collapseAll() {
    setCollapsed(new Set(Object.keys(empMap)));
  }

  // Zoom buttons
  function zoomIn()  { zoomRef.current = Math.min(2.5, zoomRef.current * 1.15); applyTransform(); }
  function zoomOut() { zoomRef.current = Math.max(0.25, zoomRef.current / 1.15); applyTransform(); }

  // ── Date label ─────────────────────────────────────────────────────────────
  const dateLabel = viewDate === todayVal
    ? `Viewing organisation as of Today (${new Date().toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric' })})`
    : `Viewing organisation as of ${new Date(viewDate + 'T00:00:00').toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric' })}`;

  // ─────────────────────────────────────────────────────────────────────────
  return (
    <div className="page-content" style={{ padding: '28px 32px', display: 'flex', flexDirection: 'column', height: 'calc(100vh - 60px)', overflow: 'hidden' }}>
      <h2 className="page-title" style={{ marginBottom: 18, flexShrink: 0 }}>Employee Organisation Chart</h2>

      {/* ── Toolbar ── */}
      <div className="oc-toolbar" style={{ flexShrink: 0 }}>
        <div className="oc-toolbar-left">
          <div className="oc-search-wrap">
            <i className="fa-solid fa-magnifying-glass" />
            <input
              type="text"
              placeholder="Search employee…"
              value={searchQ}
              onChange={e => setSearchQ(e.target.value)}
              autoComplete="off"
            />
            {searchQ && (
              <button className="oc-search-clear" onClick={() => setSearchQ('')} title="Clear">
                <i className="fa-solid fa-xmark" />
              </button>
            )}
          </div>
          <select
            className="oc-filter-select"
            value={deptFilter}
            onChange={e => setDeptFilter(e.target.value)}
          >
            <option value="">All Departments</option>
            {departments
              .filter(d => activeDeptIds.has(d.id || '') || activeDeptIds.has(d.deptId))
              .map(d => {
                // Use UUID as option value so it matches empDeptId() (emp.deptId = UUID FK)
                const val = d.id || d.deptId;
                return <option key={val} value={val}>{d.name}</option>;
              })
            }
          </select>
        </div>
        <div className="oc-toolbar-right">
          <button className="oc-btn oc-btn-ghost" onClick={expandAll}>
            <i className="fa-solid fa-expand" /> Expand All
          </button>
          <button className="oc-btn oc-btn-ghost" onClick={collapseAll}>
            <i className="fa-solid fa-compress" /> Collapse All
          </button>
          <div className="oc-zoom-group">
            <button className="oc-zoom-btn" onClick={zoomOut}>−</button>
            <span className="oc-zoom-label" ref={zoomLabelRef}>100%</span>
            <button className="oc-zoom-btn" onClick={zoomIn}>+</button>
            <button className="oc-btn oc-btn-ghost oc-zoom-reset" onClick={resetView} title="Reset view">
              <i className="fa-solid fa-arrows-to-dot" />
            </button>
          </div>
        </div>
      </div>

      {/* ── Date bar ── */}
      <div className="oc-date-bar" style={{ flexShrink: 0 }}>
        <i className="fa-solid fa-calendar-day" />
        <label>View as of</label>
        <input
          type="date"
          className="oc-date-input"
          value={viewDate}
          onChange={e => setViewDate(e.target.value || todayVal)}
        />
        <span className="oc-date-viewing">{dateLabel}</span>
      </div>

      {/* ── Focus banner ── */}
      {focusId && (
        <div className="oc-focus-bar" style={{ flexShrink: 0 }}>
          <i className="fa-solid fa-crosshairs" />
          <span>Focused on <strong>{focusName}</strong></span>
          <button className="oc-btn oc-btn-ghost oc-focus-clear" onClick={clearFocus}>
            <i className="fa-solid fa-xmark" /> Clear Focus
          </button>
        </div>
      )}

      {/* ── Legend ── */}
      <Legend depts={departments} orderedDeptIds={orderedDeptIds} activeDeptIds={activeDeptIds} />

      {/* ── Chart area + details panel ── */}
      <div style={{ flex: 1, position: 'relative', overflow: 'hidden', marginTop: 8 }}>
        {/* Viewport */}
        <div
          className="oc-viewport"
          ref={viewportRef}
          onClick={() => { if (selectedId) setSelectedId(null); }}
          style={{ width: '100%', height: '100%', cursor: 'grab', overflow: 'hidden', position: 'relative' }}
        >
          <div className="oc-canvas" ref={canvasRef} style={{ display: 'inline-block', position: 'relative' }}>
            {roots.length === 0 ? (
              <div style={{ padding: '60px 40px', textAlign: 'center', color: '#9CA3AF' }}>
                <i className="fa-solid fa-users" style={{ fontSize: 36, display: 'block', marginBottom: 12 }} />
                {allEmployees.length === 0
                  ? 'No active employees. Add employees from Admin → Add New Employee.'
                  : 'No employees match the current filters.'
                }
              </div>
            ) : (
              <div style={{ display: 'flex', gap: 32, alignItems: 'flex-start', padding: '40px 40px 80px' }}>
                {roots.map(root => (
                  <div key={root.employeeId} className="eoc-child-wrap">
                    <OrgNode
                      node={root}
                      collapsed={collapsed}
                      highlightMap={highlightMap}
                      empMap={empMap}
                      deptMap={deptMap}
                      orderedDeptIds={orderedDeptIds}
                      profileEmpId={profileEmpId}
                      plVals={plVals}
                      onToggle={handleToggle}
                      onSelect={handleSelect}
                      onFocus={handleFocus}
                    />
                  </div>
                ))}
              </div>
            )}
          </div>
        </div>

        {/* Details panel */}
        <DetailsPanel
          empId={selectedId}
          empMap={empMap}
          deptMap={deptMap}
          plVals={plVals}
          onClose={() => setSelectedId(null)}
          onFocus={handleFocus}
        />
      </div>
    </div>
  );
}
