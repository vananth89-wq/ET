import { useState, useMemo, useEffect, useRef, useCallback } from 'react';
import { useEmployees, type Employee } from '../../hooks/useEmployees';
import { useDepartments } from '../../hooks/useDepartments';
import { usePicklistValues } from '../../hooks/usePicklistValues';
import { type Department, getDeptStatus, fmtDate, getAvatarColor } from './Departments';

// ─────────────────────────────────────────────────────────────────────────────
// Types
// ─────────────────────────────────────────────────────────────────────────────

interface TreeNode extends Department {
  children: TreeNode[];
}

type DocMap = Record<string, TreeNode>;

interface PicklistVal {
  id: string; picklistId: string; value: string; active?: boolean;
  meta?: Record<string, string>;
}

// ─────────────────────────────────────────────────────────────────────────────
// Constants
// ─────────────────────────────────────────────────────────────────────────────

const DOC_PALETTE = [
  { bg: '#EBF4FF', border: '#3B82F6', avatar: '#1D4ED8' },
  { bg: '#F0FDF4', border: '#22C55E', avatar: '#15803D' },
  { bg: '#FFF7ED', border: '#F97316', avatar: '#C2410C' },
  { bg: '#FDF4FF', border: '#A855F7', avatar: '#7E22CE' },
  { bg: '#FFF1F2', border: '#F43F5E', avatar: '#BE123C' },
  { bg: '#F0FDFA', border: '#14B8A6', avatar: '#0F766E' },
  { bg: '#FFFBEB', border: '#EAB308', avatar: '#A16207' },
  { bg: '#F5F3FF', border: '#8B5CF6', avatar: '#6D28D9' },
  { bg: '#ECFEFF', border: '#06B6D4', avatar: '#0E7490' },
  { bg: '#FFF0F0', border: '#EF4444', avatar: '#B91C1C' },
];

function docColor(deptId: string) {
  let n = 0;
  for (const c of String(deptId || 'a')) n += c.charCodeAt(0);
  return DOC_PALETTE[Math.abs(n) % DOC_PALETTE.length];
}

// ─────────────────────────────────────────────────────────────────────────────
// Pure tree helpers
// ─────────────────────────────────────────────────────────────────────────────

function buildTree(deptList: Department[]): { docMap: DocMap; docRoots: TreeNode[] } {
  const docMap: DocMap = {};
  const docRoots: TreeNode[] = [];

  deptList.forEach(d => { docMap[d.deptId] = { ...d, children: [] }; });
  deptList.forEach(d => {
    if (d.parentDeptId && docMap[d.parentDeptId]) {
      docMap[d.parentDeptId].children.push(docMap[d.deptId]);
    } else {
      docRoots.push(docMap[d.deptId]);
    }
  });

  function sortChildren(node: TreeNode) {
    node.children.sort((a, b) => a.name.localeCompare(b.name));
    node.children.forEach(sortChildren);
  }
  docRoots.forEach(sortChildren);

  return { docMap, docRoots };
}

function getSubDeptCount(deptId: string, docMap: DocMap): number {
  const node = docMap[deptId];
  if (!node) return 0;
  return node.children.reduce((sum, c) => sum + 1 + getSubDeptCount(c.deptId, docMap), 0);
}

function getReportingChain(deptId: string, docMap: DocMap): string[] {
  const chain: string[] = [];
  let cur: TreeNode | undefined = docMap[deptId];
  while (cur) {
    chain.unshift(cur.deptId);
    cur = cur.parentDeptId ? docMap[cur.parentDeptId] : undefined;
  }
  return chain;
}

function getAllSubDepts(deptId: string, docMap: DocMap): string[] {
  const node = docMap[deptId];
  if (!node) return [];
  return node.children.flatMap(c => [c.deptId, ...getAllSubDepts(c.deptId, docMap)]);
}

// ─────────────────────────────────────────────────────────────────────────────
// OrgNode — recursive card renderer
// ─────────────────────────────────────────────────────────────────────────────

interface OrgNodeProps {
  node: TreeNode;
  collapsed: Set<string>;
  highlightMap: Record<string, string>;
  employees: Employee[];
  docMap: DocMap;
  onToggle: (id: string) => void;
  onSelect: (id: string) => void;
  onFocus:  (id: string) => void;
}

function OrgNode({ node, collapsed, highlightMap, employees, docMap, onToggle, onSelect, onFocus }: OrgNodeProps) {
  const color       = docColor(node.deptId);
  const initial     = (node.name || '?').charAt(0).toUpperCase();
  const hasChildren = node.children.length > 0;
  const isCollapsed = collapsed.has(node.deptId);
  const subCount    = getSubDeptCount(node.deptId, docMap);
  // e.deptId is a UUID FK → departments.id; node.id is the department's UUID
  const empCount    = employees.filter(e => e.deptId === node.id).length;
  // headEmployeeId is a UUID FK → employees.id; match against e.id (UUID)
  const headEmp     = node.headEmployeeId ? employees.find(e => e.id === node.headEmployeeId) : null;
  const headName    = headEmp ? headEmp.name : (node.headEmployeeId ? '(Unknown)' : 'No Head');
  const parentName  = node.parentDeptId && docMap[node.parentDeptId]
    ? docMap[node.parentDeptId].name : null;
  const highlight   = highlightMap[node.deptId] || '';

  return (
    <div className="eoc-node-wrap" data-dept-id={node.deptId}>
      {/* Card */}
      <div
        className={`eoc-card doc-dept-card${highlight ? ' ' + highlight : ''}`}
        data-dept-id={node.deptId}
        style={{ background: color.bg, borderColor: color.border } as React.CSSProperties}
        onClick={e => { e.stopPropagation(); onSelect(node.deptId); }}
        onDoubleClick={e => { e.preventDefault(); e.stopPropagation(); onFocus(node.deptId); }}
        title={`${node.name} — click for details, double-click to focus`}
      >
        <div className="eoc-avatar" style={{ background: color.avatar }}>{initial}</div>
        <div className="eoc-card-body">
          <div className="eoc-card-name">{node.name}</div>
          <div className="eoc-card-desg">
            <i className="fa-solid fa-user-tie" style={{ fontSize: 10, marginRight: 3 }} />
            {headName}
          </div>
          {parentName && <div className="eoc-card-dept">{parentName}</div>}
          <div className="eoc-card-id">{node.deptId}</div>
        </div>
        <div className="eoc-team-badge">
          <i className="fa-solid fa-users" />{' '}{empCount} emp
          {subCount > 0 && (
            <> &nbsp;·&nbsp; <i className="fa-solid fa-sitemap" />{' '}{subCount} sub</>
          )}
        </div>
      </div>

      {/* Toggle button */}
      {hasChildren && (
        <button
          className="eoc-toggle-btn"
          data-dept-id={node.deptId}
          title={isCollapsed ? 'Expand' : 'Collapse'}
          onClick={e => { e.stopPropagation(); onToggle(node.deptId); }}
        >
          <i className={`fa-solid ${isCollapsed ? 'fa-plus' : 'fa-minus'}`} />
        </button>
      )}

      {/* Children */}
      {hasChildren && !isCollapsed && (
        <div className="eoc-children-row" data-parent-dept-id={node.deptId}>
          {node.children.map(child => (
            <div key={child.deptId} className="eoc-child-wrap">
              <OrgNode
                node={child}
                collapsed={collapsed}
                highlightMap={highlightMap}
                employees={employees}
                docMap={docMap}
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
// Details panel
// ─────────────────────────────────────────────────────────────────────────────

interface DetailsPanelProps {
  deptId: string | null;
  docMap: DocMap;
  employees: Employee[];
  onClose: () => void;
  onFocus: (id: string) => void;
  onEmpClick: (empId: string, el: HTMLElement) => void;
}

function DetailsPanel({ deptId, docMap, employees, onClose, onFocus, onEmpClick }: DetailsPanelProps) {
  const open = !!(deptId && docMap[deptId]);
  const dept = deptId ? docMap[deptId] : null;

  if (!dept) {
    return (
      <div className="oc-details-panel" style={{ right: open ? 0 : -420 }}>
        <div className="oc-details-header">
          <span className="oc-details-title">Department Details</span>
          <button className="oc-details-close" onClick={onClose}><i className="fa-solid fa-xmark" /></button>
        </div>
      </div>
    );
  }

  const color       = docColor(dept.deptId);
  const initial     = (dept.name || '?').charAt(0).toUpperCase();
  const headEmp     = dept.headEmployeeId ? employees.find(e => e.id === dept.headEmployeeId) : null;
  const headName    = headEmp ? headEmp.name : (dept.headEmployeeId ? '(Unknown)' : '—');
  const deptEmps    = employees.filter(e => e.deptId === dept.id);
  const subDepts    = dept.children.map(c => c.name);
  const parentName  = dept.parentDeptId && docMap[dept.parentDeptId]
    ? docMap[dept.parentDeptId].name : 'Top Level';
  const chain       = getReportingChain(dept.deptId, docMap);

  function detRow(icon: string, label: string, value: React.ReactNode) {
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

  return (
    <div className={`oc-details-panel${open ? ' eoc-details-panel--open' : ''}`}>
      <div className="oc-details-header">
        <span className="oc-details-title">Department Details</span>
        <button className="oc-details-close" title="Close" onClick={onClose}>
          <i className="fa-solid fa-xmark" />
        </button>
      </div>

      <div className="oc-details-body">
        {/* Hero */}
        <div className="eoc-det-hero">
          <div className="eoc-det-avatar" style={{ background: color.avatar }}>{initial}</div>
          <div className="eoc-det-name">{dept.name}</div>
          <div className="eoc-det-desg" style={{ color: '#888' }}>Department</div>
          <div className="eoc-det-id">{dept.deptId}</div>
        </div>

        {/* Grid rows */}
        <div className="eoc-det-grid">
          {detRow('user-tie',       'Department Head', headName)}
          {detRow('sitemap',        'Parent',          parentName)}
          {detRow('users',          'Employees',
            deptEmps.length === 0
              ? 'None'
              : (
                <>
                  <span style={{ display: 'block', marginBottom: 6 }}>
                    {deptEmps.length} member{deptEmps.length !== 1 ? 's' : ''}
                  </span>
                  <div className="doc-emp-list">
                    {deptEmps.map(e => (
                      <div
                        key={e.employeeId}
                        className="doc-emp-list-item"
                        title={`View ${e.name}'s details`}
                        onClick={ev => onEmpClick(e.employeeId, ev.currentTarget as HTMLElement)}
                      >
                        <span className="doc-emp-list-name">{e.name}</span>
                        <span className="doc-emp-list-id">{e.employeeId}</span>
                      </div>
                    ))}
                  </div>
                </>
              )
          )}
          {detRow('code-branch',    'Sub-Departments', subDepts.length > 0 ? subDepts.join(', ') : 'None')}
          {detRow('calendar-plus',  'Start Date',      fmtDate(dept.startDate))}
          {detRow('calendar-xmark', 'End Date',        fmtDate(dept.endDate))}
        </div>

        {/* Hierarchy chain */}
        {chain.length > 1 && (
          <div className="eoc-det-section">
            <div className="eoc-det-section-title">
              <i className="fa-solid fa-route" /> Hierarchy Chain
            </div>
            <div className="eoc-chain-row">
              {chain.map((id, idx) => {
                const n = docMap[id];
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
            className="oc-btn btn-focus-mode"
            style={{ flex: 1, padding: '9px 0', borderRadius: 7, fontSize: 12, fontWeight: 600, cursor: 'pointer', background: '#18345B', color: '#fff', border: '1px solid #18345B' }}
            onClick={() => onFocus(dept.deptId)}
          >
            <i className="fa-solid fa-crosshairs" /> Focus on this dept
          </button>
        </div>
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Employee popover
// ─────────────────────────────────────────────────────────────────────────────

interface EmpPopoverState {
  isOpen: boolean;
  emp: Employee | null;
  top: number;
  left: number;
}

function EmpPopover({ state, plVals, departments, onClose }: {
  state: EmpPopoverState;
  plVals: PicklistVal[];
  departments: Department[];
  onClose: () => void;
}) {
  if (!state.isOpen || !state.emp) return null;
  const emp = state.emp;

  // emp.deptId is a UUID FK → departments.id; match against d.id (UUID)
  const empDeptId = emp.deptId as string | null;
  const deptName = empDeptId
    ? (departments.find(d => d.id === empDeptId)?.name || empDeptId)
    : '—';
  const desigVal = plVals.find(v =>
    v.picklistId === 'DESIGNATION' &&
    (String(v.id) === String(emp.designation) || v.value === emp.designation)
  );
  const locVal = plVals.find(v =>
    v.picklistId === 'LOCATION' &&
    (String(v.id) === String(emp.workLocationId)
      || String(v.id) === String((emp as any).locationId)
      || String(v.id) === String((emp as any).workLocation))
  );
  const initial     = (emp.name || '?').charAt(0).toUpperCase();
  const avatarColor = getAvatarColor(emp.name);

  function popRow(icon: string, label: string, value: string) {
    return (
      <div className="dep-pop-row" key={label}>
        <div className="dep-pop-row-icon"><i className={`fa-solid fa-${icon}`} /></div>
        <div>
          <div className="dep-pop-row-label">{label}</div>
          <div className="dep-pop-row-value">{value || '—'}</div>
        </div>
      </div>
    );
  }

  return (
    <>
      {/* Backdrop */}
      <div
        className="doc-emp-popover-backdrop"
        style={{ display: 'block' }}
        onClick={onClose}
      />
      {/* Popover card */}
      <div
        className="doc-emp-popover"
        style={{ display: 'block', top: state.top, left: state.left }}
      >
        <button className="doc-emp-popover-close" id="doc-emp-popover-close" onClick={onClose}>
          <i className="fa-solid fa-xmark" />
        </button>
        <div className="dep-pop-hero">
          <div
            className="dep-pop-avatar"
            style={{ background: emp.photo ? 'transparent' : avatarColor }}
          >
            {emp.photo
              ? <img src={emp.photo} alt={emp.name} style={{ width: '100%', height: '100%', objectFit: 'cover', borderRadius: '50%' }} />
              : initial}
          </div>
          <div className="dep-pop-name">
            {emp.name}{' '}
            <span style={{ opacity: 0.7, fontWeight: 500, fontSize: 13 }}>({emp.employeeId})</span>
          </div>
        </div>
        <div className="dep-pop-body">
          {popRow('id-badge',     'Designation', desigVal?.value || String(emp.designation || '—'))}
          {popRow('sitemap',      'Department',  deptName)}
          {popRow('location-dot', 'Location',    locVal?.value || '—')}
          {popRow('envelope',     'Email',       String(emp.businessEmail || emp.email || '—'))}
          {popRow('phone',        'Mobile No',   String(emp.mobile || '—'))}
        </div>
      </div>
    </>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Main component
// ─────────────────────────────────────────────────────────────────────────────

export default function OrgChart() {
  const { departments: supabaseDepts } = useDepartments();
  const { employees: supabaseEmps }   = useEmployees();
  const { picklistValues: plVals }    = usePicklistValues();

  // supabaseDepts still needs a cast to the legacy TreeNode-compatible Department shape
  const departments = supabaseDepts as unknown as Department[];
  const employees   = supabaseEmps;  // typed as Employee[] from useEmployees — no cast needed

  const today = new Date().toISOString().split('T')[0];
  const [viewDate,  setViewDate]  = useState(today);
  const [searchQ,   setSearchQ]   = useState('');
  const [collapsed, setCollapsed] = useState<Set<string>>(new Set());
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [focusId,    setFocusId]    = useState<string | null>(null);
  const [focusName,  setFocusName]  = useState('');
  const [empPopover, setEmpPopover] = useState<EmpPopoverState>({ isOpen: false, emp: null, top: 0, left: 0 });

  // DOM refs
  const viewportRef  = useRef<HTMLDivElement>(null);
  const canvasRef    = useRef<HTMLDivElement>(null);
  const zoomLabelRef = useRef<HTMLSpanElement>(null);
  const zoomRef      = useRef(1);
  const panRef       = useRef({ x: 0, y: 0 });

  // ── Derived tree ──────────────────────────────────────────────────────────

  const activeDepts = useMemo(() => {
    return departments.filter(d => getDeptStatus(d, viewDate) === 'Active');
  }, [departments, viewDate]);

  const { docMap, docRoots } = useMemo(() => {
    if (activeDepts.length === 0) return { docMap: {}, docRoots: [] };

    let list = activeDepts;
    if (searchQ.trim()) {
      const q       = searchQ.trim().toLowerCase();
      const matched = new Set(
        activeDepts
          .filter(d => d.name.toLowerCase().includes(q) || d.deptId.toLowerCase().includes(q))
          .map(d => d.deptId)
      );
      // include ancestors for coherence
      const { docMap: tmpMap } = buildTree(activeDepts);
      matched.forEach(id => getReportingChain(id, tmpMap).forEach(aid => matched.add(aid)));
      list = activeDepts.filter(d => matched.has(d.deptId));
    }

    return buildTree(list);
  }, [activeDepts, searchQ]);

  // Highlight map — recompute when focus/selection changes
  const highlightMap = useMemo<Record<string, string>>(() => {
    const map: Record<string, string> = {};
    const focusTarget = focusId || selectedId;
    if (!focusTarget || !docMap[focusTarget]) return map;

    const chain = getReportingChain(focusTarget, docMap);
    const subs  = getAllSubDepts(focusTarget, docMap);

    Object.keys(docMap).forEach(id => {
      if (id === focusTarget)         map[id] = 'eoc-card--selected';
      else if (chain.includes(id))    map[id] = 'eoc-card--chain';
      else if (subs.includes(id))     map[id] = 'eoc-card--sub';
      else                            map[id] = 'eoc-card--dimmed';
    });
    return map;
  }, [focusId, selectedId, docMap]);

  // ── Transform helpers (direct DOM — no state to avoid re-renders) ─────────

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

  // ── Zoom/pan event setup (once) ───────────────────────────────────────────

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
      const mx      = e.clientX - rect.left;
      const my      = e.clientY - rect.top;
      panRef.current.x = mx - (mx - panRef.current.x) * (newZoom / zoomRef.current);
      panRef.current.y = my - (my - panRef.current.y) * (newZoom / zoomRef.current);
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
    document.addEventListener('mouseup',   onMouseUp);

    return () => {
      viewport.removeEventListener('wheel', onWheel);
      viewport.removeEventListener('mousedown', onMouseDown);
      document.removeEventListener('mousemove', onMouseMove);
      document.removeEventListener('mouseup',   onMouseUp);
    };
  }, [applyTransform]);

  // ── Draw SVG connector lines after every tree render ──────────────────────
  //
  // Two important details:
  // 1. requestAnimationFrame — lets the browser finish layout before we read
  //    positions. useLayoutEffect fires before paint but after DOM mutations;
  //    newly added/removed subtrees (expand/collapse) may not have their final
  //    getBoundingClientRect values until the next frame.
  // 2. Divide by zoomRef.current — getBoundingClientRect returns viewport-space
  //    coordinates. The SVG lives inside the transformed canvas, so its
  //    coordinate system is canvas-local (pre-scale). Without the division,
  //    lines are off by a factor of zoom at anything other than 100%.

  useEffect(() => {
    let rafId: number;

    function drawLines() {
      const canvas = canvasRef.current;
      if (!canvas) return;

      const oldSvg = canvas.querySelector('#oc-svg-lines');
      if (oldSvg) oldSvg.remove();

      const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
      svg.id = 'oc-svg-lines';
      // width/height 1px + overflow:visible — avoids percentage recalc issues
      // when the canvas size changes during expand/collapse.
      svg.style.cssText =
        'position:absolute;top:0;left:0;width:1px;height:1px;pointer-events:none;overflow:visible;z-index:0;';

      const canvasRect = canvas.getBoundingClientRect();
      const zoom       = zoomRef.current;

      canvas.querySelectorAll<HTMLElement>('.eoc-children-row[data-parent-dept-id]').forEach(row => {
        const parentId   = row.dataset.parentDeptId;
        if (!parentId) return;
        const parentCard = canvas.querySelector<HTMLElement>(`.eoc-card[data-dept-id="${parentId}"]`);
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
        const lineW   = onChain ? '2.5'    : '1.5';

        function mkLine(x1: number, y1: number, x2: number, y2: number) {
          const ln = document.createElementNS('http://www.w3.org/2000/svg', 'line');
          ln.setAttribute('x1', String(x1)); ln.setAttribute('y1', String(y1));
          ln.setAttribute('x2', String(x2)); ln.setAttribute('y2', String(y2));
          ln.setAttribute('stroke',        lineCol);
          ln.setAttribute('stroke-width',  lineW);
          ln.setAttribute('stroke-linecap','round');
          svg.appendChild(ln);
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
  }, [collapsed, searchQ, viewDate, departments, selectedId, focusId]);

  // Auto-reset view when search or date changes
  useEffect(() => { resetView(); }, [searchQ, viewDate, resetView]);

  // ── Interaction handlers ──────────────────────────────────────────────────

  function handleSelect(deptId: string) {
    setSelectedId(deptId);
  }

  function handleFocus(deptId: string) {
    const dept = docMap[deptId];
    if (!dept) return;
    setFocusId(deptId);
    setFocusName(dept.name);
    setSelectedId(deptId);
    // Expand chain + subs
    setCollapsed(prev => {
      const next = new Set(prev);
      getReportingChain(deptId, docMap).forEach(id => next.delete(id));
      getAllSubDepts(deptId, docMap).forEach(id => next.delete(id));
      return next;
    });
    setTimeout(() => {
      const card = canvasRef.current?.querySelector<HTMLElement>(`.eoc-card[data-dept-id="${deptId}"]`);
      card?.scrollIntoView({ behavior: 'smooth', block: 'center', inline: 'center' });
    }, 150);
  }

  function clearFocus() {
    setFocusId(null);
    setFocusName('');
    setSelectedId(null);
  }

  function handleToggle(deptId: string) {
    setCollapsed(prev => {
      const next = new Set(prev);
      next.has(deptId) ? next.delete(deptId) : next.add(deptId);
      return next;
    });
  }

  function expandAll() {
    setCollapsed(new Set());
  }

  function collapseAll() {
    const parents = new Set<string>();
    Object.values(docMap).forEach(n => { if (n.children.length) parents.add(n.deptId); });
    setCollapsed(parents);
  }

  function zoomIn()    { zoomRef.current = Math.min(2.5, zoomRef.current * 1.2); applyTransform(); }
  function zoomOut()   { zoomRef.current = Math.max(0.25, zoomRef.current / 1.2); applyTransform(); }
  function zoomReset() { zoomRef.current = 1; panRef.current = { x: 0, y: 0 }; applyTransform(); resetView(); }

  function handleEmpClick(empId: string, triggerEl: HTMLElement) {
    const emp = employees.find(e => e.employeeId === empId);
    if (!emp) return;
    const tRect  = triggerEl.getBoundingClientRect();
    const pW     = 300;
    const pH     = 320;
    const margin = 10;
    let left = tRect.left - pW - margin;
    if (left < margin) left = tRect.right + margin;
    if (left + pW > window.innerWidth - margin) left = Math.max(margin, window.innerWidth - pW - margin);
    let top = tRect.top + tRect.height / 2 - pH / 2;
    if (top < margin) top = margin;
    if (top + pH > window.innerHeight - margin) top = window.innerHeight - pH - margin;
    setEmpPopover({ isOpen: true, emp, top, left });
  }

  // ── Render ────────────────────────────────────────────────────────────────

  return (
    <div className="ar-panel" style={{ position: 'relative' }}>

      {/* Page title */}
      <h2 className="page-title">Organisation Chart</h2>
      <p className="page-subtitle" style={{ marginBottom: 16 }}>
        Visualise the department hierarchy. Drag to pan, scroll to zoom, click a card for details.
      </p>

      {/* Chart container */}
      <div style={{ borderRadius: 10, border: '1px solid #e8edf5', overflow: 'hidden', boxShadow: '0 2px 10px rgba(24,52,91,0.05)' }}>

        {/* Toolbar */}
        <div className="oc-toolbar">
          <div className="oc-toolbar-left">
            {/* Date filter */}
            <div className="dept-date-bar" style={{ border: 'none', padding: 0, margin: 0, background: 'transparent' }}>
              <i className="fa-regular fa-calendar" style={{ color: '#2F77B5' }} />
              <label style={{ fontSize: 13, color: '#374151', marginRight: 4 }}>View as of</label>
              <input
                type="date"
                value={viewDate}
                onChange={e => setViewDate(e.target.value || today)}
                style={{ padding: '5px 8px', border: '1px solid #D1D5DB', borderRadius: 6, fontSize: 13 }}
              />
              {viewDate === today && (
                <span style={{ fontSize: 12, color: '#2F77B5', fontWeight: 600 }}>(Today)</span>
              )}
            </div>

            {/* Search */}
            <div className="oc-search-wrap">
              <i className="fa-solid fa-magnifying-glass" />
              <input
                type="text"
                placeholder="Search department…"
                value={searchQ}
                onChange={e => setSearchQ(e.target.value)}
              />
              {searchQ && (
                <button
                  className={`oc-search-clear${searchQ ? ' visible' : ''}`}
                  onClick={() => { setSearchQ(''); clearFocus(); }}
                >
                  <i className="fa-solid fa-xmark" />
                </button>
              )}
            </div>
          </div>

          <div className="oc-toolbar-right">
            <button className="oc-btn oc-btn-ghost" onClick={expandAll}>
              <i className="fa-solid fa-maximize" /> Expand All
            </button>
            <button className="oc-btn oc-btn-ghost" onClick={collapseAll}>
              <i className="fa-solid fa-minimize" /> Collapse All
            </button>
            <div className="oc-zoom-group">
              <button className="oc-zoom-btn" title="Zoom out" onClick={zoomOut}>
                <i className="fa-solid fa-minus" />
              </button>
              <span className="oc-zoom-label" ref={zoomLabelRef}>100%</span>
              <button className="oc-zoom-btn" title="Zoom in" onClick={zoomIn}>
                <i className="fa-solid fa-plus" />
              </button>
              <button className="oc-zoom-btn" title="Reset view" onClick={zoomReset}>
                <i className="fa-solid fa-arrows-to-circle" />
              </button>
            </div>
          </div>
        </div>

        {/* Focus bar */}
        {focusId && (
          <div className="oc-focus-bar visible">
            <i className="fa-solid fa-crosshairs" />
            Focused on <strong>{focusName}</strong>
            <button className="oc-focus-clear" onClick={clearFocus}>
              <i className="fa-solid fa-xmark" /> Clear Focus
            </button>
          </div>
        )}

        {/* Viewport — clicking empty canvas closes the details panel */}
        <div
          className="oc-viewport"
          ref={viewportRef}
          onClick={() => { if (selectedId) setSelectedId(null); }}
        >
          <div className="oc-canvas" ref={canvasRef}>
            {activeDepts.length === 0 ? (
              <div className="eoc-empty">
                <i className="fa-solid fa-sitemap" />
                <p>
                  {departments.length === 0
                    ? 'No departments found. Add departments in the Departments section.'
                    : `No active departments on ${new Date(viewDate + 'T00:00:00').toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' })}.`}
                </p>
              </div>
            ) : docRoots.length === 0 ? (
              <div className="eoc-empty">
                <i className="fa-solid fa-magnifying-glass" />
                <p>No departments match the search.</p>
              </div>
            ) : (
              <div className="eoc-roots-row">
                {docRoots.map(node => (
                  <div key={node.deptId} className="eoc-root-wrap">
                    <OrgNode
                      node={node}
                      collapsed={collapsed}
                      highlightMap={highlightMap}
                      employees={employees}
                      docMap={docMap}
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
      </div>

      {/* Details panel (fixed, slides in from right) */}
      <DetailsPanel
        deptId={selectedId}
        docMap={docMap}
        employees={employees}
        onClose={() => { setSelectedId(null); }}
        onFocus={handleFocus}
        onEmpClick={handleEmpClick}
      />

      {/* Employee popover */}
      <EmpPopover
        state={empPopover}
        plVals={plVals}
        departments={departments}
        onClose={() => setEmpPopover(s => ({ ...s, isOpen: false }))}
      />
    </div>
  );
}
