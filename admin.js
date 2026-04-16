// ═══════════════════════════════════════════════════════════════════
// ── REPORTS MODULE
// ═══════════════════════════════════════════════════════════════════

/**
 * Report registry — the single source of truth for all available reports.
 * To add a new report:
 *   1. Add an entry here.
 *   2. Add a loader function below.
 *   3. Register it in REPORT_LOADERS.
 * No HTML or UI changes required.
 */
var ADMIN_REPORTS = [
    {
        id:          'expense',
        name:        'Expense Report',
        description: 'View all employee expenses and export to Excel.',
        roles:       ['admin', 'finance'],
        active:      true,
        lastUpdated: '2026-04-16'
    },
    // Future reports — uncomment and add loader when ready:
    // { id: 'currency',  name: 'Currency Summary',  description: 'Exchange rate usage across all reports.',  roles: ['admin'],           active: false, lastUpdated: '' },
    // { id: 'category',  name: 'Category Report',   description: 'Expenses broken down by category.',        roles: ['admin','finance'], active: false, lastUpdated: '' },
];

/**
 * Dispatch table — maps report ID → loader function.
 * Adding a new report module: add one entry here, define the function below.
 */
var REPORT_LOADERS = {
    expense: loadExpenseReport
};

// ── Role helper (placeholder — wire to real role system when available) ──
function getCurrentAdminRole() {
    // Return null to show all reports (no role filtering yet).
    // Future: return the logged-in admin's role string (e.g. 'finance').
    return null;
}

// ── Per-report icon mapping ───────────────────────────────────────
var RPT_ICONS = {
    expense: 'fa-file-invoice-dollar'
    // Future: payroll: 'fa-money-bill-wave', attendance: 'fa-calendar-check'
};

// ── Description overrides — user-editable, persisted to localStorage ─
function rptLoadDescOverrides() {
    try { return JSON.parse(localStorage.getItem('prowess-rpt-desc') || '{}'); }
    catch (e) { return {}; }
}
function rptSaveDescOverrides(obj) {
    localStorage.setItem('prowess-rpt-desc', JSON.stringify(obj));
}

// ── Safe HTML escape ─────────────────────────────────────────────
function rptEsc(str) {
    return String(str || '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

// ── Inline description editing ───────────────────────────────────
function rptStartEditDesc(reportId) {
    var textEl  = document.getElementById('rpt-desc-text-' + reportId);
    var editEl  = document.getElementById('rpt-desc-edit-' + reportId);
    var penBtn  = document.getElementById('rpt-pen-btn-' + reportId);
    if (!textEl || !editEl) return;
    textEl.style.display = 'none';
    if (penBtn) penBtn.style.display = 'none';
    editEl.style.display = 'block';
    var ta = document.getElementById('rpt-desc-ta-' + reportId);
    if (ta) { ta.focus(); ta.setSelectionRange(ta.value.length, ta.value.length); }
}

function rptCancelEditDesc(reportId) {
    var textEl = document.getElementById('rpt-desc-text-' + reportId);
    var editEl = document.getElementById('rpt-desc-edit-' + reportId);
    var penBtn = document.getElementById('rpt-pen-btn-' + reportId);
    if (textEl) textEl.style.display = '';
    if (penBtn) penBtn.style.display = '';
    if (editEl) editEl.style.display = 'none';
}

function rptSaveDescEdit(reportId) {
    var ta = document.getElementById('rpt-desc-ta-' + reportId);
    if (!ta) return;
    var newDesc   = ta.value.trim();
    var overrides = rptLoadDescOverrides();
    overrides[reportId] = newDesc;
    rptSaveDescOverrides(overrides);
    var textEl = document.getElementById('rpt-desc-text-' + reportId);
    if (textEl) textEl.textContent = newDesc || '—';
    rptCancelEditDesc(reportId);
}

// ── Date formatter — DD-MMM-YYYY ──────────────────────────────────
function rptFmtDate(dateStr) {
    if (!dateStr) return '—';
    var d = new Date(dateStr + 'T00:00:00');
    if (isNaN(d.getTime())) return dateStr;
    var mo = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return d.getDate().toString().padStart(2, '0') + '-' + mo[d.getMonth()] + '-' + d.getFullYear();
}

// ── Render SAP Fiori-style report list table ──────────────────────
function renderAdminReports() {
    var tbody    = document.getElementById('rpt-tbody');
    var emptyEl  = document.getElementById('rpt-list-empty');
    var countEl  = document.getElementById('rpt-list-count');
    if (!tbody) return;

    var role      = getCurrentAdminRole();
    var searchEl  = document.getElementById('rpt-list-search');
    var term      = searchEl ? searchEl.value.toLowerCase().trim() : '';
    var overrides = rptLoadDescOverrides();

    // Role filter first (never hidden — just role-gated in future)
    var pool = ADMIN_REPORTS.filter(function (r) {
        if (!role) return true;
        return !r.roles || !r.roles.length || r.roles.indexOf(role) !== -1;
    });

    // Search filter (name, description, roles)
    var visible = term
        ? pool.filter(function (r) {
            var desc = overrides[r.id] !== undefined ? overrides[r.id] : r.description;
            return r.name.toLowerCase().includes(term) ||
                   (desc || '').toLowerCase().includes(term) ||
                   (r.roles || []).some(function (ro) { return ro.toLowerCase().includes(term); });
          })
        : pool;

    // Count
    if (countEl) {
        countEl.textContent = visible.length + (visible.length !== pool.length
            ? ' of ' + pool.length : '') + ' report' + (pool.length !== 1 ? 's' : '');
    }

    // Empty state
    if (!visible.length) {
        tbody.innerHTML = '';
        if (emptyEl) emptyEl.style.display = '';
        return;
    }
    if (emptyEl) emptyEl.style.display = 'none';

    // Build rows
    var html = '';
    visible.forEach(function (report) {
        var icon  = RPT_ICONS[report.id] || 'fa-chart-bar';
        var desc  = overrides[report.id] !== undefined ? overrides[report.id] : report.description;
        var roles = (report.roles || []).map(function (r) {
            return '<span class="rpt-role-badge">' + rptEsc(r) + '</span>';
        }).join('');
        var statusCls = report.active ? 'rpt-list-status-active' : 'rpt-list-status-inactive';
        var statusLbl = report.active ? 'Active'                 : 'Inactive';
        var dateStr   = rptFmtDate(report.lastUpdated);

        html +=
            '<tr class="rpt-list-row">' +

            /* Name */
            '<td><div class="rpt-name-cell">' +
                '<span class="rpt-name-icon"><i class="fa-solid ' + rptEsc(icon) + '"></i></span>' +
                '<span class="rpt-name-text">'  + rptEsc(report.name) + '</span>' +
            '</div></td>' +

            /* Description (editable) */
            '<td class="rpt-list-td-desc"><div class="rpt-card-desc-area">' +
                '<p class="rpt-card-desc" id="rpt-desc-text-' + report.id + '">' + rptEsc(desc) + '</p>' +
                '<button class="rpt-pen-btn" id="rpt-pen-btn-' + report.id + '" ' +
                        'data-action="edit-desc" data-report-id="' + report.id + '" title="Edit description">' +
                    '<i class="fa-solid fa-pen"></i>' +
                '</button>' +
                '<div class="rpt-desc-edit-wrap" id="rpt-desc-edit-' + report.id + '" style="display:none;">' +
                    '<textarea class="rpt-desc-ta" id="rpt-desc-ta-' + report.id + '" rows="2">' + rptEsc(desc) + '</textarea>' +
                    '<div class="rpt-desc-edit-actions">' +
                        '<button class="rpt-desc-save" data-action="save-desc" data-report-id="' + report.id + '">' +
                            '<i class="fa-solid fa-check"></i> Save' +
                        '</button>' +
                        '<button class="rpt-desc-cancel" data-action="cancel-desc" data-report-id="' + report.id + '">' +
                            '<i class="fa-solid fa-xmark"></i>' +
                        '</button>' +
                    '</div>' +
                '</div>' +
            '</div></td>' +

            /* Roles */
            '<td><div class="rpt-roles-wrap">' + (roles || '<span style="color:#c8d6ea;font-size:12px">—</span>') + '</div></td>' +

            /* Status */
            '<td><span class="rpt-list-status ' + statusCls + '">' + statusLbl + '</span></td>' +

            /* Last Updated */
            '<td class="rpt-list-td-date">' + dateStr + '</td>' +

            /* Action */
            '<td class="rpt-list-td-action">' +
                '<button class="rpt-list-view-btn" data-action="view" data-report-id="' + report.id + '">' +
                    'View <i class="fa-solid fa-arrow-right"></i>' +
                '</button>' +
            '</td>' +

            '</tr>';
    });
    tbody.innerHTML = html;
}

// ── Navigate to a report detail screen ───────────────────────────
function loadAdminReport(reportId) {
    var report = ADMIN_REPORTS.find(function (r) { return r.id === reportId; });
    if (!report) return;

    // Panel swap: hide list, show detail
    document.getElementById('rpt-list-panel').style.display   = 'none';
    document.getElementById('rpt-detail-panel').style.display = 'block';
    document.getElementById('rpt-detail-title').textContent   = report.name;
    document.getElementById('rpt-detail-content').innerHTML   = '';

    // Dispatch to the correct loader
    var loader = REPORT_LOADERS[reportId];
    if (typeof loader === 'function') {
        loader(report);
    } else {
        document.getElementById('rpt-detail-content').innerHTML =
            '<p class="rpt-not-implemented">This report module is not yet implemented.</p>';
    }
}

// ── Back to report list ───────────────────────────────────────────
function showRptList() {
    document.getElementById('rpt-detail-panel').style.display = 'none';
    document.getElementById('rpt-list-panel').style.display   = 'block';
}

// ═══════════════════════════════════════════════════════════════════
// ── EXPENSE REPORT — Full admin screen with charts, currency, pagination
// ═══════════════════════════════════════════════════════════════════

var _erAllRows      = [];   // flat enriched rows (all data)
var _erFiltered     = [];   // after filters applied
var _erResizeTimer  = null;
var _erPage         = 1;
var _erPageSize     = 20;
var _erViewCurrency = 'INR'; // 'INR' | 'SAR' | 'PKR' | 'LKR'
var _erCharts       = {};    // { bar, donut, line } — Chart.js instances

/* Fallback rates: 1 [CCY] = X INR, keyed by year.
   Approximate mid-market historical averages.
   Override any value via prowess-exchange-rates in localStorage. */
var _erFxFallback = {
    INR: { '2023': 1,     '2024': 1,     '2025': 1,     '2026': 1     },
    SAR: { '2023': 22.38, '2024': 22.50, '2025': 22.60, '2026': 22.70 },
    PKR: { '2023': 0.288, '2024': 0.299, '2025': 0.300, '2026': 0.302 },
    LKR: { '2023': 0.252, '2024': 0.272, '2025': 0.270, '2026': 0.287 }
};

var _erFilters = {
    search: '', employees: [], departments: [],
    projects: [], statuses: [],
    expFrom: '', expTo: '', appFrom: '', appTo: ''
};

// ── Entry point ────────────────────────────────────────────────────
function loadExpenseReport(report) {
    // Destroy any existing Chart.js instances
    Object.values(_erCharts).forEach(function(c){ if (c) c.destroy(); });
    _erCharts = {};

    // Reset state
    _erFilters = {
        search: '', employees: [], departments: [],
        projects: [], statuses: [],
        expFrom: '', expTo: '', appFrom: '', appTo: ''
    };
    _erViewCurrency = 'INR';
    _erPage = 1;

    // Render shell HTML
    document.getElementById('rpt-detail-content').innerHTML = _erBuildShell();

    try {
        // Load and flatten localStorage data
        _erAllRows  = _erFlattenData();
        _erFiltered = _erAllRows.slice();

        // Populate filter dropdowns
        _erPopulateMS();

        // Wire all event listeners
        _erWireEvents();

        // Initial render
        _erApplyFilters();
        setTimeout(function() { _erSizeTable(); _erUpdateStickyTop(); _erSyncColWidths(); }, 60);
    } catch (err) {
        var tb = document.getElementById('er-tbody');
        if (tb) tb.innerHTML = '<tr><td colspan="13" class="er-empty" style="color:#D32F2F">' +
            '<i class="fa-solid fa-circle-xmark"></i>' +
            '<span>Error loading report: ' + String(err.message || err) + '</span></td></tr>';
        console.error('[ExpenseReport] loadExpenseReport error:', err);
    }
}

// ── Flatten all reports → one row per line item ────────────────────
function _erFlattenData() {
    var reports   = JSON.parse(localStorage.getItem('prowess-expense-reports') || '[]');
    var employees = JSON.parse(localStorage.getItem('prowess-employees')       || '[]');
    var depts     = JSON.parse(localStorage.getItem('prowess-departments')     || '[]');
    var projects  = JSON.parse(localStorage.getItem('prowess-projects')        || '[]');
    var rows = [];

    reports.forEach(function (rpt) {
        var emp  = employees.find(function (e) { return e.employeeId === rpt.employeeId; });
        var dept = emp ? depts.find(function (d) { return d.deptId === emp.departmentId; }) : null;

        (rpt.lineItems || []).forEach(function (li) {
            var proj = projects.find(function (p) { return String(p.id) === String(li.projectId); });
            rows.push({
                reportId:        rpt.id,
                reportName:      rpt.name || '—',
                status:          rpt.status || 'draft',
                baseCurrency:    rpt.baseCurrencyCode || 'INR',
                createdAt:       rpt.createdAt   || '',
                submittedAt:     rpt.submittedAt || '',
                approvedAt:      rpt.approvedAt  || '',
                employeeId:      rpt.employeeId  || '',
                empName:         emp  ? (emp.name || rpt.employeeId || '—') : (rpt.employeeId || '—'),
                deptId:          emp  ? (emp.departmentId || '') : '',
                deptName:        dept ? (dept.name || '—') : '—',
                liId:            li.id,
                category:        li.category_name || li.category_id || '—',
                date:            li.date          || '',
                projectId:       String(li.projectId || ''),
                projectName:     proj ? (proj.name || String(li.projectId) || '—') : (li.projectId ? String(li.projectId) : '—'),
                amount:          Number(li.amount || 0),
                currencyCode:    li.currencyCode  || rpt.baseCurrencyCode || 'INR',
                exchangeRate:    li.exchangeRate  || null,
                convertedAmount: Number(li.convertedAmount || li.amount || 0), // in base (INR)
                note:            li.note || ''
            });
        });
    });
    return rows;
}

// ── Exchange rate lookup: 1 [ccy] = ? INR ─────────────────────────
// Checks prowess-exchange-rates localStorage first, falls back to
// _erFxFallback table. Supports INR, SAR, PKR, LKR.
function _erGetFxRate(ccy, date) {
    if (ccy === 'INR') return 1;

    // 1. Try prowess-exchange-rates { date, fromCcy, toCcy, rate }
    var stored = JSON.parse(localStorage.getItem('prowess-exchange-rates') || '[]');
    var match = stored.find(function(r) {
        return r.date === date && r.fromCcy === ccy && r.toCcy === 'INR';
    });
    if (match) return Number(match.rate);
    // Also accept INR→CCY direction and invert
    match = stored.find(function(r) {
        return r.date === date && r.fromCcy === 'INR' && r.toCcy === ccy;
    });
    if (match && Number(match.rate)) return 1 / Number(match.rate);

    // 2. Fallback: built-in approximate year-keyed rate
    var year   = (date || String(new Date().getFullYear())).substring(0, 4);
    var ccyMap = _erFxFallback[ccy];
    if (!ccyMap) return 1; // unknown currency — no conversion
    return ccyMap[year] || ccyMap['2025'] || 1;
}

// ── Convert a row's amount to the view currency ────────────────────
// Conversion model:
//   • INR  → return convertedAmount  (base currency, stored directly)
//   • SAR/PKR/LKR → if row was originally that currency with a stored
//     exchangeRate, return the original amount (source-of-truth);
//     otherwise divide convertedAmount (INR) by the 1-CCY-in-INR rate.
function _erConvertToView(row) {
    var ccy = _erViewCurrency;
    if (ccy === 'INR') return row.convertedAmount;

    // Original expense in same currency AND stored rate → use directly
    if (row.currencyCode === ccy && row.exchangeRate) return row.amount;

    // Cross-convert: INR → target = convertedAmount ÷ (1 CCY = X INR)
    var rate = _erGetFxRate(ccy, row.date);
    return rate > 0 ? row.convertedAmount / rate : row.convertedAmount;
}

// ── Currency symbol helper ─────────────────────────────────────────
function _erCcySym(ccy) {
    return { INR: '₹', SAR: '﷼', PKR: '₨', LKR: 'Rs' }[ccy] || ccy;
}

// ── Format date string to DD-MMM-YY ───────────────────────────────
function _erFmtDate(str) {
    if (!str) return '—';
    var d = new Date((str.length === 10 ? str + 'T00:00:00' : str));
    if (isNaN(d.getTime())) return str;
    var mo = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return String(d.getDate()).padStart(2,'0') + '-' + mo[d.getMonth()] + '-' + String(d.getFullYear()).substring(2);
}

// ── Build HTML shell ───────────────────────────────────────────────
function _erBuildShell() {
    return (
        '<div class="er-page">' +

        /* ═══ STICKY TOOLBAR ═══════════════════════════════════════ */
        '<div class="er-toolbar" id="er-toolbar">' +

            /* Row 1 — search + multi-selects + date ranges */
            '<div class="er-filters-row">' +
                '<div class="er-chip er-chip-search">' +
                    '<i class="fa-solid fa-magnifying-glass er-chip-icon"></i>' +
                    '<input type="text" id="er-search" class="er-search-inp" placeholder="Search employee, report, note…" autocomplete="off" />' +
                '</div>' +
                _erMSChip('emp',    'fa-user',          'Employee') +
                _erMSChip('dept',   'fa-sitemap',       'Department') +
                _erMSChip('proj',   'fa-folder-open',   'Project') +
                _erMSChip('status', 'fa-tag',           'Status') +
                '<div class="er-chip er-chip-date">' +
                    '<i class="fa-solid fa-calendar-days er-chip-icon"></i>' +
                    '<span class="er-date-lbl">Expense</span>' +
                    '<input type="date" id="er-exp-from" class="er-date-inp" />' +
                    '<span class="er-date-sep">–</span>' +
                    '<input type="date" id="er-exp-to"   class="er-date-inp" />' +
                '</div>' +
                '<div class="er-chip er-chip-date">' +
                    '<i class="fa-solid fa-calendar-check er-chip-icon"></i>' +
                    '<span class="er-date-lbl">Approved</span>' +
                    '<input type="date" id="er-app-from" class="er-date-inp" />' +
                    '<span class="er-date-sep">–</span>' +
                    '<input type="date" id="er-app-to"   class="er-date-inp" />' +
                '</div>' +
            '</div>' +

            /* Row 2 — currency + apply/reset + count + export */
            '<div class="er-filters-row2">' +
                /* View Currency */
                '<div class="er-ccy-group">' +
                    '<span class="er-ccy-label"><i class="fa-solid fa-coins"></i> View Currency</span>' +
                    '<div class="er-ccy-toggle" id="er-ccy-toggle">' +
                        '<button class="er-ccy-btn er-ccy-active" data-ccy="INR">₹ INR</button>' +
                        '<button class="er-ccy-btn" data-ccy="SAR">﷼ SAR</button>' +
                    '</div>' +
                '</div>' +
                /* Apply / Reset */
                '<button class="er-apply-btn" id="er-apply-btn">' +
                    '<i class="fa-solid fa-filter"></i> Apply Filters' +
                '</button>' +
                '<button class="er-reset-btn" id="er-reset-btn">' +
                    '<i class="fa-solid fa-rotate-left"></i> Reset' +
                '</button>' +
                /* Spacer */
                '<div style="flex:1"></div>' +
                /* Row count + export */
                '<span class="er-row-count" id="er-row-count">—</span>' +
                '<button class="er-export-btn" id="er-export-btn">' +
                    '<i class="fa-solid fa-file-excel"></i> Export' +
                '</button>' +
            '</div>' +

        '</div>' + /* .er-toolbar */

        /* ═══ CHARTS SECTION ════════════════════════════════════════ */
        '<div class="er-charts-section" id="er-charts-section">' +
            /* KPI — Total Spend */
            '<div class="er-chart-card er-kpi-card" id="er-chart-card-kpi">' +
                '<div class="er-chart-title"><i class="fa-solid fa-coins"></i> Total Spend</div>' +
                '<div class="er-kpi-body">' +
                    '<div class="er-kpi-amount" id="er-kpi-amount">—</div>' +
                    '<div class="er-kpi-label">Total Spend</div>' +
                '</div>' +
            '</div>' +
            '<div class="er-chart-card" id="er-chart-card-bar">' +
                '<div class="er-chart-title"><i class="fa-solid fa-chart-column"></i> Project-wise Spend</div>' +
                '<div class="er-chart-body"><canvas id="er-chart-bar"></canvas></div>' +
            '</div>' +
            '<div class="er-chart-card" id="er-chart-card-donut">' +
                '<div class="er-chart-title"><i class="fa-solid fa-circle-half-stroke"></i> Status Distribution</div>' +
                '<div class="er-chart-body"><canvas id="er-chart-donut"></canvas></div>' +
            '</div>' +
            '<div class="er-chart-card" id="er-chart-card-line">' +
                '<div class="er-chart-title"><i class="fa-solid fa-chart-line"></i> Monthly Trend</div>' +
                '<div class="er-chart-body"><canvas id="er-chart-line"></canvas></div>' +
            '</div>' +
        '</div>' +

        /* ═══ STICKY TABLE HEADER (outside scroll frame) ═══════════ */
        '<div class="er-thead-wrap" id="er-thead-wrap">' +
            '<table class="er-table">' +
                '<thead>' +
                    '<tr>' +
                        '<th class="er-th-num">#</th>' +
                        '<th class="er-th-emp">Employee</th>' +
                        '<th class="er-th-dept">Department</th>' +
                        '<th class="er-th-rpt">Report Name</th>' +
                        '<th class="er-th-date">Exp. Date</th>' +
                        '<th class="er-th-cat">Category</th>' +
                        '<th class="er-th-proj">Project</th>' +
                        '<th class="er-th-amt">Amount</th>' +
                        '<th class="er-th-ccy">Currency</th>' +
                        '<th class="er-th-amt er-th-conv" id="er-th-conv">Converted (INR)</th>' +
                        '<th class="er-th-status">Status</th>' +
                        '<th class="er-th-date">Submitted</th>' +
                        '<th class="er-th-date">Approved</th>' +
                    '</tr>' +
                '</thead>' +
            '</table>' +
        '</div>' +

        /* ═══ TABLE FRAME (body rows only) ══════════════════════════ */
        '<div class="er-table-frame" id="er-table-frame">' +
            '<table class="er-table" id="er-table">' +
                '<tbody id="er-tbody">' +
                    '<tr><td colspan="13" class="er-loading"><i class="fa-solid fa-spinner fa-spin"></i> Loading…</td></tr>' +
                '</tbody>' +
            '</table>' +
        '</div>' +

        /* ═══ FOOTER — pagination + totals ══════════════════════════ */
        '<div class="er-footer" id="er-footer">' +
            /* Pagination */
            '<div class="er-pagination" id="er-pagination">' +
                '<button class="er-pg-btn" id="er-pg-prev"><i class="fa-solid fa-chevron-left"></i></button>' +
                '<span class="er-pg-info" id="er-pg-info">—</span>' +
                '<button class="er-pg-btn" id="er-pg-next"><i class="fa-solid fa-chevron-right"></i></button>' +
                '<select class="er-pg-size" id="er-pg-size">' +
                    '<option value="20">20 / page</option>' +
                    '<option value="50">50 / page</option>' +
                    '<option value="100">100 / page</option>' +
                '</select>' +
            '</div>' +
            /* Totals */
            '<div class="er-footer-totals">' +
                '<span class="er-footer-count" id="er-footer-count">—</span>' +
                '<span class="er-footer-sep">·</span>' +
                '<span>Total: <strong id="er-total-orig">—</strong></span>' +
                '<span class="er-footer-sep">·</span>' +
                '<span id="er-conv-label">Converted (INR): <strong id="er-total-conv">—</strong></span>' +
            '</div>' +
        '</div>' +

        '</div>' /* .er-page */
    );
}

// ── Multi-select chip markup ───────────────────────────────────────
function _erMSChip(id, iconCls, label) {
    return (
        '<div class="er-chip er-chip-ms" id="er-ms-wrap-' + id + '">' +
            '<button class="er-ms-btn" data-msid="' + id + '">' +
                '<i class="fa-solid ' + iconCls + ' er-chip-icon"></i>' +
                '<span class="er-ms-lbl" id="er-ms-lbl-' + id + '">' + label + '</span>' +
                '<i class="fa-solid fa-chevron-down er-ms-caret"></i>' +
            '</button>' +
            '<div class="er-ms-panel" id="er-ms-panel-' + id + '" style="display:none">' +
                '<div class="er-ms-search">' +
                    '<input type="text" class="er-ms-search-inp" placeholder="Search…" />' +
                '</div>' +
                '<ul class="er-ms-list" id="er-ms-list-' + id + '"></ul>' +
            '</div>' +
        '</div>'
    );
}

// ── Populate multi-select option lists ────────────────────────────
function _erPopulateMS() {
    /* Build unique option sets from _erAllRows */
    var empMap  = {}, deptMap = {}, projMap = {};
    _erAllRows.forEach(function (r) {
        if (r.employeeId) empMap[r.employeeId]  = r.empName;
        if (r.deptId)     deptMap[r.deptId]     = r.deptName;
        if (r.projectId)  projMap[r.projectId]  = r.projectName;
    });

    _erFillList('emp',  Object.entries(empMap).map(function(e){return {v:e[0],l:e[1]};}));
    _erFillList('dept', Object.entries(deptMap).map(function(e){return {v:e[0],l:e[1]};}));
    _erFillList('proj', Object.entries(projMap).map(function(e){return {v:e[0],l:e[1]};}));
    _erFillList('status', [
        {v:'draft',l:'Draft'},{v:'submitted',l:'Submitted'},
        {v:'approved',l:'Approved'},{v:'rejected',l:'Rejected'}
    ]);
}

function _erFillList(id, items) {
    var ul = document.getElementById('er-ms-list-' + id);
    if (!ul) return;
    ul.innerHTML = '';
    items.sort(function(a,b){return String(a.l||'').localeCompare(String(b.l||''));});
    items.forEach(function (item) {
        var li = document.createElement('li');
        li.innerHTML = '<label class="er-ms-item">' +
            '<input type="checkbox" value="' + _erEsc(item.v) + '" />' +
            '<span>' + _erEsc(item.l) + '</span>' +
            '</label>';
        ul.appendChild(li);
    });
}

// ── Wire events ────────────────────────────────────────────────────
function _erWireEvents() {
    /* Search — fires on every keystroke (no apply needed for search alone) */
    var searchEl = document.getElementById('er-search');
    if (searchEl) searchEl.addEventListener('input', function() { _erPage = 1; _erApplyFilters(); });

    /* Multi-select toggle buttons */
    document.querySelectorAll('.er-ms-btn').forEach(function (btn) {
        btn.addEventListener('click', function (e) {
            e.stopPropagation();
            var id    = btn.getAttribute('data-msid');
            var panel = document.getElementById('er-ms-panel-' + id);
            var open  = panel.style.display !== 'none';
            _erCloseAllMS();
            if (!open) {
                panel.style.display = 'block';
                var si = panel.querySelector('.er-ms-search-inp');
                if (si) si.focus();
            }
        });
    });

    /* Multi-select panel — search filter and checkbox selection */
    ['emp','dept','proj','status'].forEach(function (id) {
        var panel = document.getElementById('er-ms-panel-' + id);
        if (!panel) return;

        var si = panel.querySelector('.er-ms-search-inp');
        if (si) {
            si.addEventListener('input', function () {
                var term = si.value.toLowerCase();
                panel.querySelectorAll('.er-ms-list li').forEach(function (li) {
                    li.style.display = li.textContent.toLowerCase().includes(term) ? '' : 'none';
                });
            });
            si.addEventListener('click', function(e){ e.stopPropagation(); });
        }

        var list = document.getElementById('er-ms-list-' + id);
        if (list) {
            list.addEventListener('change', function () {
                var checked = Array.from(list.querySelectorAll('input:checked')).map(function(cb){return cb.value;});
                if (id === 'emp')    _erFilters.employees   = checked;
                if (id === 'dept')   _erFilters.departments = checked;
                if (id === 'proj')   _erFilters.projects    = checked;
                if (id === 'status') _erFilters.statuses    = checked;
                _erUpdateMSLabel(id, checked);
                // Don't auto-apply — user presses Apply button
            });
        }
    });

    /* Apply Filters button */
    var applyBtn = document.getElementById('er-apply-btn');
    if (applyBtn) applyBtn.addEventListener('click', function() { _erPage = 1; _erApplyFilters(); });

    /* Reset Filters button */
    var resetBtn = document.getElementById('er-reset-btn');
    if (resetBtn) resetBtn.addEventListener('click', _erResetFilters);

    /* Currency toggle — immediate re-render on change */
    var ccyToggle = document.getElementById('er-ccy-toggle');
    if (ccyToggle) {
        ccyToggle.addEventListener('click', function (e) {
            var btn = e.target.closest('.er-ccy-btn');
            if (!btn) return;
            ccyToggle.querySelectorAll('.er-ccy-btn').forEach(function(b){b.classList.remove('er-ccy-active');});
            btn.classList.add('er-ccy-active');
            _erViewCurrency = btn.getAttribute('data-ccy');
            _erUpdateCurrencyLabels();
            _erRenderTable();
            _erRenderCharts();
            _erUpdateKPI();
        });
    }

    /* Export */
    var exportBtn = document.getElementById('er-export-btn');
    if (exportBtn) exportBtn.addEventListener('click', _erExport);

    /* Pagination */
    var pgPrev = document.getElementById('er-pg-prev');
    var pgNext = document.getElementById('er-pg-next');
    var pgSize = document.getElementById('er-pg-size');
    if (pgPrev) pgPrev.addEventListener('click', function() {
        if (_erPage > 1) { _erPage--; _erRenderTable(); }
    });
    if (pgNext) pgNext.addEventListener('click', function() {
        var totalPages = Math.max(1, Math.ceil(_erFiltered.length / _erPageSize));
        if (_erPage < totalPages) { _erPage++; _erRenderTable(); }
    });
    if (pgSize) pgSize.addEventListener('change', function() {
        _erPageSize = parseInt(pgSize.value, 10) || 20;
        _erPage = 1;
        _erRenderTable();
    });

    /* Close multi-select panels on outside click */
    function outsideHandler(e) {
        if (!document.getElementById('er-toolbar')) {
            document.removeEventListener('click', outsideHandler);
            return;
        }
        if (!e.target.closest('.er-chip-ms')) _erCloseAllMS();
    }
    document.addEventListener('click', outsideHandler);

    /* Resize → re-size table frame + re-sync sticky header top */
    function resizeHandler() {
        clearTimeout(_erResizeTimer);
        _erResizeTimer = setTimeout(function() {
            _erSizeTable();
            _erUpdateStickyTop();
            _erSyncColWidths();
        }, 120);
    }
    window.addEventListener('resize', resizeHandler);

    /* Horizontal scroll sync: frame → sticky header (transform-based, no overflow trick) */
    var theadWrap  = document.getElementById('er-thead-wrap');
    var tableFrame = document.getElementById('er-table-frame');
    if (tableFrame && theadWrap) {
        var headTable = theadWrap.querySelector('.er-table');
        tableFrame.addEventListener('scroll', function() {
            if (headTable) {
                headTable.style.transform = 'translateX(-' + tableFrame.scrollLeft + 'px)';
            }
        });
    }
}

function _erCloseAllMS() {
    document.querySelectorAll('.er-ms-panel').forEach(function(p){ p.style.display = 'none'; });
}

function _erUpdateMSLabel(id, checked) {
    var lbl  = document.getElementById('er-ms-lbl-' + id);
    var btn  = document.querySelector('.er-ms-btn[data-msid="' + id + '"]');
    var base = {emp:'Employee',dept:'Department',proj:'Project',status:'Status'}[id] || id;
    if (lbl) lbl.textContent = checked.length ? base + ' (' + checked.length + ')' : base;
    if (btn) btn.classList.toggle('er-ms-btn-active', checked.length > 0);
}

function _erUpdateCurrencyLabels() {
    var ccy = _erViewCurrency;
    var hdr = document.getElementById('er-th-conv');
    if (hdr) hdr.textContent = 'Converted (' + ccy + ')';
    var lbl = document.getElementById('er-conv-label');
    if (lbl) lbl.innerHTML = 'Converted (' + ccy + '): <strong id="er-total-conv">—</strong>';
}

// ── Apply filters → re-render table + charts ───────────────────────
function _erApplyFilters() {
    var search  = (document.getElementById('er-search')   || {}).value || '';
    var expFrom = (document.getElementById('er-exp-from') || {}).value || '';
    var expTo   = (document.getElementById('er-exp-to')   || {}).value || '';
    var appFrom = (document.getElementById('er-app-from') || {}).value || '';
    var appTo   = (document.getElementById('er-app-to')   || {}).value || '';
    var term    = search.toLowerCase();

    _erFiltered = _erAllRows.filter(function (r) {
        // Text search
        if (term && ![r.empName,r.reportName,r.category,r.projectName,r.note,r.deptName]
                .some(function(v){ return (v||'').toLowerCase().includes(term); })) return false;
        // Multi-selects
        if (_erFilters.employees.length   && !_erFilters.employees.includes(r.employeeId))  return false;
        if (_erFilters.departments.length && !_erFilters.departments.includes(r.deptId))    return false;
        if (_erFilters.projects.length    && !_erFilters.projects.includes(r.projectId))    return false;
        if (_erFilters.statuses.length    && !_erFilters.statuses.includes(r.status))       return false;
        // Expense date range
        if (expFrom && r.date && r.date < expFrom) return false;
        if (expTo   && r.date && r.date > expTo)   return false;
        // Approved date range
        var appDate = (r.approvedAt || '').substring(0, 10);
        if (appFrom && appDate && appDate < appFrom) return false;
        if (appTo   && appDate && appDate > appTo)   return false;

        return true;
    });

    _erPage = 1;
    _erRenderTable();
    _erRenderCharts();
    _erUpdateKPI();
}

// ── Render table rows with pagination + currency conversion ─────────
function _erRenderTable() {
    var tbody  = document.getElementById('er-tbody');
    var count  = document.getElementById('er-row-count');
    var fcount = document.getElementById('er-footer-count');
    var torig  = document.getElementById('er-total-orig');
    var tconv  = document.getElementById('er-total-conv');
    if (!tbody) return;

    var n = _erFiltered.length;

    if (!n) {
        tbody.innerHTML = '<tr><td colspan="13" class="er-empty">' +
            '<i class="fa-solid fa-inbox"></i><span>No records match the current filters.</span></td></tr>';
        if (count)  count.textContent  = '0 rows';
        if (fcount) fcount.textContent = 'No records';
        if (torig)  torig.textContent  = '—';
        if (tconv)  tconv.textContent  = '—';
        _erRenderPagination(0, 1);
        return;
    }

    /* Pagination */
    var totalPages = Math.max(1, Math.ceil(n / _erPageSize));
    _erPage = Math.min(_erPage, totalPages);
    var start = (_erPage - 1) * _erPageSize;
    var end   = Math.min(start + _erPageSize, n);
    var pageRows = _erFiltered.slice(start, end);

    /* Build rows */
    var html = '';
    pageRows.forEach(function (r, i) {
        var globalIdx = start + i + 1;
        var isFx      = r.currencyCode && r.currencyCode !== 'INR';
        var viewAmt   = _erConvertToView(r);
        var ccy       = _erViewCurrency;

        html += '<tr class="er-row' + (isFx ? ' er-row-fx' : '') + '">' +
            '<td class="er-td-num">' + globalIdx + '</td>' +

            /* Employee — tooltip shows full name + ID on hover */
            '<td class="er-td-emp" title="' + _erEsc(r.empName) + ' (' + _erEsc(r.employeeId) + ')">' +
                '<span class="er-emp-avatar">' + _erInitial(r.empName) + '</span>' +
                '<div class="er-emp-info">' +
                    '<span class="er-emp-name">' + _erEsc(r.empName) + '</span>' +
                    '<span class="er-emp-id">'   + _erEsc(r.employeeId) + '</span>' +
                '</div>' +
            '</td>' +

            '<td title="' + _erEsc(r.deptName) + '">' + _erEsc(r.deptName) + '</td>' +

            '<td class="er-td-report" title="' + _erEsc(r.reportName) + '">' +
                '<span class="er-report-name">' + _erEsc(r.reportName) + '</span>' +
            '</td>' +

            '<td class="er-td-date">' + _erFmtDate(r.date) + '</td>' +
            '<td title="' + _erEsc(r.category) + '">'    + _erEsc(r.category)    + '</td>' +
            '<td title="' + _erEsc(r.projectName) + '">' + _erEsc(r.projectName) + '</td>' +

            '<td class="er-td-amt">' + _erFmt(r.amount) + '</td>' +
            '<td><span class="er-ccy-pill">' + _erEsc(r.currencyCode || '—') + '</span></td>' +

            /* Converted amount in selected view currency */
            '<td class="er-td-amt er-td-conv" title="' +
                (r.currencyCode === ccy && r.exchangeRate
                    ? 'Stored rate used'
                    : 'Rate: 1 ' + _erEsc(ccy) + ' = ' + _erGetFxRate(ccy, r.date).toFixed(4) + ' INR') +
            '">' +
                _erCcySym(ccy) + ' ' + _erFmt(viewAmt) +
                (r.currencyCode !== 'INR' && r.currencyCode !== ccy
                    ? ' <span class="er-fx-note" title="Cross-converted via INR">~</span>' : '') +
            '</td>' +

            '<td>' + _erStatusBadge(r.status) + '</td>' +

            '<td class="er-td-date">' + _erFmtDate(r.submittedAt) + '</td>' +
            '<td class="er-td-date">' +
                (r.status === 'approved' ? _erFmtDate(r.approvedAt) : '<span class="er-dash">—</span>') +
            '</td>' +
        '</tr>';
    });
    tbody.innerHTML = html;

    /* Row count */
    if (count)  count.textContent = n + ' row' + (n !== 1 ? 's' : '');

    /* Footer totals — computed over ALL filtered rows, not just current page */
    var sumOrig = _erFiltered.reduce(function(s,r){ return s + (r.amount || 0); }, 0);
    var sumConv = _erFiltered.reduce(function(s,r){ return s + _erConvertToView(r); }, 0);
    if (fcount) fcount.textContent = n + ' record' + (n !== 1 ? 's' : '');
    if (torig)  torig.textContent  = _erFmt(sumOrig);
    if (tconv)  tconv.textContent  = _erFmt(sumConv);

    /* Pagination controls */
    _erRenderPagination(n, totalPages);

    /* Sync sticky header column widths to match rendered body */
    _erSyncColWidths();
}

function _erRenderPagination(total, totalPages) {
    var info    = document.getElementById('er-pg-info');
    var pgPrev  = document.getElementById('er-pg-prev');
    var pgNext  = document.getElementById('er-pg-next');
    if (!info) return;

    if (total === 0) {
        info.textContent = 'No data';
        if (pgPrev) pgPrev.disabled = true;
        if (pgNext) pgNext.disabled = true;
        return;
    }
    info.textContent = 'Page ' + _erPage + ' of ' + totalPages;
    if (pgPrev) pgPrev.disabled = _erPage <= 1;
    if (pgNext) pgNext.disabled = _erPage >= totalPages;
}

// ── Chart rendering ────────────────────────────────────────────────
function _erRenderCharts() {
    if (typeof Chart === 'undefined') return; // Chart.js not yet loaded

    var ccy = _erViewCurrency;
    var rows = _erFiltered;

    /* ── Enterprise colour palettes ── */
    // Project-wise: categorical, no red/green (reserved for status)
    var _erBarPalette = ['#1976D2','#00897B','#3949AB','#8E24AA','#FB8C00','#90A4AE',
                         '#0288D1','#00ACC1','#5E35B1','#D81B60','#F4511E','#6D8399'];
    // Status: accessible, semantic
    var _erStatusPalette = {
        Approved:  '#2E7D32',
        Submitted: '#1976D2',
        Draft:     '#757575',
        Rejected:  '#D32F2F'
    };
    var _erGridColor  = '#E0E0E0';
    var _erChartBg    = '#FAFAFA';
    var _erTrendColor = '#1976D2';

    /* ── 1. Bar chart — Project-wise Spend ── */
    var projTotals = {};
    rows.forEach(function(r) {
        var k = r.projectName || 'Unknown';
        projTotals[k] = (projTotals[k] || 0) + _erConvertToView(r);
    });
    var projEntries = Object.entries(projTotals).sort(function(a,b){ return b[1]-a[1]; }).slice(0, 12);
    var barLabels = projEntries.map(function(e){ return e[0]; });
    var barData   = projEntries.map(function(e){ return Math.round(e[1] * 100) / 100; });
    var barColors = barLabels.map(function(_,i){ return _erBarPalette[i % _erBarPalette.length]; });

    var barCanvas = document.getElementById('er-chart-bar');
    if (barCanvas) {
        if (_erCharts.bar) _erCharts.bar.destroy();
        _erCharts.bar = new Chart(barCanvas, {
            type: 'bar',
            data: {
                labels: barLabels,
                datasets: [{
                    label: 'Spend (' + ccy + ')',
                    data: barData,
                    backgroundColor: barColors,
                    borderRadius: 5,
                    borderSkipped: false
                }]
            },
            options: {
                responsive: true, maintainAspectRatio: false,
                backgroundColor: _erChartBg,
                layout: { padding: { top: 12, right: 4, bottom: 0, left: 4 } },
                plugins: {
                    legend: { display: false },
                    tooltip: { callbacks: { label: function(ctx){ return ' ' + ccy + ' ' + _erFmt(ctx.raw); } } }
                },
                scales: {
                    x: { ticks: { font: { size: 11 }, maxRotation: 40 }, grid: { display: false } },
                    y: { ticks: { font: { size: 11 }, callback: function(v){ return _erFmt(v); } }, grid: { color: _erGridColor } }
                }
            }
        });
    }

    /* ── 2. Donut chart — Status Distribution ── */
    var statusCounts = { 'Approved': 0, 'Submitted': 0, 'Draft': 0, 'Rejected': 0 };
    // Count distinct reports per status
    var seenReports = {};
    rows.forEach(function(r) {
        if (!seenReports[r.reportId]) {
            seenReports[r.reportId] = true;
            var s = r.status || 'draft';
            var key = s.charAt(0).toUpperCase() + s.slice(1);
            if (statusCounts.hasOwnProperty(key)) statusCounts[key]++;
            else statusCounts['Draft']++;
        }
    });
    var donutLabels = Object.keys(statusCounts).filter(function(k){ return statusCounts[k] > 0; });
    var donutData   = donutLabels.map(function(k){ return statusCounts[k]; });
    var donutBg     = donutLabels.map(function(k){ return _erStatusPalette[k] || '#90A4AE'; });

    var donutCanvas = document.getElementById('er-chart-donut');
    if (donutCanvas) {
        if (_erCharts.donut) _erCharts.donut.destroy();
        _erCharts.donut = new Chart(donutCanvas, {
            type: 'doughnut',
            data: { labels: donutLabels, datasets: [{ data: donutData, backgroundColor: donutBg, borderWidth: 2, borderColor: '#fff' }] },
            options: {
                responsive: true, maintainAspectRatio: false,
                cutout: '68%',
                layout: { padding: { top: 6, right: 6, bottom: 6, left: 6 } },
                plugins: {
                    legend: {
                        position: 'right',
                        labels: { font: { size: 11 }, boxWidth: 12, padding: 12,
                            generateLabels: function(chart) {
                                return chart.data.labels.map(function(label, i) {
                                    return {
                                        text: label,
                                        fillStyle: chart.data.datasets[0].backgroundColor[i],
                                        strokeStyle: '#fff',
                                        lineWidth: 2,
                                        index: i
                                    };
                                });
                            }
                        }
                    },
                    tooltip: { callbacks: { label: function(ctx){ return ' ' + ctx.label + ': ' + ctx.raw + ' reports'; } } }
                }
            }
        });
    }

    /* ── 3. Line chart — Monthly Trend ── */
    var monthTotals = {};
    rows.forEach(function(r) {
        if (!r.date) return;
        var ym = r.date.substring(0, 7); // YYYY-MM
        monthTotals[ym] = (monthTotals[ym] || 0) + _erConvertToView(r);
    });
    var months = Object.keys(monthTotals).sort();
    var lineLabels = months.map(function(ym) {
        var parts = ym.split('-');
        var mo = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
        return mo[parseInt(parts[1], 10) - 1] + ' ' + parts[0].substring(2);
    });
    var lineData = months.map(function(ym){ return Math.round(monthTotals[ym] * 100) / 100; });

    var lineCanvas = document.getElementById('er-chart-line');
    if (lineCanvas) {
        if (_erCharts.line) _erCharts.line.destroy();
        _erCharts.line = new Chart(lineCanvas, {
            type: 'line',
            data: {
                labels: lineLabels,
                datasets: [{
                    label: 'Spend (' + ccy + ')',
                    data: lineData,
                    borderColor: _erTrendColor,
                    backgroundColor: 'rgba(25,118,210,0.08)',
                    borderWidth: 2.5,
                    pointRadius: 4,
                    pointBackgroundColor: _erTrendColor,
                    pointHoverBackgroundColor: '#1565C0',
                    pointHoverRadius: 6,
                    fill: true,
                    tension: 0.35
                }]
            },
            options: {
                responsive: true, maintainAspectRatio: false,
                backgroundColor: _erChartBg,
                layout: { padding: { top: 12, right: 8, bottom: 0, left: 4 } },
                plugins: {
                    legend: { display: false },
                    tooltip: { callbacks: { label: function(ctx){ return ' ' + ccy + ' ' + _erFmt(ctx.raw); } } }
                },
                scales: {
                    x: { ticks: { font: { size: 11 } }, grid: { display: false } },
                    y: { ticks: { font: { size: 11 }, callback: function(v){ return _erFmt(v); } }, grid: { color: _erGridColor } }
                }
            }
        });
    }
}

// ── Reset all filters ──────────────────────────────────────────────
function _erResetFilters() {
    var s = document.getElementById('er-search');
    if (s) s.value = '';
    ['er-exp-from','er-exp-to','er-app-from','er-app-to'].forEach(function (id) {
        var el = document.getElementById(id);
        if (el) el.value = '';
    });
    _erFilters.employees = []; _erFilters.departments = [];
    _erFilters.projects  = []; _erFilters.statuses    = [];
    document.querySelectorAll('.er-ms-list input[type=checkbox]').forEach(function(cb){ cb.checked = false; });
    ['emp','dept','proj','status'].forEach(function(id){ _erUpdateMSLabel(id, []); });
    _erPage = 1;
    _erApplyFilters();
}

// ── KPI tile update ────────────────────────────────────────────────
function _erUpdateKPI() {
    var el = document.getElementById('er-kpi-amount');
    if (!el) return;
    var total = _erFiltered.reduce(function(s, r) { return s + _erConvertToView(r); }, 0);
    el.textContent = _erCcySym(_erViewCurrency) + ' ' + _erFmt(total);
}

// ── Utilities ──────────────────────────────────────────────────────
function _erStatusBadge(status) {
    var map = {
        draft:     ['er-badge-draft',     'Draft'],
        submitted: ['er-badge-submitted', 'Submitted'],
        approved:  ['er-badge-approved',  'Approved'],
        rejected:  ['er-badge-rejected',  'Rejected']
    };
    var x = map[status] || ['er-badge-draft', status || 'Draft'];
    return '<span class="er-status-badge ' + x[0] + '">' + x[1] + '</span>';
}

function _erInitial(name) { return ((name || '?').charAt(0)).toUpperCase(); }

function _erFmt(n) {
    if (n == null || n === '' || isNaN(n)) return '—';
    return Number(n).toLocaleString('en-IN', {minimumFractionDigits:2, maximumFractionDigits:2});
}

function _erEsc(s) {
    return String(s || '').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
}

/* _erUpdateClearBtn and _erClearFilters replaced by _erResetFilters above */

// ── Sync sticky header column widths with rendered body columns ─────
// Uses Math.max(body cell width, header natural text width) so long
// labels (e.g. "CONVERTED (INR)") never overflow into the next column.
// Body columns are also updated via <colgroup> to stay in lock-step.
function _erSyncColWidths() {
    var bodyTable = document.getElementById('er-table');
    var headWrap  = document.getElementById('er-thead-wrap');
    if (!bodyTable || !headWrap) return;

    var firstRow = bodyTable.querySelector('tbody tr:first-child');
    if (!firstRow) return;
    var cells = firstRow.querySelectorAll('td');
    if (cells.length < 13) return; // loading/empty colspan row — skip

    var headCols  = headWrap.querySelectorAll('thead th');
    var headTable = headWrap.querySelector('.er-table');

    // Step 1 — reset header widths so scrollWidth reflects natural text size
    headCols.forEach(function(th) { th.style.width = ''; th.style.minWidth = ''; });

    // Step 2 — for each column take max(body rendered px, header text px + padding)
    var widths = [];
    cells.forEach(function(td, i) {
        var bodyW = td.offsetWidth;
        var headW = headCols[i] ? (headCols[i].scrollWidth + 8) : 0; // +8 safety buffer
        widths.push(Math.max(bodyW, headW));
    });

    // Step 3 — apply to header cells
    headCols.forEach(function(th, i) {
        th.style.width    = widths[i] + 'px';
        th.style.minWidth = widths[i] + 'px';
    });

    // Step 4 — keep body columns in sync via <colgroup> so table widths match
    var cg = bodyTable.querySelector('colgroup');
    if (!cg) {
        cg = document.createElement('colgroup');
        widths.forEach(function() { cg.appendChild(document.createElement('col')); });
        bodyTable.insertBefore(cg, bodyTable.firstChild);
    }
    var cols = cg.querySelectorAll('col');
    widths.forEach(function(w, i) { if (cols[i]) cols[i].style.width = w + 'px'; });

    // Step 5 — force both tables to the same total width
    var totalW = widths.reduce(function(s, w) { return s + w; }, 0);
    if (headTable)   headTable.style.width   = totalW + 'px';
    bodyTable.style.width = totalW + 'px';
}

// ── Pin sticky header just below the sticky toolbar ────────────────
function _erUpdateStickyTop() {
    var toolbar   = document.getElementById('er-toolbar');
    var theadWrap = document.getElementById('er-thead-wrap');
    if (!toolbar || !theadWrap) return;
    theadWrap.style.top = (toolbar.offsetHeight || 0) + 'px';
}

// ── Dynamic table frame height ─────────────────────────────────────
function _erSizeTable() {
    var frame     = document.getElementById('er-table-frame');
    var toolbar   = document.getElementById('er-toolbar');
    var footer    = document.getElementById('er-footer');
    var charts    = document.getElementById('er-charts-section');
    var detHdr    = document.querySelector('.rpt-detail-header');
    var theadWrap = document.getElementById('er-thead-wrap');
    if (!frame || !toolbar) return;

    var tbH  = toolbar.offsetHeight   || 80;
    var ftH  = footer     ? (footer.offsetHeight     || 46)  : 46;
    var chH  = charts     ? (charts.offsetHeight     || 220) : 220;
    var dhH  = detHdr     ? (detHdr.offsetHeight     || 56)  : 56;
    var thH  = theadWrap  ? (theadWrap.offsetHeight  || 44)  : 44;
    // 60 = admin header, 32 = .content padding-top
    var avail = window.innerHeight - 60 - 32 - dhH - tbH - chH - thH - ftH - 16;
    frame.style.height = Math.max(avail, 200) + 'px';
}

// ── Export to Excel ───────────────────────────────────────────────
function _erExport() {
    if (!window.XLSX) { alert('XLSX library not available.'); return; }
    if (!_erFiltered.length) { alert('No data to export.'); return; }

    var ccy  = _erViewCurrency;
    var rows = _erFiltered.map(function (r, i) {
        var obj = {};
        obj['#']                         = i + 1;
        obj['Employee']                  = r.empName;
        obj['Employee ID']               = r.employeeId;
        obj['Department']                = r.deptName;
        obj['Report Name']               = r.reportName;
        obj['Status']                    = r.status;
        obj['Category']                  = r.category;
        obj['Project']                   = r.projectName;
        obj['Expense Date']              = _erFmtDate(r.date);
        obj['Amount']                    = r.amount;
        obj['Currency']                  = r.currencyCode;
        obj['Exchange Rate']             = r.exchangeRate || '';
        obj['Converted (' + ccy + ')']   = Math.round(_erConvertToView(r) * 100) / 100;
        obj['Submitted Date']            = _erFmtDate(r.submittedAt);
        obj['Approved Date']             = r.status === 'approved' ? _erFmtDate(r.approvedAt) : '—';
        obj['Note']                      = r.note;
        return obj;
    });

    var ws = XLSX.utils.json_to_sheet(rows);
    var cols = Object.keys(rows[0]).map(function(k){ return { wch: Math.max(k.length + 2, 14) }; });
    ws['!cols'] = cols;

    var wb = XLSX.utils.book_new();
    XLSX.utils.book_append_sheet(wb, ws, 'Expense Report');
    XLSX.writeFile(wb, 'Expense_Report_' + ccy + '_' + new Date().toISOString().substring(0, 10) + '.xlsx');
}

// ── Event wiring ─────────────────────────────────────────────────

/* Table click delegation — handles view + description edit actions */
document.getElementById('rpt-list-table-frame').addEventListener('click', function (e) {
    var el = e.target.closest('[data-action]');
    if (!el) return;
    var action   = el.getAttribute('data-action');
    var reportId = el.getAttribute('data-report-id');
    if      (action === 'view')         { loadAdminReport(reportId); }
    else if (action === 'edit-desc')    { rptStartEditDesc(reportId); }
    else if (action === 'save-desc')    { rptSaveDescEdit(reportId); }
    else if (action === 'cancel-desc')  { rptCancelEditDesc(reportId); }
});

/* Live search */
document.getElementById('rpt-list-search').addEventListener('input', renderAdminReports);

document.getElementById('rpt-back-btn').addEventListener('click', showRptList);

// ═══════════════════════════════════════════════
// ── COUNTRIES LIST (ISO 3166-1, with emoji flags)
// ═══════════════════════════════════════════════

const COUNTRIES = [
    {code:'AF',flag:'🇦🇫',name:'Afghanistan'},{code:'AL',flag:'🇦🇱',name:'Albania'},
    {code:'DZ',flag:'🇩🇿',name:'Algeria'},{code:'AD',flag:'🇦🇩',name:'Andorra'},
    {code:'AO',flag:'🇦🇴',name:'Angola'},{code:'AG',flag:'🇦🇬',name:'Antigua and Barbuda'},
    {code:'AR',flag:'🇦🇷',name:'Argentina'},{code:'AM',flag:'🇦🇲',name:'Armenia'},
    {code:'AU',flag:'🇦🇺',name:'Australia'},{code:'AT',flag:'🇦🇹',name:'Austria'},
    {code:'AZ',flag:'🇦🇿',name:'Azerbaijan'},{code:'BS',flag:'🇧🇸',name:'Bahamas'},
    {code:'BH',flag:'🇧🇭',name:'Bahrain'},{code:'BD',flag:'🇧🇩',name:'Bangladesh'},
    {code:'BB',flag:'🇧🇧',name:'Barbados'},{code:'BY',flag:'🇧🇾',name:'Belarus'},
    {code:'BE',flag:'🇧🇪',name:'Belgium'},{code:'BZ',flag:'🇧🇿',name:'Belize'},
    {code:'BJ',flag:'🇧🇯',name:'Benin'},{code:'BT',flag:'🇧🇹',name:'Bhutan'},
    {code:'BO',flag:'🇧🇴',name:'Bolivia'},{code:'BA',flag:'🇧🇦',name:'Bosnia and Herzegovina'},
    {code:'BW',flag:'🇧🇼',name:'Botswana'},{code:'BR',flag:'🇧🇷',name:'Brazil'},
    {code:'BN',flag:'🇧🇳',name:'Brunei'},{code:'BG',flag:'🇧🇬',name:'Bulgaria'},
    {code:'BF',flag:'🇧🇫',name:'Burkina Faso'},{code:'BI',flag:'🇧🇮',name:'Burundi'},
    {code:'CV',flag:'🇨🇻',name:'Cabo Verde'},{code:'KH',flag:'🇰🇭',name:'Cambodia'},
    {code:'CM',flag:'🇨🇲',name:'Cameroon'},{code:'CA',flag:'🇨🇦',name:'Canada'},
    {code:'CF',flag:'🇨🇫',name:'Central African Republic'},{code:'TD',flag:'🇹🇩',name:'Chad'},
    {code:'CL',flag:'🇨🇱',name:'Chile'},{code:'CN',flag:'🇨🇳',name:'China'},
    {code:'CO',flag:'🇨🇴',name:'Colombia'},{code:'KM',flag:'🇰🇲',name:'Comoros'},
    {code:'CG',flag:'🇨🇬',name:'Congo'},{code:'CD',flag:'🇨🇩',name:'Congo (DRC)'},
    {code:'CR',flag:'🇨🇷',name:'Costa Rica'},{code:'CI',flag:'🇨🇮',name:"Côte d'Ivoire"},
    {code:'HR',flag:'🇭🇷',name:'Croatia'},{code:'CU',flag:'🇨🇺',name:'Cuba'},
    {code:'CY',flag:'🇨🇾',name:'Cyprus'},{code:'CZ',flag:'🇨🇿',name:'Czech Republic'},
    {code:'DK',flag:'🇩🇰',name:'Denmark'},{code:'DJ',flag:'🇩🇯',name:'Djibouti'},
    {code:'DM',flag:'🇩🇲',name:'Dominica'},{code:'DO',flag:'🇩🇴',name:'Dominican Republic'},
    {code:'EC',flag:'🇪🇨',name:'Ecuador'},{code:'EG',flag:'🇪🇬',name:'Egypt'},
    {code:'SV',flag:'🇸🇻',name:'El Salvador'},{code:'GQ',flag:'🇬🇶',name:'Equatorial Guinea'},
    {code:'ER',flag:'🇪🇷',name:'Eritrea'},{code:'EE',flag:'🇪🇪',name:'Estonia'},
    {code:'SZ',flag:'🇸🇿',name:'Eswatini'},{code:'ET',flag:'🇪🇹',name:'Ethiopia'},
    {code:'FJ',flag:'🇫🇯',name:'Fiji'},{code:'FI',flag:'🇫🇮',name:'Finland'},
    {code:'FR',flag:'🇫🇷',name:'France'},{code:'GA',flag:'🇬🇦',name:'Gabon'},
    {code:'GM',flag:'🇬🇲',name:'Gambia'},{code:'GE',flag:'🇬🇪',name:'Georgia'},
    {code:'DE',flag:'🇩🇪',name:'Germany'},{code:'GH',flag:'🇬🇭',name:'Ghana'},
    {code:'GR',flag:'🇬🇷',name:'Greece'},{code:'GD',flag:'🇬🇩',name:'Grenada'},
    {code:'GT',flag:'🇬🇹',name:'Guatemala'},{code:'GN',flag:'🇬🇳',name:'Guinea'},
    {code:'GW',flag:'🇬🇼',name:'Guinea-Bissau'},{code:'GY',flag:'🇬🇾',name:'Guyana'},
    {code:'HT',flag:'🇭🇹',name:'Haiti'},{code:'HN',flag:'🇭🇳',name:'Honduras'},
    {code:'HU',flag:'🇭🇺',name:'Hungary'},{code:'IS',flag:'🇮🇸',name:'Iceland'},
    {code:'IN',flag:'🇮🇳',name:'India'},{code:'ID',flag:'🇮🇩',name:'Indonesia'},
    {code:'IR',flag:'🇮🇷',name:'Iran'},{code:'IQ',flag:'🇮🇶',name:'Iraq'},
    {code:'IE',flag:'🇮🇪',name:'Ireland'},{code:'IL',flag:'🇮🇱',name:'Israel'},
    {code:'IT',flag:'🇮🇹',name:'Italy'},{code:'JM',flag:'🇯🇲',name:'Jamaica'},
    {code:'JP',flag:'🇯🇵',name:'Japan'},{code:'JO',flag:'🇯🇴',name:'Jordan'},
    {code:'KZ',flag:'🇰🇿',name:'Kazakhstan'},{code:'KE',flag:'🇰🇪',name:'Kenya'},
    {code:'KI',flag:'🇰🇮',name:'Kiribati'},{code:'KP',flag:'🇰🇵',name:'Korea (North)'},
    {code:'KR',flag:'🇰🇷',name:'Korea (South)'},{code:'XK',flag:'🇽🇰',name:'Kosovo'},
    {code:'KW',flag:'🇰🇼',name:'Kuwait'},{code:'KG',flag:'🇰🇬',name:'Kyrgyzstan'},
    {code:'LA',flag:'🇱🇦',name:'Laos'},{code:'LV',flag:'🇱🇻',name:'Latvia'},
    {code:'LB',flag:'🇱🇧',name:'Lebanon'},{code:'LS',flag:'🇱🇸',name:'Lesotho'},
    {code:'LR',flag:'🇱🇷',name:'Liberia'},{code:'LY',flag:'🇱🇾',name:'Libya'},
    {code:'LI',flag:'🇱🇮',name:'Liechtenstein'},{code:'LT',flag:'🇱🇹',name:'Lithuania'},
    {code:'LU',flag:'🇱🇺',name:'Luxembourg'},{code:'MG',flag:'🇲🇬',name:'Madagascar'},
    {code:'MW',flag:'🇲🇼',name:'Malawi'},{code:'MY',flag:'🇲🇾',name:'Malaysia'},
    {code:'MV',flag:'🇲🇻',name:'Maldives'},{code:'ML',flag:'🇲🇱',name:'Mali'},
    {code:'MT',flag:'🇲🇹',name:'Malta'},{code:'MH',flag:'🇲🇭',name:'Marshall Islands'},
    {code:'MR',flag:'🇲🇷',name:'Mauritania'},{code:'MU',flag:'🇲🇺',name:'Mauritius'},
    {code:'MX',flag:'🇲🇽',name:'Mexico'},{code:'FM',flag:'🇫🇲',name:'Micronesia'},
    {code:'MD',flag:'🇲🇩',name:'Moldova'},{code:'MC',flag:'🇲🇨',name:'Monaco'},
    {code:'MN',flag:'🇲🇳',name:'Mongolia'},{code:'ME',flag:'🇲🇪',name:'Montenegro'},
    {code:'MA',flag:'🇲🇦',name:'Morocco'},{code:'MZ',flag:'🇲🇿',name:'Mozambique'},
    {code:'MM',flag:'🇲🇲',name:'Myanmar'},{code:'NA',flag:'🇳🇦',name:'Namibia'},
    {code:'NR',flag:'🇳🇷',name:'Nauru'},{code:'NP',flag:'🇳🇵',name:'Nepal'},
    {code:'NL',flag:'🇳🇱',name:'Netherlands'},{code:'NZ',flag:'🇳🇿',name:'New Zealand'},
    {code:'NI',flag:'🇳🇮',name:'Nicaragua'},{code:'NE',flag:'🇳🇪',name:'Niger'},
    {code:'NG',flag:'🇳🇬',name:'Nigeria'},{code:'MK',flag:'🇲🇰',name:'North Macedonia'},
    {code:'NO',flag:'🇳🇴',name:'Norway'},{code:'OM',flag:'🇴🇲',name:'Oman'},
    {code:'PK',flag:'🇵🇰',name:'Pakistan'},{code:'PW',flag:'🇵🇼',name:'Palau'},
    {code:'PA',flag:'🇵🇦',name:'Panama'},{code:'PG',flag:'🇵🇬',name:'Papua New Guinea'},
    {code:'PY',flag:'🇵🇾',name:'Paraguay'},{code:'PE',flag:'🇵🇪',name:'Peru'},
    {code:'PH',flag:'🇵🇭',name:'Philippines'},{code:'PL',flag:'🇵🇱',name:'Poland'},
    {code:'PT',flag:'🇵🇹',name:'Portugal'},{code:'QA',flag:'🇶🇦',name:'Qatar'},
    {code:'RO',flag:'🇷🇴',name:'Romania'},{code:'RU',flag:'🇷🇺',name:'Russia'},
    {code:'RW',flag:'🇷🇼',name:'Rwanda'},{code:'KN',flag:'🇰🇳',name:'Saint Kitts and Nevis'},
    {code:'LC',flag:'🇱🇨',name:'Saint Lucia'},{code:'VC',flag:'🇻🇨',name:'Saint Vincent and the Grenadines'},
    {code:'WS',flag:'🇼🇸',name:'Samoa'},{code:'SM',flag:'🇸🇲',name:'San Marino'},
    {code:'ST',flag:'🇸🇹',name:'São Tomé and Príncipe'},{code:'SA',flag:'🇸🇦',name:'Saudi Arabia'},
    {code:'SN',flag:'🇸🇳',name:'Senegal'},{code:'RS',flag:'🇷🇸',name:'Serbia'},
    {code:'SC',flag:'🇸🇨',name:'Seychelles'},{code:'SL',flag:'🇸🇱',name:'Sierra Leone'},
    {code:'SG',flag:'🇸🇬',name:'Singapore'},{code:'SK',flag:'🇸🇰',name:'Slovakia'},
    {code:'SI',flag:'🇸🇮',name:'Slovenia'},{code:'SB',flag:'🇸🇧',name:'Solomon Islands'},
    {code:'SO',flag:'🇸🇴',name:'Somalia'},{code:'ZA',flag:'🇿🇦',name:'South Africa'},
    {code:'SS',flag:'🇸🇸',name:'South Sudan'},{code:'ES',flag:'🇪🇸',name:'Spain'},
    {code:'LK',flag:'🇱🇰',name:'Sri Lanka'},{code:'SD',flag:'🇸🇩',name:'Sudan'},
    {code:'SR',flag:'🇸🇷',name:'Suriname'},{code:'SE',flag:'🇸🇪',name:'Sweden'},
    {code:'CH',flag:'🇨🇭',name:'Switzerland'},{code:'SY',flag:'🇸🇾',name:'Syria'},
    {code:'TW',flag:'🇹🇼',name:'Taiwan'},{code:'TJ',flag:'🇹🇯',name:'Tajikistan'},
    {code:'TZ',flag:'🇹🇿',name:'Tanzania'},{code:'TH',flag:'🇹🇭',name:'Thailand'},
    {code:'TL',flag:'🇹🇱',name:'Timor-Leste'},{code:'TG',flag:'🇹🇬',name:'Togo'},
    {code:'TO',flag:'🇹🇴',name:'Tonga'},{code:'TT',flag:'🇹🇹',name:'Trinidad and Tobago'},
    {code:'TN',flag:'🇹🇳',name:'Tunisia'},{code:'TR',flag:'🇹🇷',name:'Turkey'},
    {code:'TM',flag:'🇹🇲',name:'Turkmenistan'},{code:'TV',flag:'🇹🇻',name:'Tuvalu'},
    {code:'UG',flag:'🇺🇬',name:'Uganda'},{code:'UA',flag:'🇺🇦',name:'Ukraine'},
    {code:'AE',flag:'🇦🇪',name:'United Arab Emirates'},{code:'GB',flag:'🇬🇧',name:'United Kingdom'},
    {code:'US',flag:'🇺🇸',name:'United States'},{code:'UY',flag:'🇺🇾',name:'Uruguay'},
    {code:'UZ',flag:'🇺🇿',name:'Uzbekistan'},{code:'VU',flag:'🇻🇺',name:'Vanuatu'},
    {code:'VE',flag:'🇻🇪',name:'Venezuela'},{code:'VN',flag:'🇻🇳',name:'Vietnam'},
    {code:'YE',flag:'🇾🇪',name:'Yemen'},{code:'ZM',flag:'🇿🇲',name:'Zambia'},
    {code:'ZW',flag:'🇿🇼',name:'Zimbabwe'}
];

function populatePassportCountryDropdown() {
    const sel = document.getElementById('emp-passport-country');
    const cur = sel.value;
    sel.innerHTML = '<option value="">-- Select Country --</option>';
    COUNTRIES.forEach(function (c) {
        const opt = document.createElement('option');
        opt.value = c.code;
        opt.textContent = c.flag + '  ' + c.name;
        sel.appendChild(opt);
    });
    sel.value = cur;
}

// ── Helper: populate any country dropdown from COUNTRIES list ───────
function populateCountrySelect(selId) {
    const sel = document.getElementById(selId);
    if (!sel) return;
    const cur = sel.value;
    sel.innerHTML = '<option value="">-- Select Country --</option>';
    COUNTRIES.forEach(function (c) {
        const opt = document.createElement('option');
        opt.value = c.code;
        opt.textContent = c.flag + '  ' + c.name;
        sel.appendChild(opt);
    });
    sel.value = cur;
}

// ── Address country dropdown ────────────────────────────────────────
function populateAddressCountryDropdown()  { populateCountrySelect('emp-addr-country'); }


// ── TAB NAVIGATION ─────────────────────────────

const tabItems  = document.querySelectorAll('.tab-item');
const tabPanels = document.querySelectorAll('.tab-panel');

tabItems.forEach(function (item) {
    item.addEventListener('click', function () {
        tabItems.forEach(t => t.classList.remove('active'));
        tabPanels.forEach(p => p.classList.remove('active'));
        item.classList.add('active');
        const tab = item.getAttribute('data-tab');
        document.getElementById('tab-' + tab).classList.add('active');

        // Refresh dropdowns when switching tabs
        if (tab === 'employees')      populateEmployeeFormDropdowns();
        if (tab === 'departments')    { populateDeptFormDropdowns(); renderOrgChart(); }
        if (tab === 'workflow-roles') { populateWfEmpGrid(); renderWfRoles(); }
        if (tab === 'reference-data') {
            rdRenderPage1();
        }
        if (tab === 'reports') {
            showRptList();
            renderAdminReports();
        }
    });
});

// ═══════════════════════════════════════════════
// ── SECTION 1: EMPLOYEE MANAGEMENT ─────────────
// ═══════════════════════════════════════════════

const profileForm  = document.getElementById('profile-form');
const empSubmitBtn = document.getElementById('emp-submit-btn');
const empCancelBtn = document.getElementById('emp-cancel-btn');
const employeeBody = document.getElementById('employee-body');

let employees    = JSON.parse(localStorage.getItem('prowess-employees')) || [];
let editingEmpId = null;

// ── Populate dept + manager dropdowns in employee form

function populateEmployeeFormDropdowns() {
    populateDesignationDropdown();
    populateNationalityDropdown();
    populateMaritalStatusDropdown();
    populateRelationshipTypeDropdown();
    populatePassportCountryDropdown();
    populateAddressCountryDropdown();
    populateWorkCountrySelect();   // Country of Work (shares prowess-id-countries)
    populateBaseCurrencySelect();  // Base Currency (prowess-currencies)
    populateEmpFilters();
    const departments = JSON.parse(localStorage.getItem('prowess-departments')) || [];

    // Department dropdown
    const deptSelect = document.getElementById('emp-department');
    const currentDept = deptSelect.value;
    deptSelect.innerHTML = '<option value="">-- Select Department --</option>';
    departments.forEach(d => {
        const opt = document.createElement('option');
        opt.value = d.deptId;
        opt.textContent = `${d.name} (${d.deptId})`;
        deptSelect.appendChild(opt);
    });
    deptSelect.value = currentDept;

    // Manager dropdown — all employees except the one being edited
    const managerSelect = document.getElementById('emp-manager-id');
    const currentMgr = managerSelect.value;
    managerSelect.innerHTML = '<option value="">-- No Manager --</option>';
    employees.forEach(e => {
        if (editingEmpId && e.id === editingEmpId) return; // skip self
        const opt = document.createElement('option');
        opt.value = e.employeeId;
        opt.textContent = `${e.name} (${e.employeeId})`;
        managerSelect.appendChild(opt);
    });
    managerSelect.value = currentMgr;
}

// ── Auto-derive role based on org structure ─────

function deriveRole(empId) {
    // Check if this employee is a dept head of any department
    const departments = JSON.parse(localStorage.getItem('prowess-departments')) || [];
    const isDeptHead = departments.some(d => d.headId === empId);
    if (isDeptHead) return 'Dept Head';

    // Check if this employee is a manager of any other employee
    const isManager = employees.some(e => e.managerId === empId && e.id !== editingEmpId);
    if (isManager) return 'Manager';

    return 'Employee';
}

// ── Employee status helper ──────────────────────

function getEmpStatus(emp) {
    const today   = new Date().toISOString().split('T')[0];
    const endDate = emp.endDate || '9999-12-31';
    const hire    = emp.hireDate || '0000-01-01';
    if (hire > today) return 'Upcoming';
    if (endDate < today) return 'Inactive';
    return 'Active';
}

function getEmpStatusBadge(status) {
    const map = {
        'Active':   'badge-active',
        'Inactive': 'badge-expired',
        'Upcoming': 'badge-upcoming'
    };
    return `<span class="badge ${map[status] || 'badge-active'}">${status}</span>`;
}

// ── Populate filter dropdowns ───────────────────

function populateEmpFilters() {
    const departments = JSON.parse(localStorage.getItem('prowess-departments')) || [];

    // Designation filter
    const desgItems = JSON.parse(localStorage.getItem('prowess-designations')) || [];
    const desgSel   = document.getElementById('filter-designation');
    const curDesg   = desgSel.value;
    desgSel.innerHTML = '<option value="">All Designations</option>';
    [...desgItems].sort((a, b) => a.value.localeCompare(b.value)).forEach(function (d) {
        const o = document.createElement('option');
        o.value = d.refId || d.value; o.textContent = d.value;
        desgSel.appendChild(o);
    });
    desgSel.value = curDesg;

    // Department filter
    const deptSel = document.getElementById('filter-department');
    const curDept = deptSel.value;
    deptSel.innerHTML = '<option value="">All Departments</option>';
    departments.forEach(function (d) {
        const o = document.createElement('option');
        o.value = d.deptId; o.textContent = d.name;
        deptSel.appendChild(o);
    });
    deptSel.value = curDept;
}

// ── Render employees table ──────────────────────

function renderEmployees() {
    const departments = JSON.parse(localStorage.getItem('prowess-departments')) || [];

    // Read active filters
    const filterName   = (document.getElementById('filter-emp-name')?.value   || '').trim().toLowerCase();
    const filterId     = (document.getElementById('filter-emp-id')?.value     || '').trim().toLowerCase();
    const filterDesg   = (document.getElementById('filter-designation')?.value || '');
    const filterDept   = (document.getElementById('filter-department')?.value  || '');
    const filterStatus = (document.getElementById('filter-status')?.value      || '');

    const hasFilter = filterName || filterId || filterDesg || filterDept || filterStatus;
    const clearBtn  = document.getElementById('emp-filter-clear');
    if (clearBtn) clearBtn.style.display = hasFilter ? 'inline-flex' : 'none';

    // Apply filters
    let list = employees.filter(function (emp) {
        if (filterName && !emp.name.toLowerCase().includes(filterName))         return false;
        if (filterId   && !emp.employeeId.toLowerCase().includes(filterId))     return false;
        if (filterDesg && emp.designation !== filterDesg)                       return false;
        if (filterDept && emp.departmentId !== filterDept)                      return false;
        if (filterStatus && getEmpStatus(emp) !== filterStatus)                 return false;
        return true;
    });

    // Update count badge
    const countEl = document.getElementById('emp-filter-count');
    if (countEl) {
        countEl.textContent = hasFilter
            ? `${list.length} of ${employees.length} shown`
            : `${employees.length} employee${employees.length !== 1 ? 's' : ''}`;
    }

    // Update export button label to reflect current visible count
    updateEmpExportLabel(list.length, employees.length);

    // Refresh document alert panels whenever employees render
    renderPassportAlerts();
    renderIdAlerts();

    employeeBody.innerHTML = '';

    if (employees.length === 0) {
        employeeBody.innerHTML = '<tr><td colspan="8" class="no-data">No employees added yet.</td></tr>';
        return;
    }

    if (list.length === 0) {
        employeeBody.innerHTML = '<tr><td colspan="8" class="no-data">No employees match the current filters.</td></tr>';
        return;
    }

    list.forEach(function (emp, index) {
        const roleBadge    = getRoleBadge(emp.role || 'Employee');
        const statusBadge  = getEmpStatusBadge(getEmpStatus(emp));
        const deptName     = emp.departmentId
            ? (departments.find(d => d.deptId === emp.departmentId)?.name || emp.departmentId)
            : '—';
        const managerName  = emp.managerId
            ? (employees.find(e => e.employeeId === emp.managerId)?.name || emp.managerId)
            : '—';
        const initial      = (emp.name || '?').charAt(0).toUpperCase();
        const avatarColor  = getAvatarColor(emp.name);
        const passportAlert = emp.passportExpiryDate
            ? getPassportAlertLevel(emp.passportExpiryDate)
            : null;
        const passportIcon  = passportAlert
            ? `<i class="fa-solid fa-passport emp-passport-icon emp-passport-${passportAlert.level}" title="Passport ${passportAlert.level === 'expired' ? 'expired' : 'expiring in ' + passportAlert.days + 'd'}"></i>`
            : '';

        const row = document.createElement('tr');
        row.innerHTML = `
            <td class="emp-td-num">${index + 1}</td>
            <td>
                <div class="emp-name-cell">
                    <div class="emp-avatar-sm" style="background:${avatarColor};">${initial}</div>
                    <div class="emp-name-info">
                        <span class="emp-name-primary">${emp.name}${passportIcon}</span>
                        <span class="emp-name-id">${emp.employeeId}</span>
                    </div>
                </div>
            </td>
            <td class="emp-td-desg">${resolveRefLabel(emp.designation, 'prowess-designations') || '—'}</td>
            <td>${deptName}</td>
            <td class="emp-td-mgr">${managerName !== '—' ? `<span class="emp-manager-tag">${managerName}</span>` : '<span class="emp-dash">—</span>'}</td>
            <td>${roleBadge}</td>
            <td>${statusBadge}</td>
            <td>
                <div class="emp-action-btns">
                    <button class="btn-view" data-id="${emp.id}" title="View employee details">
                        <i class="fa-solid fa-eye" data-id="${emp.id}"></i>
                    </button>
                    <button class="btn-edit" data-id="${emp.id}" title="Edit employee">
                        <i class="fa-solid fa-pen-to-square" data-id="${emp.id}"></i>
                    </button>
                    <button class="btn-delete" data-id="${emp.id}" title="Delete employee">
                        <i class="fa-solid fa-trash" data-id="${emp.id}"></i>
                    </button>
                </div>
            </td>
        `;
        employeeBody.appendChild(row);
    });
}

// ── Employee avatar color (consistent per first letter) ────
const EMP_AVATAR_PALETTE = [
    '#3b5fc0','#0f9d8a','#c0392b','#7b4fa6','#e07b00',
    '#1a7a4a','#b03060','#2980b9','#6d4c00','#336b4a'
];
function getAvatarColor(name) {
    const code = (name || 'A').toUpperCase().charCodeAt(0) - 65;
    return EMP_AVATAR_PALETTE[Math.abs(code) % EMP_AVATAR_PALETTE.length];
}

function getRoleBadge(role) {
    const colors = {
        'Employee':  'badge-active',
        'Manager':   'badge-upcoming',
        'Dept Head': 'badge-depthead',
        'HR':        'badge-hr',
        'Finance':   'badge-finance'
    };
    return `<span class="badge ${colors[role] || 'badge-active'}">${role}</span>`;
}

// ── Handle add / update employee ────────────────

profileForm.addEventListener('submit', function (event) {
    event.preventDefault();

    // ── Auto-save any pending ID sub-form entry ──────────────────────────────
    // If the user filled in the sub-form but forgot to click "Add ID",
    // automatically flush it into tempEmpIds so the data is not silently lost.
    {
        const pendingCountry = document.getElementById('emp-id-country').value;
        const pendingType    = document.getElementById('emp-id-type').value;
        const pendingNumber  = document.getElementById('emp-id-number').value.trim();
        const pendingExpiry  = document.getElementById('emp-id-expiry').value;

        const pendingIsPrimaryV = document.getElementById('emp-id-is-primary').value;
        if (pendingCountry && pendingType && pendingNumber) {
            // Record Type must be chosen
            if (!pendingIsPrimaryV) {
                alert('Please select a Record Type (Primary or Secondary) for the pending ID record, or clear the ID sub-form.');
                document.getElementById('emp-id-is-primary').focus();
                return;
            }
            // Validate expiry if provided
            if (pendingExpiry) {
                const today = new Date().toISOString().split('T')[0];
                if (pendingExpiry <= today) {
                    alert('The pending ID record has a past expiry date. Please correct it or clear the ID sub-form before saving.');
                    document.getElementById('emp-id-expiry').focus();
                    return;
                }
            }
            const pendingIsPrimary = (pendingIsPrimaryV === 'primary');
            // If new record is primary, demote any existing primary
            if (pendingIsPrimary) {
                tempEmpIds = tempEmpIds.map(r => r.isPrimary ? { ...r, isPrimary: false } : r);
            }
            // Add if no duplicate type
            const alreadyExists = tempEmpIds.some(r => String(r.idTypeId) === String(pendingType));
            if (!alreadyExists) {
                tempEmpIds.push({ id: Date.now(), countryId: pendingCountry, idTypeId: pendingType,
                                  isPrimary: pendingIsPrimary, idNumber: pendingNumber, expiryDate: pendingExpiry });
                resetIdAddForm();
                renderEmpIdList();
            }
        }
    }

    const name          = document.getElementById('emp-name').value.trim();
    const employeeId    = document.getElementById('emp-id').value.trim().toUpperCase();
    const designation   = document.getElementById('emp-designation').value.trim();
    const countryCode   = document.getElementById('emp-country-code').value;
    const phoneRaw      = document.getElementById('emp-phone').value.trim();
    const departmentId  = document.getElementById('emp-department').value;
    const managerId     = document.getElementById('emp-manager-id').value;
    const hireDate        = document.getElementById('emp-hire-date').value;
    const endDate         = document.getElementById('emp-end-date').value || '9999-12-31';
    const workCountryId   = document.getElementById('emp-work-country').value;
    const workLocationId  = document.getElementById('emp-work-location').value;
    const baseCurrencyCode = document.getElementById('emp-base-currency').value;

    // ── Country of Work / Location validation ──
    if (!workCountryId) {
        alert('Country of Work is required.');
        document.getElementById('emp-work-country').focus();
        return;
    }
    if (!workLocationId) {
        alert('Location is required. Please select a Country of Work first, then choose a Location.');
        document.getElementById('emp-work-location').focus();
        return;
    }
    const nationality   = document.getElementById('emp-nationality').value.trim();
    const maritalStatus = document.getElementById('emp-marital-status').value;

    // ── Passport fields (all optional, but if any filled all must be filled) ──
    const passportCountry    = document.getElementById('emp-passport-country').value;
    const passportNumber     = document.getElementById('emp-passport-number').value.trim().toUpperCase();
    const passportIssueDate  = document.getElementById('emp-passport-issue-date').value;
    const passportExpiryDate = document.getElementById('emp-passport-expiry-date').value;

    // ── Passport validation ──────────────────────
    // Rule 1: if passport number is provided, issue date + expiry date are mandatory
    if (passportNumber && !passportIssueDate) {
        alert('Passport Issue Date is required when a Passport Number is entered.');
        document.getElementById('emp-passport-issue-date').focus();
        return;
    }
    if (passportNumber && !passportExpiryDate) {
        alert('Passport Expiry Date is required when a Passport Number is entered.');
        document.getElementById('emp-passport-expiry-date').focus();
        return;
    }
    // Rule 2: any partial entry (except number-only handled above) must be complete
    const passportFieldsFilled = [passportCountry, passportNumber, passportIssueDate, passportExpiryDate]
        .filter(Boolean).length;
    if (passportFieldsFilled > 0 && passportFieldsFilled < 4) {
        alert('Passport information is optional, but if entered all four fields (Issue Country, Passport Number, Issue Date, Expiry Date) are required.');
        return;
    }
    // Rule 3: expiry must be strictly after issue date
    if (passportIssueDate && passportExpiryDate && passportExpiryDate <= passportIssueDate) {
        alert('Passport Expiry Date must be after the Issue Date.');
        document.getElementById('emp-passport-expiry-date').focus();
        return;
    }

    const businessEmail = document.getElementById('emp-business-email').value.trim().toLowerCase();
    const personalEmail = document.getElementById('emp-personal-email').value.trim().toLowerCase();

    // ── Emergency contact fields ────────────────────────────────────
    const ecName         = document.getElementById('ec-name').value.trim();
    const ecRelationship = document.getElementById('ec-relationship').value;
    const ecPhone        = document.getElementById('ec-phone').value.trim();
    const ecAltPhone     = document.getElementById('ec-alt-phone').value.trim();
    const ecEmail        = document.getElementById('ec-email').value.trim();
    // ── Address fields ──────────────────────────────────────────────
    const addrLine1    = document.getElementById('emp-addr-line1').value.trim();
    const addrLine2    = document.getElementById('emp-addr-line2').value.trim();
    const addrLandmark = document.getElementById('emp-addr-landmark').value.trim();
    const addrCity     = document.getElementById('emp-addr-city').value.trim();
    const addrDistrict = document.getElementById('emp-addr-district').value.trim();
    const addrState    = document.getElementById('emp-addr-state').value.trim();
    const addrPin      = document.getElementById('emp-addr-pin').value.trim();
    const addrCountry  = document.getElementById('emp-addr-country').value;

    // ── Phone validation: digits only, 7–15 chars ──
    const phoneDigits = phoneRaw.replace(/[\s\-().]/g, '');
    const phoneError  = document.getElementById('emp-phone-error');
    if (!/^\d{7,15}$/.test(phoneDigits)) {
        phoneError.style.display = 'block';
        document.getElementById('emp-phone').focus();
        return;
    }
    phoneError.style.display = 'none';
    const mobile = countryCode + ' ' + phoneRaw;

    // ── Email format validation ──
    const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
    const bizErrEl   = document.getElementById('emp-business-email-error');
    const bizErrMsg  = document.getElementById('emp-business-email-error-msg');
    const perErrEl   = document.getElementById('emp-personal-email-error');
    const perErrMsg  = document.getElementById('emp-personal-email-error-msg');

    bizErrEl.style.display = 'none';
    perErrEl.style.display = 'none';

    if (!emailRegex.test(businessEmail)) {
        bizErrMsg.textContent = 'Enter a valid business email address.';
        bizErrEl.style.display = 'block';
        document.getElementById('emp-business-email').focus();
        return;
    }
    if (!emailRegex.test(personalEmail)) {
        perErrMsg.textContent = 'Enter a valid personal email address.';
        perErrEl.style.display = 'block';
        document.getElementById('emp-personal-email').focus();
        return;
    }

    // ── Business and personal email must not be the same ──
    if (businessEmail === personalEmail) {
        perErrMsg.textContent = 'Personal email must be different from the business email.';
        perErrEl.style.display = 'block';
        document.getElementById('emp-personal-email').focus();
        return;
    }

    // ── Email uniqueness across all employees ──
    const otherEmployees = editingEmpId !== null
        ? employees.filter(e => e.id !== editingEmpId)
        : employees;

    const bizConflict = otherEmployees.find(e =>
        (e.businessEmail || '').toLowerCase() === businessEmail ||
        (e.personalEmail  || '').toLowerCase() === businessEmail
    );
    if (bizConflict) {
        bizErrMsg.textContent = `This email is already in use by ${bizConflict.name} (${bizConflict.employeeId}).`;
        bizErrEl.style.display = 'block';
        document.getElementById('emp-business-email').focus();
        return;
    }

    const perConflict = otherEmployees.find(e =>
        (e.businessEmail || '').toLowerCase() === personalEmail ||
        (e.personalEmail  || '').toLowerCase() === personalEmail
    );
    if (perConflict) {
        perErrMsg.textContent = `This email is already in use by ${perConflict.name} (${perConflict.employeeId}).`;
        perErrEl.style.display = 'block';
        document.getElementById('emp-personal-email').focus();
        return;
    }

    // ── Validation: employee cannot be their own manager ──
    if (managerId && managerId === employeeId) {
        alert('An employee cannot be their own manager.');
        return;
    }

    // Role is always auto-derived — never manually set
    const role = deriveRole(employeeId);

    if (editingEmpId !== null) {
        // ── EDIT MODE ──
        const oldEmp       = employees.find(e => e.id === editingEmpId);
        const oldManagerId = oldEmp ? oldEmp.managerId : null;

        employees = employees.map(function (emp) {
            if (emp.id === editingEmpId) {
                return { ...emp, name, employeeId, designation, mobile, countryCode, phone: phoneRaw,
                         departmentId, managerId, role, hireDate, endDate, nationality, maritalStatus,
                         businessEmail, personalEmail,
                         passportCountry, passportNumber, passportIssueDate, passportExpiryDate,
                         identifications: [...tempEmpIds],
                         photo: emp.photo || null,
                         // Work location + base currency
                         workCountryId, workLocationId, baseCurrencyCode,
                         // Address
                         addrLine1, addrLine2, addrLandmark, addrCity,
                         addrDistrict, addrState, addrPin, addrCountry,
                         // Emergency contact
                         ecName, ecRelationship, ecPhone, ecAltPhone, ecEmail };
            }
            return emp;
        });

        // Promote new manager
        if (managerId) updateManagerRole(managerId);

        // If manager was removed or changed, re-evaluate the old manager's role
        if (oldManagerId && oldManagerId !== managerId) reEvaluateRole(oldManagerId);

        // Update active profile if this is the current employee
        syncProfile(editingEmpId);
        resetEmpForm();

    } else {
        // ── ADD MODE ──
        const duplicate = employees.find(e => e.employeeId.toLowerCase() === employeeId.toLowerCase());
        if (duplicate) {
            alert('An employee with this ID already exists.');
            return;
        }

        const newEmployee = {
            id: Date.now(),
            name, employeeId, designation, mobile, countryCode, phone: phoneRaw,
            departmentId, managerId, role, hireDate, endDate, nationality, maritalStatus,
            businessEmail, personalEmail,
            passportCountry, passportNumber, passportIssueDate, passportExpiryDate,
            identifications: [...tempEmpIds], photo: null,
            // Work location + base currency
            workCountryId, workLocationId, baseCurrencyCode,
            // Address
            addrLine1, addrLine2, addrLandmark, addrCity,
            addrDistrict, addrState, addrPin, addrCountry,
            // Emergency contact
            ecName, ecRelationship, ecPhone, ecAltPhone, ecEmail
        };
        employees.push(newEmployee);

        // Update manager's role
        if (managerId) updateManagerRole(managerId);

        // Set first employee as active profile
        if (employees.length === 1) {
            localStorage.setItem('prowess-profile', JSON.stringify(newEmployee));
        }

        resetEmpForm();
    }

    localStorage.setItem('prowess-employees', JSON.stringify(employees));
    renderEmployees();
});

// ── When an employee becomes a manager, update their role

function updateManagerRole(managerId) {
    employees = employees.map(function (emp) {
        if (emp.employeeId === managerId) {
            // Dept Head, HR and Finance always win — never downgrade them to Manager
            if (['Dept Head', 'HR', 'Finance'].includes(emp.role)) return emp;
            return { ...emp, role: 'Manager' };
        }
        return emp;
    });
}

// ── Re-evaluate role when someone loses a report or is unassigned as manager

function reEvaluateRole(empId) {
    if (!empId) return;
    const depts = JSON.parse(localStorage.getItem('prowess-departments')) || [];
    const isDeptHead   = depts.some(d => d.headId === empId);
    const stillManages = employees.some(e => e.managerId === empId);
    employees = employees.map(function (emp) {
        if (emp.employeeId === empId) {
            if (isDeptHead)    return { ...emp, role: 'Dept Head' };
            if (stillManages)  return { ...emp, role: 'Manager' };
            return { ...emp, role: 'Employee' };
        }
        return emp;
    });
}

// ── Sync active profile with updated employee data

function syncProfile(empId) {
    const currentProfile = JSON.parse(localStorage.getItem('prowess-profile')) || {};
    if (currentProfile.id === empId) {
        const updated = employees.find(e => e.id === empId);
        if (updated) localStorage.setItem('prowess-profile', JSON.stringify(updated));
    }
}

// ── Handle edit / delete clicks ─────────────────

employeeBody.addEventListener('click', function (event) {

    // View employee details panel
    const viewBtn = event.target.closest('.btn-view');
    if (viewBtn) {
        const id = Number(viewBtn.getAttribute('data-id'));
        openEmpView(id);
        return;
    }

    const editBtn = event.target.closest('.btn-edit');
    if (editBtn) {
        const id  = Number(editBtn.getAttribute('data-id'));
        const emp = employees.find(e => e.id === id);

        document.getElementById('emp-name').value        = emp.name;
        document.getElementById('emp-id').value          = emp.employeeId;
        document.getElementById('emp-country-code').value    = emp.countryCode || '+91';
        document.getElementById('emp-phone').value           = emp.phone || '';
        document.getElementById('emp-hire-date').value       = emp.hireDate || '';
        document.getElementById('emp-end-date').value        = emp.endDate || '9999-12-31';
        document.getElementById('emp-business-email').value       = emp.businessEmail || '';
        document.getElementById('emp-personal-email').value       = emp.personalEmail || '';
        document.getElementById('emp-passport-number').value      = emp.passportNumber || '';
        document.getElementById('emp-passport-issue-date').value  = emp.passportIssueDate || '';
        document.getElementById('emp-passport-expiry-date').value = emp.passportExpiryDate || '';
        updatePassportDateRequired(); // apply required state based on restored passport number
        document.getElementById('emp-phone-error').style.display         = 'none';
        document.getElementById('emp-business-email-error').style.display = 'none';
        document.getElementById('emp-personal-email-error').style.display = 'none';

        // Populate all dropdowns first, then restore saved values
        editingEmpId = id;
        populateEmployeeFormDropdowns();
        populateIdCountrySelects(); // ensure ID countries are ready before rendering records
        document.getElementById('emp-designation').value       = emp.designation || '';
        document.getElementById('emp-nationality').value       = emp.nationality || '';
        document.getElementById('emp-marital-status').value    = emp.maritalStatus || '';
        document.getElementById('emp-department').value        = emp.departmentId || '';
        document.getElementById('emp-manager-id').value        = emp.managerId || '';
        document.getElementById('emp-passport-country').value  = emp.passportCountry || '';

        // Load identification records AFTER all dropdowns are ready
        tempEmpIds = emp.identifications ? JSON.parse(JSON.stringify(emp.identifications)) : [];
        resetIdAddForm();
        renderEmpIdList();

        // Restore emergency contact fields
        document.getElementById('ec-name').value         = emp.ecName         || '';
        document.getElementById('ec-relationship').value = emp.ecRelationship || '';
        document.getElementById('ec-phone').value        = emp.ecPhone        || '';
        document.getElementById('ec-alt-phone').value    = emp.ecAltPhone     || '';
        document.getElementById('ec-email').value        = emp.ecEmail        || '';
        // Restore Country of Work → then filter and restore Location
        // (must populate location select first so the saved value can be selected)
        document.getElementById('emp-work-country').value = emp.workCountryId || '';
        populateWorkLocationSelect(emp.workCountryId || '');
        document.getElementById('emp-work-location').value = emp.workLocationId || '';
        document.getElementById('emp-base-currency').value = emp.baseCurrencyCode || '';

        // Restore address fields
        document.getElementById('emp-addr-line1').value    = emp.addrLine1    || '';
        document.getElementById('emp-addr-line2').value    = emp.addrLine2    || '';
        document.getElementById('emp-addr-landmark').value = emp.addrLandmark || '';
        document.getElementById('emp-addr-city').value     = emp.addrCity     || '';
        document.getElementById('emp-addr-district').value = emp.addrDistrict || '';
        document.getElementById('emp-addr-state').value    = emp.addrState    || '';
        document.getElementById('emp-addr-pin').value      = emp.addrPin      || '';
        document.getElementById('emp-addr-country').value  = emp.addrCountry  || '';

        // Restore photo preview
        empSetAvatarPreview(emp.photo || null);

        empSubmitBtn.innerHTML = '<i class="fa-solid fa-floppy-disk"></i> Update Employee';
        empCancelBtn.style.display = 'inline-flex';
        document.getElementById('emp-form-title').textContent = 'Edit Employee — ' + emp.name;
        // Refresh progress tracker to reflect restored values
        if (typeof empUpdateFormProgress === 'function') empUpdateFormProgress();
        profileForm.scrollIntoView({ behavior: 'smooth' });
        return;
    }

    const deleteBtn = event.target.closest('.btn-delete');
    if (deleteBtn) {
        if (!confirm('Are you sure you want to delete this employee?')) return;
        const id         = Number(deleteBtn.getAttribute('data-id'));
        const deletedEmp = employees.find(e => e.id === id);
        employees = employees.filter(e => e.id !== id);

        // If the deleted employee had a manager, re-evaluate that manager's role
        if (deletedEmp && deletedEmp.managerId) reEvaluateRole(deletedEmp.managerId);

        localStorage.setItem('prowess-employees', JSON.stringify(employees));

        // Reassign active profile if needed
        const currentProfile = JSON.parse(localStorage.getItem('prowess-profile')) || {};
        if (currentProfile.id === id) {
            employees.length > 0
                ? localStorage.setItem('prowess-profile', JSON.stringify(employees[0]))
                : localStorage.removeItem('prowess-profile');
        }
        renderEmployees();
    }
});

empCancelBtn.addEventListener('click', resetEmpForm);

// Set defaults on page load
document.getElementById('emp-end-date').value = '9999-12-31';

// ── Employee avatar preview (read-only, photo set by employee via portal) ──

let empCurrentPhoto = null;

function empSetAvatarPreview(photoSrc) {
    empCurrentPhoto = photoSrc || null;
    const icon = document.getElementById('emp-avatar-icon');
    const img  = document.getElementById('emp-avatar-img');
    if (!icon || !img) return;
    if (photoSrc) {
        img.src = photoSrc;
        img.style.display = 'block';
        icon.style.display = 'none';
    } else {
        img.src = '';
        img.style.display = 'none';
        icon.style.display = '';
    }
}

// ── Filter listeners ────────────────────────────

['filter-emp-name', 'filter-emp-id', 'filter-designation', 'filter-department', 'filter-status'].forEach(function (id) {
    document.getElementById(id).addEventListener('input', renderEmployees);
    document.getElementById(id).addEventListener('change', renderEmployees);
});

document.getElementById('emp-filter-clear').addEventListener('click', function () {
    document.getElementById('filter-emp-name').value     = '';
    document.getElementById('filter-emp-id').value       = '';
    document.getElementById('filter-designation').value  = '';
    document.getElementById('filter-department').value   = '';
    document.getElementById('filter-status').value       = '';
    renderEmployees();
});

// ── Dept filter listeners ───────────────────────

['filter-dept-name', 'filter-dept-id', 'filter-dept-head', 'filter-dept-parent', 'filter-dept-status'].forEach(function (id) {
    const el = document.getElementById(id);
    if (el) {
        el.addEventListener('input', renderDepartments);
        el.addEventListener('change', renderDepartments);
    }
});

const deptFilterClearBtn = document.getElementById('dept-filter-clear');
if (deptFilterClearBtn) {
    deptFilterClearBtn.addEventListener('click', function () {
        const n = document.getElementById('filter-dept-name');   if (n) n.value = '';
        const i = document.getElementById('filter-dept-id');     if (i) i.value = '';
        const h = document.getElementById('filter-dept-head');   if (h) h.value = '';
        const p = document.getElementById('filter-dept-parent'); if (p) p.value = '';
        const s = document.getElementById('filter-dept-status'); if (s) s.value = '';
        renderDepartments();
    });
}

// ── Dynamically require issue/expiry dates when passport number is filled ──

function updatePassportDateRequired() {
    const hasNumber   = document.getElementById('emp-passport-number').value.trim().length > 0;
    const issueField  = document.getElementById('emp-passport-issue-date');
    const expiryField = document.getElementById('emp-passport-expiry-date');
    if (hasNumber) {
        issueField.setAttribute('required', '');
        expiryField.setAttribute('required', '');
    } else {
        issueField.removeAttribute('required');
        expiryField.removeAttribute('required');
    }
}

// Live listener — fires as the user types in the passport number field
document.getElementById('emp-passport-number')
    .addEventListener('input', updatePassportDateRequired);

// ═══════════════════════════════════════════════════════════════════════════
// ── EMPLOYEE FORM UX ENHANCEMENTS (progress, collapse, success states) ──────
// ═══════════════════════════════════════════════════════════════════════════

// Section metadata: which required field IDs belong to each section
var EMP_SECTION_META = [
    { id: 's-personal',   required: ['emp-name','emp-id','emp-nationality','emp-marital-status'], optional: false },
    { id: 's-contact',    required: ['emp-phone'], optional: false },
    { id: 's-email',      required: ['emp-business-email','emp-personal-email'], optional: false },
    { id: 's-passport',   required: [], optional: true },
    { id: 's-identity',   required: [], optional: true },
    { id: 's-employment', required: ['emp-designation','emp-department','emp-hire-date','emp-end-date','emp-work-country','emp-work-location'], optional: false },
    { id: 's-address',    required: ['emp-addr-line1','emp-addr-line2','emp-addr-city','emp-addr-district','emp-addr-country'], optional: false },
    { id: 's-emergency',  required: ['ec-name','ec-relationship','ec-phone'], optional: false },
];

// ── Initialise sections: add data-section-id, icon bubble, check, chevron, body wrapper ──
(function empInitSections() {
    var keyMap = {
        'Personal Information': 's-personal',
        'Contact Details':      's-contact',
        'Email Addresses':      's-email',
        'Passport Information': 's-passport',
        'Employee Identification': 's-identity',
        'Employment Details':   's-employment',
        'Address Information':  's-address',
        'Emergency Contact':    's-emergency',
    };

    document.querySelectorAll('.emp-section').forEach(function(section) {
        var label = section.querySelector(':scope > .emp-section-label');
        if (!label) return;

        // Match section by keyword in label text
        var text = label.textContent.trim();
        var sectionId = null;
        Object.keys(keyMap).forEach(function(k) {
            if (text.indexOf(k) !== -1) sectionId = keyMap[k];
        });
        if (!sectionId) return;
        section.dataset.sectionId = sectionId;

        // Wrap existing icon in bubble
        var icon = label.querySelector(':scope > i');
        if (icon) {
            var bubble = document.createElement('span');
            bubble.className = 'esc-icon-bubble';
            label.insertBefore(bubble, icon);
            bubble.appendChild(icon);
        }

        // Append right-side controls (check + chevron)
        var right = document.createElement('span');
        right.className = 'esc-right';
        right.innerHTML = '<i class="fa-solid fa-circle-check esc-check"></i>' +
                          '<i class="fa-solid fa-chevron-down esc-chevron"></i>';
        label.appendChild(right);

        // Wrap all non-label children in emp-section-body
        var body = document.createElement('div');
        body.className = 'emp-section-body';
        Array.from(section.children).forEach(function(child) {
            if (child !== label) body.appendChild(child);
        });
        section.appendChild(body);

        // Collapse toggle on label click
        label.addEventListener('click', function() {
            section.classList.toggle('esc-collapsed');
        });
    });
})();

// ── Update progress tracker + section completion states ──────────────────────
function empUpdateFormProgress() {
    EMP_SECTION_META.forEach(function(meta, idx) {
        var section = document.querySelector('[data-section-id="' + meta.id + '"]');
        var step    = document.querySelector('.efp-step[data-target="' + meta.id + '"]');

        // Mark required select/date fields with efp-valid for CSS success state
        if (section) {
            section.querySelectorAll('select[required], input[type="date"][required]').forEach(function(el) {
                el.classList.toggle('efp-valid', el.value !== '');
            });
        }

        // Determine completion
        var isDone = !meta.optional && meta.required.length > 0 &&
            meta.required.every(function(id) {
                var el = document.getElementById(id);
                return el && el.value && el.value.trim() !== '';
            });

        if (section) section.classList.toggle('esc-complete', isDone);
        if (step)    step.classList.toggle('efp-done', isDone);
    });

    // Update connector lines
    var connectors = document.querySelectorAll('.efp-connector');
    EMP_SECTION_META.forEach(function(meta, idx) {
        if (idx >= connectors.length) return;
        var isDone = !meta.optional && meta.required.length > 0 &&
            meta.required.every(function(id) {
                var el = document.getElementById(id);
                return el && el.value && el.value.trim() !== '';
            });
        connectors[idx].classList.toggle('efp-done', isDone);
    });
}

// Wire form input/change → progress update
(function() {
    var form = document.getElementById('profile-form');
    if (form) {
        form.addEventListener('input',  empUpdateFormProgress);
        form.addEventListener('change', empUpdateFormProgress);
    }
})();

// Progress step click → scroll to section (expanding if collapsed)
document.querySelectorAll('.efp-step[data-target]').forEach(function(step) {
    step.addEventListener('click', function() {
        var section = document.querySelector('[data-section-id="' + step.dataset.target + '"]');
        if (!section) return;
        section.classList.remove('esc-collapsed');
        setTimeout(function() {
            section.scrollIntoView({ behavior: 'smooth', block: 'start' });
        }, 50);
    });
});

// When browser native validation fires on a field, expand its section and shake
document.querySelectorAll('#profile-form [required]').forEach(function(el) {
    el.addEventListener('invalid', function() {
        var section = el.closest('.emp-section');
        if (section) section.classList.remove('esc-collapsed');
        setTimeout(function() {
            el.scrollIntoView({ behavior: 'smooth', block: 'center' });
            el.classList.add('efp-shake');
            setTimeout(function() { el.classList.remove('efp-shake'); }, 420);
        }, 80);
    });
});

// Run once on load to reflect restored edit state
empUpdateFormProgress();

function resetEmpForm() {
    profileForm.reset();
    editingEmpId = null;
    // Re-apply defaults that reset() clears
    document.getElementById('emp-end-date').value = '9999-12-31';
    document.getElementById('emp-country-code').value = '+91';
    document.getElementById('emp-phone-error').style.display          = 'none';
    document.getElementById('emp-business-email-error').style.display = 'none';
    document.getElementById('emp-personal-email-error').style.display = 'none';
    // Clear dynamic passport date required state
    updatePassportDateRequired();
    // Clear identification records buffer
    tempEmpIds = [];
    resetIdAddForm();
    renderEmpIdList();
    document.getElementById('emp-form-title').textContent = 'New Employee';
    empSubmitBtn.innerHTML = '<i class="fa-solid fa-plus"></i> Add Employee';
    empCancelBtn.style.display = 'none';
    empSetAvatarPreview(null);
    // Reset Emergency Contact fields
    ['ec-name','ec-relationship','ec-phone','ec-alt-phone','ec-email']
        .forEach(function(id) {
            var el = document.getElementById(id);
            if (el) el.value = '';
        });
}

// ═══════════════════════════════════════════════
// ── PASSPORT ALERTS ─────────────────────────────
// ═══════════════════════════════════════════════

// Thresholds (days before expiry)
const PASSPORT_CRITICAL_DAYS = 30;
const PASSPORT_WARNING_DAYS  = 90;

function getPassportAlertLevel(expiryDate) {
    if (!expiryDate) return null;
    const today     = new Date(); today.setHours(0,0,0,0);
    const expiry    = new Date(expiryDate);
    const diffDays  = Math.floor((expiry - today) / 86400000);
    if (diffDays < 0)                             return { level: 'expired',  days: Math.abs(diffDays) };
    if (diffDays <= PASSPORT_CRITICAL_DAYS)       return { level: 'critical', days: diffDays };
    if (diffDays <= PASSPORT_WARNING_DAYS)        return { level: 'warning',  days: diffDays };
    return null;
}

function getHrEmails() {
    const wfRoles = JSON.parse(localStorage.getItem('prowess-wf-roles')) || [];
    const hrRole  = wfRoles.find(r => r.name.toLowerCase() === 'hr');
    if (!hrRole || !hrRole.members || hrRole.members.length === 0) return [];
    return hrRole.members
        .map(empId => employees.find(e => e.employeeId === empId))
        .filter(Boolean)
        .map(e => e.businessEmail)
        .filter(Boolean);
}

function buildNotifyMailto(emp, alert) {
    const countryName = emp.passportCountry
        ? (COUNTRIES.find(c => c.code === emp.passportCountry)?.name || emp.passportCountry)
        : '';
    const hrEmails   = getHrEmails();
    const toAddress  = emp.businessEmail || emp.personalEmail || '';
    const ccAddress  = hrEmails.filter(e => e !== toAddress).join(',');

    let subjectVerb, bodyUrgency;
    if (alert.level === 'expired') {
        subjectVerb  = 'EXPIRED';
        bodyUrgency  = `Your passport has EXPIRED ${alert.days} day(s) ago. Immediate renewal is required.`;
    } else if (alert.level === 'critical') {
        subjectVerb  = `Expiring in ${alert.days} day(s) — ACTION REQUIRED`;
        bodyUrgency  = `Your passport is expiring in ${alert.days} day(s). Please initiate renewal immediately.`;
    } else {
        subjectVerb  = `Expiring in ${alert.days} days — Reminder`;
        bodyUrgency  = `Your passport will expire in ${alert.days} days. Please plan for renewal.`;
    }

    const subject = encodeURIComponent(`Passport ${subjectVerb} — ${emp.name} (${emp.employeeId})`);
    const body    = encodeURIComponent(
        `Dear ${emp.name},\n\n` +
        `${bodyUrgency}\n\n` +
        `Passport Details:\n` +
        `  Employee   : ${emp.name} (${emp.employeeId})\n` +
        `  Country    : ${countryName}\n` +
        `  Passport # : ${emp.passportNumber || '—'}\n` +
        `  Issue Date : ${emp.passportIssueDate || '—'}\n` +
        `  Expiry Date: ${emp.passportExpiryDate || '—'}\n\n` +
        `Please take the necessary steps at your earliest convenience.\n\n` +
        `Regards,\nProwess HR Team`
    );

    let href = `mailto:${toAddress}?subject=${subject}&body=${body}`;
    if (ccAddress) href += `&cc=${encodeURIComponent(ccAddress)}`;
    return href;
}

function renderPassportAlerts() {
    const panel = document.getElementById('passport-alerts-panel');
    if (!panel) return;

    // Collect employees with passport alerts
    const alerts = [];
    employees.forEach(function (emp) {
        if (!emp.passportExpiryDate) return;
        const alert = getPassportAlertLevel(emp.passportExpiryDate);
        if (alert) alerts.push({ emp, alert });
    });

    // Update sidebar badge
    const sidebarItem = document.querySelector('.tab-item[data-tab="employees"]');
    const existingBadge = sidebarItem ? sidebarItem.querySelector('.passport-alert-badge') : null;
    if (alerts.length > 0) {
        if (sidebarItem && !existingBadge) {
            const badge = document.createElement('span');
            badge.className = 'passport-alert-badge';
            badge.title = `${alerts.length} passport alert(s)`;
            badge.textContent = alerts.length;
            sidebarItem.appendChild(badge);
        } else if (existingBadge) {
            existingBadge.textContent = alerts.length;
        }
    } else {
        if (existingBadge) existingBadge.remove();
    }

    if (alerts.length === 0) {
        panel.style.display = 'none';
        panel.innerHTML = '';
        return;
    }

    // Sort: expired first, then critical, then warning
    const order = { expired: 0, critical: 1, warning: 2 };
    alerts.sort((a, b) => order[a.alert.level] - order[b.alert.level] || a.alert.days - b.alert.days);

    const expired  = alerts.filter(a => a.alert.level === 'expired');
    const critical = alerts.filter(a => a.alert.level === 'critical');
    const warning  = alerts.filter(a => a.alert.level === 'warning');

    function buildRows(items) {
        return items.map(function ({ emp, alert }) {
            const countryName = emp.passportCountry
                ? (COUNTRIES.find(c => c.code === emp.passportCountry)?.name || emp.passportCountry)
                : '—';
            const flagEmoji = emp.passportCountry
                ? (COUNTRIES.find(c => c.code === emp.passportCountry)?.flag || '')
                : '';
            let dayLabel;
            if (alert.level === 'expired')  dayLabel = `Expired ${alert.days}d ago`;
            else if (alert.level === 'critical') dayLabel = `Expires in ${alert.days}d`;
            else                            dayLabel = `Expires in ${alert.days}d`;

            const mailtoHref = buildNotifyMailto(emp, alert);
            return `
              <div class="pa-row">
                <div class="pa-emp-info">
                  <strong>${emp.name}</strong>
                  <span class="pa-empid">${emp.employeeId}</span>
                </div>
                <div class="pa-passport-info">
                  <span class="pa-flag">${flagEmoji}</span>
                  <span>${countryName}</span>
                  <span class="pa-sep">·</span>
                  <span>${emp.passportNumber || '—'}</span>
                  <span class="pa-sep">·</span>
                  <span>${emp.passportExpiryDate || '—'}</span>
                </div>
                <div class="pa-days-badge pa-level-${alert.level}">${dayLabel}</div>
                <a class="pa-notify-btn" href="${mailtoHref}" title="Open email draft for ${emp.name}">
                  <i class="fa-solid fa-envelope"></i> Notify
                </a>
              </div>`;
        }).join('');
    }

    let html = `<div class="passport-alerts-card">
      <div class="pa-header">
        <i class="fa-solid fa-triangle-exclamation"></i>
        Passport Expiry Alerts &nbsp;<span class="pa-total-badge">${alerts.length} employee${alerts.length !== 1 ? 's' : ''}</span>
        <span class="pa-header-hint">Clicking "Notify" opens a pre-filled email draft in your mail client.</span>
      </div>`;

    if (expired.length)  html += `<div class="pa-section-title pa-title-expired"><i class="fa-solid fa-circle-xmark"></i> Expired (${expired.length})</div>${buildRows(expired)}`;
    if (critical.length) html += `<div class="pa-section-title pa-title-critical"><i class="fa-solid fa-circle-exclamation"></i> Expiring within 30 days (${critical.length})</div>${buildRows(critical)}`;
    if (warning.length)  html += `<div class="pa-section-title pa-title-warning"><i class="fa-solid fa-clock"></i> Expiring within 90 days (${warning.length})</div>${buildRows(warning)}`;

    html += `</div>`;
    panel.innerHTML = html;
    panel.style.display = 'block';
}

// ═══════════════════════════════════════════════
// ── SECTION 2: DEPARTMENT MANAGEMENT ───────────
// ═══════════════════════════════════════════════

const deptForm      = document.getElementById('dept-form');
const deptBody      = document.getElementById('dept-body');
const deptSubmitBtn = document.getElementById('dept-submit-btn');
const deptCancelBtn = document.getElementById('dept-cancel-btn');

let departments    = JSON.parse(localStorage.getItem('prowess-departments')) || [];
let editingDeptId  = null;

// ── "View as of" date controller ────────────────

const deptViewDateInput = document.getElementById('dept-view-date');
const deptDateHint      = document.getElementById('dept-date-hint');

// Default to today
let deptViewDate = new Date().toISOString().split('T')[0];
deptViewDateInput.value = deptViewDate;
updateDeptDateHint();

deptViewDateInput.addEventListener('change', function () {
    deptViewDate = this.value || new Date().toISOString().split('T')[0];
    updateDeptDateHint();
    renderDepartments();
    renderOrgChart();
});

function updateDeptDateHint() {
    const today = new Date().toISOString().split('T')[0];
    deptDateHint.textContent = deptViewDate === today ? '(Today)' : '';
}

// ── Status helper ───────────────────────────────

function getDeptStatus(dept) {
    if (!dept.startDate || !dept.endDate) return 'Active';
    if (deptViewDate < dept.startDate) return 'Upcoming';
    if (deptViewDate > dept.endDate)   return 'Expired';
    return 'Active';
}

function isDeptActive(dept) {
    return getDeptStatus(dept) === 'Active';
}

// ── Auto-generate Department ID ─────────────────

function generateDeptId() {
    const count = departments.length + 1;
    return 'DEPT' + String(count).padStart(3, '0');
}

// ── Populate dept head + parent dept dropdowns ──

function populateDeptFormDropdowns() {

    // Dept Head — all employees
    const headSelect = document.getElementById('dept-head');
    const currentHead = headSelect.value;
    headSelect.innerHTML = '<option value="">-- Select Employee --</option>';
    employees.forEach(e => {
        const opt = document.createElement('option');
        opt.value = e.employeeId;
        opt.textContent = `${e.name} (${e.employeeId})`;
        headSelect.appendChild(opt);
    });
    headSelect.value = currentHead;

    // Parent Department — all existing departments
    const parentSelect = document.getElementById('dept-parent');
    const currentParent = parentSelect.value;
    parentSelect.innerHTML = '<option value="">-- None (Top Level) --</option>';
    departments.forEach(d => {
        if (editingDeptId && d.id === editingDeptId) return; // skip self
        const opt = document.createElement('option');
        opt.value = d.deptId;
        opt.textContent = `${d.name} (${d.deptId})`;
        parentSelect.appendChild(opt);
    });
    parentSelect.value = currentParent;

    // Auto-fill defaults for new department
    if (!editingDeptId) {
        document.getElementById('dept-id').value = generateDeptId();
        const today = new Date().toISOString().split('T')[0];   // YYYY-MM-DD
        document.getElementById('dept-start-date').value = today;
        document.getElementById('dept-end-date').value   = '9999-12-31';
    }
}

// ── Render departments table ────────────────────

function renderDepartments() {
    // ── Populate Head dropdown ──────────────────
    const headSelect   = document.getElementById('filter-dept-head');
    const parentSelect = document.getElementById('filter-dept-parent');
    if (headSelect) {
        const currentHead = headSelect.value;
        headSelect.innerHTML = '<option value="">All Heads</option>';
        const heads = employees.filter(e => departments.some(d => d.headId === e.employeeId));
        heads.sort((a, b) => a.name.localeCompare(b.name)).forEach(function (e) {
            const opt = document.createElement('option');
            opt.value = e.employeeId;
            opt.textContent = e.name;
            if (e.employeeId === currentHead) opt.selected = true;
            headSelect.appendChild(opt);
        });
    }
    if (parentSelect) {
        const currentParent = parentSelect.value;
        parentSelect.innerHTML = '<option value="">All Parents</option>';
        departments.slice().sort((a, b) => a.name.localeCompare(b.name)).forEach(function (d) {
            const opt = document.createElement('option');
            opt.value = d.deptId;
            opt.textContent = d.name;
            if (d.deptId === currentParent) opt.selected = true;
            parentSelect.appendChild(opt);
        });
    }

    // ── Read active filters ─────────────────────
    const filterName   = (document.getElementById('filter-dept-name')?.value   || '').trim().toLowerCase();
    const filterId     = (document.getElementById('filter-dept-id')?.value     || '').trim().toLowerCase();
    const filterHead   = (document.getElementById('filter-dept-head')?.value   || '');
    const filterParent = (document.getElementById('filter-dept-parent')?.value || '');
    const filterStatus = (document.getElementById('filter-dept-status')?.value || '');

    const hasFilter = filterName || filterId || filterHead || filterParent || filterStatus;
    const clearBtn  = document.getElementById('dept-filter-clear');
    if (clearBtn) clearBtn.style.display = hasFilter ? 'inline-flex' : 'none';

    // ── Apply filters ───────────────────────────
    let list = departments.filter(function (dept) {
        if (filterName   && !dept.name.toLowerCase().includes(filterName))    return false;
        if (filterId     && !dept.deptId.toLowerCase().includes(filterId))    return false;
        if (filterHead   && dept.headId !== filterHead)                       return false;
        if (filterParent && dept.parentDeptId !== filterParent)               return false;
        if (filterStatus && getDeptStatus(dept) !== filterStatus)             return false;
        return true;
    });

    // Sort: Active → Upcoming → Expired
    list = list.sort((a, b) => {
        const order = { Active: 0, Upcoming: 1, Expired: 2 };
        return order[getDeptStatus(a)] - order[getDeptStatus(b)];
    });

    // ── Update count badge ──────────────────────
    const countEl = document.getElementById('dept-filter-count');
    if (countEl) {
        countEl.textContent = hasFilter
            ? `${list.length} of ${departments.length} shown`
            : `${departments.length} department${departments.length !== 1 ? 's' : ''}`;
    }

    // Update export button label
    updateDeptExportLabel(list.length, departments.length);

    const fmtDate = val => {
        if (!val) return '—';
        if (val === '9999-12-31') return 'Open-ended';
        return new Date(val + 'T00:00:00').toLocaleDateString('en-GB', { day:'2-digit', month:'short', year:'numeric' });
    };

    const statusBadge = dept => {
        const s = getDeptStatus(dept);
        const cls = s === 'Active' ? 'badge-active' : s === 'Upcoming' ? 'badge-upcoming' : 'badge-closed';
        return `<span class="badge ${cls}">${s}</span>`;
    };

    deptBody.innerHTML = '';

    if (departments.length === 0) {
        deptBody.innerHTML = '<tr><td colspan="8" class="no-data">No departments added yet.</td></tr>';
        return;
    }

    if (list.length === 0) {
        deptBody.innerHTML = '<tr><td colspan="8" class="no-data">No departments match the current filters.</td></tr>';
        return;
    }

    list.forEach(function (dept, index) {
        const headName   = dept.headId
            ? (employees.find(e => e.employeeId === dept.headId)?.name || dept.headId)
            : '—';
        const parentName = dept.parentDeptId
            ? (departments.find(d => d.deptId === dept.parentDeptId)?.name || dept.parentDeptId)
            : '—';

        const initial     = (dept.name || '?').charAt(0).toUpperCase();
        const avatarColor = getAvatarColor(dept.name);

        const row = document.createElement('tr');
        row.innerHTML = `
            <td class="emp-td-num">${index + 1}</td>
            <td>
                <div class="emp-name-cell">
                    <div class="emp-avatar-sm" style="background:${avatarColor};">${initial}</div>
                    <div class="emp-name-info">
                        <span class="emp-name-primary">${escHtml(dept.name)}</span>
                        <span class="emp-name-id">${escHtml(dept.deptId)}</span>
                    </div>
                </div>
            </td>
            <td>${escHtml(headName)}</td>
            <td>${escHtml(parentName)}</td>
            <td>${fmtDate(dept.startDate)}</td>
            <td>${fmtDate(dept.endDate)}</td>
            <td>${statusBadge(dept)}</td>
            <td>
                <div class="emp-action-btns">
                    <button class="btn-edit" data-id="${dept.id}" title="Edit department">
                        <i class="fa-solid fa-pen-to-square" data-id="${dept.id}"></i>
                    </button>
                    <button class="btn-delete" data-id="${dept.id}" title="Delete department">
                        <i class="fa-solid fa-trash" data-id="${dept.id}"></i>
                    </button>
                </div>
            </td>
        `;
        deptBody.appendChild(row);
    });
}

// ── Handle add / update department ─────────────

deptForm.addEventListener('submit', function (event) {
    event.preventDefault();

    const name        = document.getElementById('dept-name').value.trim();
    const deptId      = document.getElementById('dept-id').value.trim();
    const headId      = document.getElementById('dept-head').value;
    const parentDeptId = document.getElementById('dept-parent').value;
    const startDate   = document.getElementById('dept-start-date').value;
    const endDate     = document.getElementById('dept-end-date').value;

    // ── Validation: dept cannot be its own parent ──
    if (editingDeptId !== null && parentDeptId) {
        const editingDept = departments.find(d => d.id === editingDeptId);
        if (editingDept && editingDept.deptId === parentDeptId) {
            alert('A department cannot be its own parent.');
            return;
        }
    }

    if (editingDeptId !== null) {
        // ── EDIT MODE ──
        const oldDept = departments.find(d => d.id === editingDeptId);

        // If dept head changed, update old head's role back to Employee
        if (oldDept.headId && oldDept.headId !== headId) {
            updateDeptHeadRole(oldDept.headId, false);
        }

        departments = departments.map(function (d) {
            if (d.id === editingDeptId) {
                return { ...d, name, headId, parentDeptId, startDate, endDate };
            }
            return d;
        });

        resetDeptForm();

    } else {
        // ── ADD MODE ──
        const duplicate = departments.find(d => d.name.toLowerCase() === name.toLowerCase());
        if (duplicate) {
            alert('A department with this name already exists.');
            return;
        }

        departments.push({ id: Date.now(), deptId, name, headId, parentDeptId, startDate, endDate });
        deptForm.reset();
    }

    // Update dept head's role to 'Dept Head' and sync their department
    if (headId) updateDeptHeadRole(headId, true, deptId);

    localStorage.setItem('prowess-departments', JSON.stringify(departments));
    localStorage.setItem('prowess-employees', JSON.stringify(employees));
    renderDepartments();
    renderEmployees();
    renderOrgChart();
    populateDeptFormDropdowns();
});

// ── Update employee role when assigned as dept head

function updateDeptHeadRole(employeeId, isDeptHead, deptId) {
    employees = employees.map(function (emp) {
        if (emp.employeeId === employeeId) {
            if (isDeptHead) {
                // Promote to Dept Head and move them into that department
                return { ...emp, role: 'Dept Head', departmentId: deptId };
            }
            // Removing as dept head — fall back to Manager if still has reports, else Employee
            const stillManages = employees.some(e => e.managerId === employeeId);
            return { ...emp, role: stillManages ? 'Manager' : 'Employee' };
        }
        return emp;
    });
}

// ── Handle edit / delete clicks ─────────────────

deptBody.addEventListener('click', function (event) {

    const editBtn = event.target.closest('.btn-edit');
    if (editBtn) {
        const id   = Number(editBtn.getAttribute('data-id'));
        const dept = departments.find(d => d.id === id);

        editingDeptId = id;   // set BEFORE populateDeptFormDropdowns so defaults are skipped

        document.getElementById('dept-name').value       = dept.name;
        document.getElementById('dept-id').value         = dept.deptId;
        document.getElementById('dept-start-date').value = dept.startDate || '';
        document.getElementById('dept-end-date').value   = dept.endDate   || '';

        populateDeptFormDropdowns();
        document.getElementById('dept-head').value   = dept.headId || '';
        document.getElementById('dept-parent').value = dept.parentDeptId || '';
        deptSubmitBtn.innerHTML = '<i class="fa-solid fa-floppy-disk"></i> Update Department';
        deptCancelBtn.style.display = 'inline-block';
        deptForm.scrollIntoView({ behavior: 'smooth' });
        return;
    }

    const deleteBtn = event.target.closest('.btn-delete');
    if (deleteBtn) {
        if (!confirm('Delete this department?')) return;
        const id   = Number(deleteBtn.getAttribute('data-id'));
        const dept = departments.find(d => d.id === id);

        // Reset dept head role back to Employee
        if (dept.headId) updateDeptHeadRole(dept.headId, false);

        departments = departments.filter(d => d.id !== id);
        localStorage.setItem('prowess-departments', JSON.stringify(departments));
        localStorage.setItem('prowess-employees', JSON.stringify(employees));
        renderDepartments();
        renderEmployees();
        renderOrgChart();
        populateDeptFormDropdowns();
    }
});

deptCancelBtn.addEventListener('click', resetDeptForm);

// ── Auto-fill head from parent department ────────
// Only fires when head is not already explicitly set

document.getElementById('dept-parent').addEventListener('change', function () {
    const headSelect = document.getElementById('dept-head');
    const headHint   = document.getElementById('dept-head-hint');
    const parentDeptId = this.value;

    // No parent selected — nothing to inherit, hide any hint
    if (!parentDeptId) {
        headHint.style.display = 'none';
        return;
    }

    if (headSelect.value) {
        // Head already set — only nudge the admin in edit (update) mode
        if (editingDeptId !== null) {
            headHint.style.display = 'flex';
            // Auto-hide after 5 seconds
            clearTimeout(headHint._timer);
            headHint._timer = setTimeout(() => { headHint.style.display = 'none'; }, 5000);
        }
        return;
    }

    // No head set yet — inherit from parent department
    const parentDept = departments.find(d => d.deptId === parentDeptId);
    if (parentDept && parentDept.headId) {
        headSelect.value = parentDept.headId;
    }
    headHint.style.display = 'none';
});

function resetDeptForm() {
    deptForm.reset();
    editingDeptId = null;
    deptSubmitBtn.innerHTML = '<i class="fa-solid fa-plus"></i> Add Department';
    deptCancelBtn.style.display = 'none';
    document.getElementById('dept-head-hint').style.display = 'none';
    populateDeptFormDropdowns();
}

// ── ORG CHART ───────────────────────────────────

function renderOrgChart() {
    // docRenderOrgChart() is defined later in the file using let/const which
    // are in TDZ if this is called during page-load initialisation (before
    // those declarations are reached).  The try-catch lets the early call
    // fail silently; the chart renders correctly when the tab is opened.
    try { docRenderOrgChart(); } catch (e) { /* doc module not yet ready */ }
}

function formatViewDate() {
    return new Date(deptViewDate + 'T00:00:00').toLocaleDateString('en-GB', { day:'2-digit', month:'short', year:'numeric' });
}

// ═══════════════════════════════════════════════
// ── SECTION 3: PROJECT MANAGEMENT ──────────────
// ═══════════════════════════════════════════════

const projectForm   = document.getElementById('project-form');
const projectBody   = document.getElementById('project-body');
const projSubmitBtn = document.getElementById('proj-submit-btn');
const projCancelBtn = document.getElementById('proj-cancel-btn');

let projects         = JSON.parse(localStorage.getItem('prowess-projects')) || [];
let editingProjectId = null;

projectForm.addEventListener('submit', function (event) {
    event.preventDefault();

    const name      = document.getElementById('project-name').value.trim().toUpperCase();
    const startDate = document.getElementById('start-date').value;
    const endDate   = document.getElementById('end-date').value;

    if (endDate < startDate) { alert('End date cannot be before start date.'); return; }

    if (editingProjectId !== null) {
        projects = projects.map(p => p.id === editingProjectId ? { ...p, name, startDate, endDate } : p);
        resetProjectForm();
    } else {
        if (projects.find(p => p.name === name)) { alert('Project already exists.'); return; }
        projects.push({ id: Date.now(), name, startDate, endDate });
        projectForm.reset();
    }

    localStorage.setItem('prowess-projects', JSON.stringify(projects));
    renderProjects();
});

function renderProjects() {
    projectBody.innerHTML = '';

    if (projects.length === 0) {
        projectBody.innerHTML = '<tr><td colspan="6" class="no-data">No projects added yet.</td></tr>';
        return;
    }

    const today = new Date().toISOString().split('T')[0];

    projects.forEach(function (project, index) {
        const status = today < project.startDate
            ? '<span class="badge badge-upcoming">Upcoming</span>'
            : today > project.endDate
                ? '<span class="badge badge-closed">Closed</span>'
                : '<span class="badge badge-active">Active</span>';

        const row = document.createElement('tr');
        row.innerHTML = `
            <td>${index + 1}</td>
            <td><strong>${project.name}</strong></td>
            <td>${project.startDate}</td>
            <td>${project.endDate}</td>
            <td>${status}</td>
            <td>
                <button class="btn-edit" data-id="${project.id}">
                    <i class="fa-solid fa-pen-to-square" data-id="${project.id}"></i>
                </button>
                <button class="btn-delete" data-id="${project.id}">
                    <i class="fa-solid fa-trash" data-id="${project.id}"></i>
                </button>
            </td>
        `;
        projectBody.appendChild(row);
    });
}

projectBody.addEventListener('click', function (event) {
    const editBtn = event.target.closest('.btn-edit');
    if (editBtn) {
        const id = Number(editBtn.getAttribute('data-id'));
        const p  = projects.find(p => p.id === id);
        document.getElementById('project-name').value = p.name;
        document.getElementById('start-date').value   = p.startDate;
        document.getElementById('end-date').value     = p.endDate;
        editingProjectId = id;
        projSubmitBtn.innerHTML = '<i class="fa-solid fa-floppy-disk"></i> Update Project';
        projCancelBtn.style.display = 'inline-block';
        projectForm.scrollIntoView({ behavior: 'smooth' });
        return;
    }

    const deleteBtn = event.target.closest('.btn-delete');
    if (deleteBtn) {
        if (!confirm('Delete this project?')) return;
        const id = Number(deleteBtn.getAttribute('data-id'));
        projects = projects.filter(p => p.id !== id);
        localStorage.setItem('prowess-projects', JSON.stringify(projects));
        renderProjects();
    }
});

projCancelBtn.addEventListener('click', resetProjectForm);

function resetProjectForm() {
    projectForm.reset();
    editingProjectId = null;
    projSubmitBtn.innerHTML = '+ Add Project';
    projCancelBtn.style.display = 'none';
}

// ═══════════════════════════════════════════════
// ── SECTION 4: WORKFLOW ROLES ───────────────────
// ═══════════════════════════════════════════════

const wfRoleForm       = document.getElementById('wf-role-form');
const wfRolesContainer = document.getElementById('wf-roles-container');
const wfSubmitBtn      = document.getElementById('wf-submit-btn');
const wfCancelBtn      = document.getElementById('wf-cancel-btn');

let workflowRoles   = JSON.parse(localStorage.getItem('prowess-workflow-roles')) || [];
let editingWfRoleId = null;

// Professional color palette — cycles for each new role
const WF_COLORS = [
    { bg: '#e3f2fd', border: '#1976D2', header: '#1565C0' },   // Blue
    { bg: '#f3e5f5', border: '#8E24AA', header: '#6A1B9A' },   // Purple
    { bg: '#e8f5e9', border: '#388E3C', header: '#2E7D32' },   // Green
    { bg: '#fff3e0', border: '#F57C00', header: '#E65100' },   // Orange
    { bg: '#fce4ec', border: '#D81B60', header: '#880E4F' },   // Pink
    { bg: '#e0f2f1', border: '#00796B', header: '#004D40' },   // Teal
    { bg: '#ede7f6', border: '#5E35B1', header: '#4527A0' },   // Deep Purple
    { bg: '#fff8e1', border: '#F9A825', header: '#E65100' },   // Amber
];

function getWfColor(colorIndex) {
    return WF_COLORS[colorIndex % WF_COLORS.length];
}

// ── Populate employee chip-selector ─────────────

function populateWfEmpGrid() {
    const grid = document.getElementById('wf-emp-grid');
    if (!grid) return;

    if (employees.length === 0) {
        grid.innerHTML = '<p class="no-data" style="padding:12px 0;">Add employees first to assign them here.</p>';
        document.getElementById('wf-count-hint').textContent = '0 selected (min 1, max 5)';
        return;
    }

    // Preserve any already-checked IDs (edit mode pre-selection)
    const preSelected = Array.from(grid.querySelectorAll('input[type="checkbox"]:checked'))
        .map(cb => cb.value);

    grid.innerHTML = employees.map(emp => {
        const checked = preSelected.includes(emp.employeeId);
        return `
            <label class="emp-chip${checked ? ' checked' : ''}" data-emp-id="${emp.employeeId}">
                <input type="checkbox" value="${emp.employeeId}"${checked ? ' checked' : ''} />
                <i class="fa-solid fa-user"></i>
                ${emp.name} <span style="opacity:.6;font-size:11px;">(${emp.employeeId})</span>
            </label>`;
    }).join('');

    grid.querySelectorAll('input[type="checkbox"]').forEach(cb => {
        cb.addEventListener('change', function () {
            this.closest('.emp-chip').classList.toggle('checked', this.checked);
            enforceWfMax();
            updateWfCountHint();
        });
    });

    enforceWfMax();
    updateWfCountHint();
}

function enforceWfMax() {
    const grid = document.getElementById('wf-emp-grid');
    if (!grid) return;
    const boxes   = grid.querySelectorAll('input[type="checkbox"]');
    const count   = Array.from(boxes).filter(cb => cb.checked).length;
    boxes.forEach(cb => {
        const chip = cb.closest('.emp-chip');
        const lock = !cb.checked && count >= 5;
        chip.classList.toggle('disabled', lock);
        cb.disabled = lock;
    });
}

function updateWfCountHint() {
    const hint = document.getElementById('wf-count-hint');
    const grid = document.getElementById('wf-emp-grid');
    if (!hint || !grid) return;
    const n = grid.querySelectorAll('input[type="checkbox"]:checked').length;
    hint.textContent = `${n} selected (min 1, max 5)`;
    hint.classList.toggle('maxed', n >= 5);
}

// ── Render role cards ────────────────────────────

function renderWfRoles() {
    if (!wfRolesContainer) return;

    if (workflowRoles.length === 0) {
        wfRolesContainer.innerHTML = `
            <div class="wf-empty">
                <i class="fa-solid fa-shield-halved"></i>
                <p>No workflow roles yet. Create one above.</p>
            </div>`;
        return;
    }

    wfRolesContainer.innerHTML = workflowRoles.map(function (role) {
        const color   = getWfColor(role.colorIndex ?? 0);
        const members = role.employeeIds.map(id => {
            const emp = employees.find(e => e.employeeId === id);
            const label = emp ? emp.name : `${id} <em>(removed)</em>`;
            return `<span class="wf-member-chip" style="background:${color.border}18;color:${color.header};border:1px solid ${color.border}40;">
                        <i class="fa-solid fa-user" style="font-size:10px;"></i> ${label}
                    </span>`;
        }).join('');

        return `
            <div class="wf-role-card" style="border-color:${color.border};background:${color.bg};">
                <div class="wf-role-header" style="background:${color.header};">
                    <div class="wf-role-header-left">
                        <i class="fa-solid fa-shield-halved"></i>
                        <span class="wf-role-title">${role.roleName}</span>
                        <span class="wf-role-count">${role.employeeIds.length} member${role.employeeIds.length !== 1 ? 's' : ''}</span>
                    </div>
                    <div class="wf-role-actions">
                        <button class="wf-btn-edit"   data-id="${role.id}" title="Edit role">
                            <i class="fa-solid fa-pen-to-square" data-id="${role.id}"></i>
                        </button>
                        <button class="wf-btn-delete" data-id="${role.id}" title="Delete role">
                            <i class="fa-solid fa-trash" data-id="${role.id}"></i>
                        </button>
                    </div>
                </div>
                <div class="wf-role-body">
                    <div class="wf-member-list">${members}</div>
                    <p class="wf-role-footer">
                        <i class="fa-solid fa-circle-check"></i>
                        Role key: <code>${role.roleKey}</code> &mdash; ready for workflow assignment
                    </p>
                </div>
            </div>`;
    }).join('');
}

// ── Form submit (create / update) ───────────────

wfRoleForm.addEventListener('submit', function (e) {
    e.preventDefault();

    const roleName  = document.getElementById('wf-role-name').value.trim();
    const grid      = document.getElementById('wf-emp-grid');
    const selected  = Array.from(grid.querySelectorAll('input[type="checkbox"]:checked'))
                          .map(cb => cb.value);

    if (selected.length < 1) { alert('Assign at least 1 employee to this role.'); return; }
    if (selected.length > 5) { alert('A workflow role can have at most 5 employees.'); return; }

    if (editingWfRoleId !== null) {
        // ── EDIT ──
        workflowRoles = workflowRoles.map(r =>
            r.id === editingWfRoleId
                ? { ...r, roleName, roleKey: toRoleKey(roleName), employeeIds: selected }
                : r
        );
        resetWfForm();

    } else {
        // ── ADD ──
        if (workflowRoles.find(r => r.roleName.toLowerCase() === roleName.toLowerCase())) {
            alert('A workflow role with this name already exists.');
            return;
        }
        workflowRoles.push({
            id:          Date.now(),
            roleName,
            roleKey:     toRoleKey(roleName),
            employeeIds: selected,
            colorIndex:  workflowRoles.length,   // cycles through palette
            createdAt:   new Date().toISOString()
        });
        wfRoleForm.reset();
        populateWfEmpGrid();
    }

    localStorage.setItem('prowess-workflow-roles', JSON.stringify(workflowRoles));
    renderWfRoles();
});

// Normalise role name → URL-safe key (e.g. "L1 Approver" → "l1_approver")
function toRoleKey(name) {
    return name.trim().toLowerCase().replace(/\s+/g, '_').replace(/[^a-z0-9_]/g, '');
}

// ── Edit / Delete ────────────────────────────────

wfRolesContainer.addEventListener('click', function (e) {

    const editBtn = e.target.closest('.wf-btn-edit');
    if (editBtn) {
        const id   = Number(editBtn.getAttribute('data-id'));
        const role = workflowRoles.find(r => r.id === id);

        editingWfRoleId = id;
        document.getElementById('wf-role-name').value = role.roleName;

        // Rebuild grid with role's employees pre-checked
        const grid = document.getElementById('wf-emp-grid');
        // Clear checked state first so populateWfEmpGrid starts clean
        grid.querySelectorAll('input[type="checkbox"]').forEach(cb => { cb.checked = false; });
        populateWfEmpGrid();
        grid.querySelectorAll('input[type="checkbox"]').forEach(cb => {
            if (role.employeeIds.includes(cb.value)) {
                cb.checked = true;
                cb.closest('.emp-chip').classList.add('checked');
            }
        });
        enforceWfMax();
        updateWfCountHint();

        wfSubmitBtn.innerHTML = '<i class="fa-solid fa-floppy-disk"></i> Update Role';
        wfCancelBtn.style.display = 'inline-block';
        wfRoleForm.scrollIntoView({ behavior: 'smooth' });
        return;
    }

    const deleteBtn = e.target.closest('.wf-btn-delete');
    if (deleteBtn) {
        if (!confirm('Delete this workflow role?')) return;
        const id = Number(deleteBtn.getAttribute('data-id'));
        workflowRoles = workflowRoles.filter(r => r.id !== id);
        localStorage.setItem('prowess-workflow-roles', JSON.stringify(workflowRoles));
        renderWfRoles();
    }
});

wfCancelBtn.addEventListener('click', resetWfForm);

function resetWfForm() {
    wfRoleForm.reset();
    editingWfRoleId = null;
    wfSubmitBtn.innerHTML = '<i class="fa-solid fa-plus"></i> Create Role';
    wfCancelBtn.style.display = 'none';
    populateWfEmpGrid();
}

// ═══════════════════════════════════════════════
// ── SECTION 5: REFERENCE DATA ───────────────────
// ═══════════════════════════════════════════════

const DEFAULT_DESIGNATIONS = [
    'Analyst','Associate','Business Analyst','Chief Executive Officer',
    'Chief Financial Officer','Chief Operating Officer','Chief Technology Officer',
    'Consultant','Data Engineer','Data Scientist','DevOps Engineer',
    'Director','Engineering Manager','Executive Assistant','Finance Manager',
    'Frontend Developer','Full Stack Developer','HR Business Partner',
    'HR Manager','Infrastructure Engineer','IT Manager','Junior Developer',
    'Lead Developer','Marketing Manager','Mobile Developer','Operations Manager',
    'Principal Engineer','Product Manager','Product Owner','Program Manager',
    'Project Manager','QA Engineer','Sales Manager','Scrum Master',
    'Senior Analyst','Senior Consultant','Senior Developer','Senior Engineer',
    'Senior Manager','Software Architect','Software Engineer','Solution Architect',
    'Support Engineer','Systems Administrator','Technical Lead','Test Engineer',
    'UI/UX Designer','Vice President'
];

const DEFAULT_NATIONALITIES = [
    'Afghan','Albanian','Algerian','American','Angolan','Argentine','Armenian',
    'Australian','Austrian','Azerbaijani','Bahraini','Bangladeshi','Belgian',
    'Bolivian','Brazilian','British','Bulgarian','Cambodian','Cameroonian',
    'Canadian','Chilean','Chinese','Colombian','Congolese','Costa Rican',
    'Croatian','Cuban','Czech','Danish','Dutch','Ecuadorian','Egyptian',
    'Emirati','Estonian','Ethiopian','Finnish','French','Georgian','German',
    'Ghanaian','Greek','Guatemalan','Hungarian','Icelandic','Indian',
    'Indonesian','Iranian','Iraqi','Irish','Israeli','Italian','Ivorian',
    'Jamaican','Japanese','Jordanian','Kazakhstani','Kenyan','Korean',
    'Kuwaiti','Latvian','Lebanese','Libyan','Lithuanian','Malaysian',
    'Maldivian','Maltese','Mauritian','Mexican','Mongolian','Moroccan',
    'Mozambican','Namibian','Nepalese','New Zealander','Nigerian','Norwegian',
    'Omani','Pakistani','Palestinian','Panamanian','Peruvian','Philippine',
    'Polish','Portuguese','Qatari','Romanian','Russian','Rwandan','Saudi',
    'Senegalese','Serbian','Singaporean','Slovak','Slovenian','Somali',
    'South African','Spanish','Sri Lankan','Sudanese','Swedish','Swiss',
    'Syrian','Taiwanese','Tanzanian','Thai','Trinidadian','Tunisian',
    'Turkish','Ugandan','Ukrainian','Uruguayan','Venezuelan','Vietnamese',
    'Yemeni','Zambian','Zimbabwean'
];

const DEFAULT_MARITAL_STATUSES = [
    'Single','Married','Divorced','Widowed','Separated'
];

const DEFAULT_RELATIONSHIP_TYPES = [
    'Father','Mother','Spouse','Brother','Sister',
    'Son','Daughter','Guardian','Friend','Colleague','Other'
];

// ── Currency flag emoji map (must be declared before init sequence uses it) ──
var CURRENCY_FLAGS = {
    AED:'🇦🇪', AFN:'🇦🇫', AUD:'🇦🇺', BDT:'🇧🇩', BHD:'🇧🇭',
    BRL:'🇧🇷', CAD:'🇨🇦', CHF:'🇨🇭', CNY:'🇨🇳', CZK:'🇨🇿',
    DKK:'🇩🇰', EGP:'🇪🇬', EUR:'🇪🇺', GBP:'🇬🇧', GHS:'🇬🇭',
    HKD:'🇭🇰', IDR:'🇮🇩', ILS:'🇮🇱', INR:'🇮🇳', IQD:'🇮🇶',
    JOD:'🇯🇴', JPY:'🇯🇵', KES:'🇰🇪', KHR:'🇰🇭', KRW:'🇰🇷',
    KWD:'🇰🇼', LBP:'🇱🇧', LKR:'🇱🇰', MMK:'🇲🇲', MXN:'🇲🇽',
    MYR:'🇲🇾', NGN:'🇳🇬', NOK:'🇳🇴', NPR:'🇳🇵', NZD:'🇳🇿',
    OMR:'🇴🇲', PHP:'🇵🇭', PKR:'🇵🇰', PLN:'🇵🇱', QAR:'🇶🇦',
    RUB:'🇷🇺', SAR:'🇸🇦', SEK:'🇸🇪', SGD:'🇸🇬', THB:'🇹🇭',
    TRY:'🇹🇷', TWD:'🇹🇼', USD:'🇺🇸', VND:'🇻🇳', ZAR:'🇿🇦'
};

function erFlag(code) {
    return CURRENCY_FLAGS[code] ? CURRENCY_FLAGS[code] + '\u00A0' : '';
}

// ── DEFAULT CURRENCIES ────────────────────────────
const DEFAULT_CURRENCIES = [
    { code:'INR', name:'Indian Rupee',          symbol:'₹'  },
    { code:'USD', name:'US Dollar',              symbol:'$'  },
    { code:'EUR', name:'Euro',                   symbol:'€'  },
    { code:'GBP', name:'British Pound',          symbol:'£'  },
    { code:'SAR', name:'Saudi Riyal',            symbol:'﷼'  },
    { code:'AED', name:'UAE Dirham',             symbol:'د.إ'},
    { code:'SGD', name:'Singapore Dollar',       symbol:'S$' },
    { code:'AUD', name:'Australian Dollar',      symbol:'A$' },
    { code:'CAD', name:'Canadian Dollar',        symbol:'C$' },
    { code:'JPY', name:'Japanese Yen',           symbol:'¥'  },
    { code:'CNY', name:'Chinese Yuan',           symbol:'¥'  },
    { code:'MYR', name:'Malaysian Ringgit',      symbol:'RM' },
    { code:'QAR', name:'Qatari Riyal',           symbol:'﷼'  },
    { code:'KWD', name:'Kuwaiti Dinar',          symbol:'KD' },
    { code:'BHD', name:'Bahraini Dinar',         symbol:'BD' },
];

// Country code → Currency code suggestion map
const COUNTRY_CURRENCY_MAP = {
    'IN':'INR','US':'USD','GB':'GBP','DE':'EUR','FR':'EUR','IT':'EUR',
    'ES':'EUR','NL':'EUR','BE':'EUR','PT':'EUR','AT':'EUR','FI':'EUR',
    'SA':'SAR','AE':'AED','QA':'QAR','KW':'KWD','BH':'BHD','OM':'OMR',
    'SG':'SGD','AU':'AUD','CA':'CAD','JP':'JPY','CN':'CNY','MY':'MYR',
    'NZ':'NZD','CH':'CHF','SE':'SEK','NO':'NOK','DK':'DKK',
    'PK':'PKR','BD':'BDT','LK':'LKR','NP':'NPR','PH':'PHP',
    'TH':'THB','ID':'IDR','VN':'VND','KR':'KRW','TW':'TWD',
    'ZA':'ZAR','NG':'NGN','KE':'KES','GH':'GHS','EG':'EGP',
    'BR':'BRL','MX':'MXN','AR':'ARS','CO':'COP','PE':'PEN',
    'RU':'RUB','TR':'TRY','PL':'PLN','CZ':'CZK','HU':'HUF',
    'RO':'RON','UA':'UAH','IL':'ILS','JO':'JOD',
};

// ── REFERENCE ID HELPERS ──────────────────────────────────────────────────
//
// Each simple reference entity (Designations, Nationalities, Marital Statuses,
// Relationship Types) carries a 4-char alphanumeric refId:  prefix + 3-digit
// zero-padded number, e.g.  D001, N014, M003, R007.
//
// Employee records store the refId as the foreign key.  Display code always
// calls resolveRefLabel() to convert a refId back to its current label —
// so renaming a value automatically propagates everywhere without touching
// any employee record.

/**
 * Generate the next unique refId for a reference entity.
 * @param {string}   prefix  - Single uppercase letter (D / N / M / R)
 * @param {object[]} items   - Current items array (reads existing refIds to avoid collisions)
 * @returns {string}         - e.g. 'D001', 'D042'
 */
function generateRefId(prefix, items) {
    const nums = items
        .map(i => i.refId || '')
        .filter(rid => rid.length === 4 && rid.startsWith(prefix))
        .map(rid => parseInt(rid.slice(1), 10))
        .filter(n => !isNaN(n));
    const next = nums.length ? Math.max(...nums) + 1 : 1;
    return prefix + String(next).padStart(3, '0');
}

/**
 * Resolve a stored refId to its human-readable label.
 * Falls back to the refId itself if the item is not found (graceful degradation).
 * @param {string} refId      - e.g. 'D001'
 * @param {string} storageKey - localStorage key, e.g. 'prowess-designations'
 * @returns {string}
 */
function resolveRefLabel(refId, storageKey) {
    if (!refId) return '—';
    // Use new generic storage if picklist exists there
    var picklistId = PICKLIST_KEY_MAP ? PICKLIST_KEY_MAP[storageKey] : null;
    if (picklistId && plVals().length) {
        return plResolve(refId, picklistId);
    }
    // Fallback to old storage (pre-migration)
    var items = JSON.parse(localStorage.getItem(storageKey) || '[]');
    var item  = items.find(function(i){ return i.refId === refId || String(i.id) === String(refId); });
    return item ? (item.value || item.name || refId) : refId;
}

/**
 * Backfill refIds onto existing reference data items that pre-date this feature.
 * Safe to call repeatedly — only assigns IDs where refId is missing.
 */
function backfillRefIds(key, prefix) {
    const items = JSON.parse(localStorage.getItem(key) || '[]');
    if (!items.length) return;
    const existingNums = items
        .map(i => i.refId || '')
        .filter(rid => rid.startsWith(prefix) && rid.length === 4)
        .map(rid => parseInt(rid.slice(1), 10))
        .filter(n => !isNaN(n));
    let counter = existingNums.length ? Math.max(...existingNums) : 0;
    let changed  = false;
    const updated = items.map(function (item) {
        if (!item.refId) {
            changed = true;
            counter++;
            return { ...item, refId: prefix + String(counter).padStart(3, '0') };
        }
        return item;
    });
    if (changed) localStorage.setItem(key, JSON.stringify(updated));
}

// ═══════════════════════════════════════════════════════════════════════════
// ── GENERIC PICKLIST ENGINE ─────────────────────────────────────────────
// Storage: prowess-picklists  + prowess-picklist-values
//
// Picklist:  {id, description, parentPicklistId, system, metaFields:[]}
// Value:     {id, picklistId, value, parentValueId, active, refId, meta}
// ═══════════════════════════════════════════════════════════════════════════

// ── Storage helpers ──────────────────────────────────────────────────────
function plGet()         { return JSON.parse(localStorage.getItem('prowess-picklists')        || '[]'); }
function plSave(d)       { localStorage.setItem('prowess-picklists', JSON.stringify(d)); }
function plVals()        { return JSON.parse(localStorage.getItem('prowess-picklist-values')  || '[]'); }
function plSaveVals(d)   { localStorage.setItem('prowess-picklist-values', JSON.stringify(d)); }

// ── Query values ──────────────────────────────────────────────────────────
function plQuery(picklistId, opts) {
    var activeOnly    = opts && opts.activeOnly;
    var parentValueId = opts && opts.parentValueId !== undefined ? opts.parentValueId : undefined;
    var v = plVals().filter(function(i){ return i.picklistId === picklistId; });
    if (activeOnly) v = v.filter(function(i){ return i.active !== false; });
    if (parentValueId !== undefined && parentValueId !== '' && parentValueId !== null) {
        v = v.filter(function(i){ return String(i.parentValueId) === String(parentValueId); });
    }
    return v.sort(function(a,b){ return (a.value||'').localeCompare(b.value||''); });
}

// ── Resolve a stored key → display label ─────────────────────────────────
// Key may be refId ('D001'), numeric id, or meta.code ('INR')
function plResolve(key, picklistId) {
    if (!key) return '—';
    var v = plVals().find(function(i){
        return i.picklistId === picklistId && (
            i.refId === key ||
            String(i.id) === String(key) ||
            (i.meta && i.meta.code === key)
        );
    });
    return v ? v.value : String(key);
}

// ── Get value object by key ───────────────────────────────────────────────
function plGetVal(key, picklistId) {
    if (!key) return null;
    return plVals().find(function(i){
        return i.picklistId === picklistId && (
            i.refId === key ||
            String(i.id) === String(key) ||
            (i.meta && i.meta.code === key)
        );
    }) || null;
}

// ── Next safe numeric ID (above all existing IDs) ────────────────────────
function plNextId() {
    var max = plVals().reduce(function(m,v){ return Math.max(m, Number(v.id)||0); }, 99999);
    return max + 1;
}

// ── Check if a value is in use anywhere ──────────────────────────────────
function plIsInUse(valueId) {
    var vid   = String(valueId);
    var val   = plVals().find(function(v){ return String(v.id) === vid; });
    var refId = val ? (val.refId || null) : null;
    var code  = (val && val.meta) ? (val.meta.code || null) : null;

    // Children reference this as their parentValueId
    var children = plVals().filter(function(v){ return String(v.parentValueId) === vid; });
    if (children.length) return true;

    // Employee records
    var emps = JSON.parse(localStorage.getItem('prowess-employees') || '[]');
    for (var ei = 0; ei < emps.length; ei++) {
        var emp = emps[ei];
        // refId-keyed fields
        var refFields = [emp.designation, emp.nationality, emp.maritalStatus];
        for (var fi = 0; fi < refFields.length; fi++) {
            if (refFields[fi] === vid || (refId && refFields[fi] === refId)) return true;
        }
        // id-keyed fields
        if (String(emp.workCountryId) === vid || String(emp.workLocationId) === vid) return true;
        // emergency contacts
        var ecs = emp.emergencyContacts || [];
        for (var ci = 0; ci < ecs.length; ci++) {
            var ec = ecs[ci];
            if (ec.ecRelationship === vid || (refId && ec.ecRelationship === refId)) return true;
        }
        // identity documents
        var docs = emp.idDocuments || emp.identityDocs || [];
        for (var di = 0; di < docs.length; di++) {
            var doc = docs[di];
            if (String(doc.countryId) === vid || String(doc.idType) === vid) return true;
        }
    }

    // Expense reports (currency code)
    if (code) {
        var reports = JSON.parse(localStorage.getItem('prowess-expense-reports') || '[]');
        for (var ri = 0; ri < reports.length; ri++) {
            if (reports[ri].baseCurrencyCode === code) return true;
            var lines = reports[ri].lineItems || [];
            for (var li = 0; li < lines.length; li++) {
                if (lines[li].currencyCode === code) return true;
            }
        }
    }
    return false;
}

// ── picklist → old-storage-key mapping (for resolveRefLabel compat) ──────
var PICKLIST_KEY_MAP = {
    'prowess-designations':        'DESIGNATION',
    'prowess-nationalities':       'NATIONALITY',
    'prowess-marital-statuses':    'MARITAL_STATUS',
    'prowess-relationship-types':  'RELATIONSHIP_TYPE',
    'prowess-id-countries':        'ID_COUNTRY',
    'prowess-id-types':            'ID_TYPE',
    'prowess-locations':           'LOCATION',
    'prowess-currencies':          'CURRENCY',
};

// ── DEFAULT PICKLIST DEFINITIONS ─────────────────────────────────────────
var DEFAULT_PICKLISTS = [
    { id:'DESIGNATION',       description:'Designation',       parentPicklistId:null,         system:true,
      metaFields:[] },
    { id:'NATIONALITY',       description:'Nationality',       parentPicklistId:null,         system:true,
      metaFields:[] },
    { id:'MARITAL_STATUS',    description:'Marital Status',    parentPicklistId:null,         system:true,
      metaFields:[] },
    { id:'RELATIONSHIP_TYPE', description:'Relationship Type', parentPicklistId:null,         system:true,
      metaFields:[] },
    { id:'ID_COUNTRY',        description:'ID Country',        parentPicklistId:null,         system:true,
      metaFields:[{key:'code', label:'ISO Code', placeholder:'e.g. IN', width:'90'}] },
    { id:'ID_TYPE',           description:'ID Type',           parentPicklistId:'ID_COUNTRY', system:true,
      metaFields:[] },
    { id:'LOCATION',          description:'Location',          parentPicklistId:'ID_COUNTRY', system:true,
      metaFields:[] },
    { id:'CURRENCY',          description:'Currency',          parentPicklistId:null,         system:true,
      metaFields:[
          {key:'code',   label:'Code',   placeholder:'e.g. INR', width:'80', required:true},
          {key:'symbol', label:'Symbol', placeholder:'e.g. ₹',   width:'70', required:true}
      ]
    },
    { id:'Expense_Category',  description:'Expense Category',  parentPicklistId:null,         system:true,
      metaFields:[] },
];

// ── Migrate old individual storage keys → prowess-picklist-values ────────
function migrateToGenericPicklists() {
    if (localStorage.getItem('prowess-plv-migrated')) return;

    var values  = [];
    var nextId  = 200000;
    var changed = false;

    function addVals(storageKey, picklistId, transform) {
        var raw = localStorage.getItem(storageKey);
        if (!raw) return;
        var items = JSON.parse(raw) || [];
        items.forEach(function(item){ values.push(transform(item)); });
        changed = true;
    }

    addVals('prowess-designations', 'DESIGNATION', function(d) {
        return { id: nextId++, picklistId:'DESIGNATION', value:d.value,
                 parentValueId:null, active:d.active!==false, refId:d.refId||null, meta:null };
    });
    addVals('prowess-nationalities', 'NATIONALITY', function(d) {
        return { id: nextId++, picklistId:'NATIONALITY', value:d.value,
                 parentValueId:null, active:d.active!==false, refId:d.refId||null, meta:null };
    });
    addVals('prowess-marital-statuses', 'MARITAL_STATUS', function(d) {
        return { id: nextId++, picklistId:'MARITAL_STATUS', value:d.value,
                 parentValueId:null, active:d.active!==false, refId:d.refId||null, meta:null };
    });
    addVals('prowess-relationship-types', 'RELATIONSHIP_TYPE', function(d) {
        return { id: nextId++, picklistId:'RELATIONSHIP_TYPE', value:d.value,
                 parentValueId:null, active:d.active!==false, refId:d.refId||null, meta:null };
    });
    // ID_COUNTRY — preserve original numeric IDs for foreign-key compat
    addVals('prowess-id-countries', 'ID_COUNTRY', function(c) {
        return { id:c.id, picklistId:'ID_COUNTRY', value:c.name,
                 parentValueId:null, active:c.active!==false, refId:null,
                 meta:{ code: c.code||'', flag: c.flag||'' } };
    });
    // ID_TYPE — parentValueId = countryId
    addVals('prowess-id-types', 'ID_TYPE', function(t) {
        return { id:t.id, picklistId:'ID_TYPE', value:t.name,
                 parentValueId:t.countryId, active:t.active!==false, refId:null, meta:null };
    });
    // LOCATION — parentValueId = countryId
    addVals('prowess-locations', 'LOCATION', function(l) {
        return { id:l.id, picklistId:'LOCATION', value:l.name,
                 parentValueId:l.countryId, active:l.active!==false, refId:null, meta:null };
    });
    // CURRENCY
    addVals('prowess-currencies', 'CURRENCY', function(c) {
        return { id: nextId++, picklistId:'CURRENCY', value:c.name,
                 parentValueId:null, active:c.active!==false, refId:null,
                 meta:{ code:c.code, symbol:c.symbol } };
    });

    if (changed) plSaveVals(values);
    localStorage.setItem('prowess-plv-migrated', '1');
}

// ── Seed defaults + run migration ────────────────────────────────────────
function initPicklists() {
    // Seed picklist definitions
    if (!localStorage.getItem('prowess-picklists')) {
        plSave(DEFAULT_PICKLISTS.map(function(p){ return Object.assign({}, p); }));
    } else {
        // Ensure any newly-defined system picklists are present
        var existing = plGet();
        var ids = existing.map(function(p){ return p.id; });
        var added = false;
        DEFAULT_PICKLISTS.forEach(function(p){
            if (ids.indexOf(p.id) === -1) { existing.push(Object.assign({}, p)); added = true; }
        });
        if (added) plSave(existing);
    }

    // Migrate old storage → prowess-picklist-values
    migrateToGenericPicklists();

    // Patch: ensure Expense_Category picklist definition is marked system:true in localStorage
    (function () {
        var pls = plGet();
        var idx = pls.findIndex(function (p) { return p.id === 'Expense_Category'; });
        if (idx >= 0 && !pls[idx].system) {
            pls[idx].system = true;
            plSave(pls);
        }
    }());

    // Patch: seed Expense_Category values if none exist yet (handles existing installs)
    var hasExpCat = plVals().some(function(v){ return v.picklistId === 'Expense_Category'; });
    if (!hasExpCat) {
        var expCatDefaults = [
            { refId:'EC001', value:'Cab'            },
            { refId:'EC002', value:'Flight'         },
            { refId:'EC003', value:'Hotel'          },
            { refId:'EC004', value:'Internet'       },
            { refId:'EC005', value:'Meals'          },
            { refId:'EC006', value:'Miscellaneous'  },
            { refId:'EC007', value:'Mobile'         },
            { refId:'EC008', value:'Office Supplies'},
            { refId:'EC009', value:'Training'       },
            { refId:'EC010', value:'Travel'         },
        ];
        var maxId = plVals().reduce(function(m,v){ return Math.max(m, Number(v.id)||0); }, 399999);
        var patched = plVals().concat(expCatDefaults.map(function(c, i){
            return { id: maxId + i + 1, picklistId:'Expense_Category', value:c.value,
                     parentValueId:null, active:true, refId:c.refId, meta:null };
        }));
        plSaveVals(patched);
    }

    // If still no values (fresh install with no old data), seed defaults
    if (!plVals().length) {
        var seeded = [];
        var nid = 1;
        DEFAULT_DESIGNATIONS.forEach(function(v, i){
            seeded.push({ id:nid++, picklistId:'DESIGNATION', value:v,
                parentValueId:null, active:true, refId:'D'+String(i+1).padStart(3,'0'), meta:null });
        });
        DEFAULT_NATIONALITIES.forEach(function(v, i){
            seeded.push({ id:nid++, picklistId:'NATIONALITY', value:v,
                parentValueId:null, active:true, refId:'N'+String(i+1).padStart(3,'0'), meta:null });
        });
        DEFAULT_MARITAL_STATUSES.forEach(function(v, i){
            seeded.push({ id:nid++, picklistId:'MARITAL_STATUS', value:v,
                parentValueId:null, active:true, refId:'M'+String(i+1).padStart(3,'0'), meta:null });
        });
        DEFAULT_RELATIONSHIP_TYPES.forEach(function(v, i){
            seeded.push({ id:nid++, picklistId:'RELATIONSHIP_TYPE', value:v,
                parentValueId:null, active:true, refId:'R'+String(i+1).padStart(3,'0'), meta:null });
        });
        DEFAULT_ID_COUNTRIES.forEach(function(c){
            seeded.push({ id:c.id, picklistId:'ID_COUNTRY', value:c.name,
                parentValueId:null, active:true, refId:null, meta:{code:c.code||'', flag:c.flag||''} });
        });
        DEFAULT_ID_TYPES.forEach(function(t){
            seeded.push({ id:t.id, picklistId:'ID_TYPE', value:t.name,
                parentValueId:t.countryId, active:true, refId:null, meta:null });
        });
        DEFAULT_LOCATIONS.forEach(function(l){
            seeded.push({ id:l.id, picklistId:'LOCATION', value:l.name,
                parentValueId:l.countryId, active:true, refId:null, meta:null });
        });
        DEFAULT_CURRENCIES.forEach(function(c, i){
            seeded.push({ id:300000+i, picklistId:'CURRENCY', value:c.name,
                parentValueId:null, active:true, refId:null, meta:{code:c.code, symbol:c.symbol} });
        });
        var DEFAULT_EXPENSE_CATEGORIES = [
            { refId:'EC001', value:'Cab'           },
            { refId:'EC002', value:'Flight'        },
            { refId:'EC003', value:'Hotel'         },
            { refId:'EC004', value:'Internet'      },
            { refId:'EC005', value:'Meals'         },
            { refId:'EC006', value:'Miscellaneous' },
            { refId:'EC007', value:'Mobile'        },
            { refId:'EC008', value:'Office Supplies'},
            { refId:'EC009', value:'Training'      },
            { refId:'EC010', value:'Travel'        },
        ];
        DEFAULT_EXPENSE_CATEGORIES.forEach(function(c, i){
            seeded.push({ id:400000+i, picklistId:'Expense_Category', value:c.value,
                parentValueId:null, active:true, refId:c.refId, meta:null });
        });
        plSaveVals(seeded);
        localStorage.setItem('prowess-plv-migrated', '1');
    }
}

function initReferenceData() {
    if (!localStorage.getItem('prowess-designations')) {
        const seeded = DEFAULT_DESIGNATIONS.map((v, i) => ({
            id: i + 1, refId: 'D' + String(i + 1).padStart(3, '0'), value: v
        }));
        localStorage.setItem('prowess-designations', JSON.stringify(seeded));
    }
    if (!localStorage.getItem('prowess-nationalities')) {
        const seeded = DEFAULT_NATIONALITIES.map((v, i) => ({
            id: i + 1, refId: 'N' + String(i + 1).padStart(3, '0'), value: v
        }));
        localStorage.setItem('prowess-nationalities', JSON.stringify(seeded));
    }
    if (!localStorage.getItem('prowess-marital-statuses')) {
        const seeded = DEFAULT_MARITAL_STATUSES.map((v, i) => ({
            id: i + 1, refId: 'M' + String(i + 1).padStart(3, '0'), value: v
        }));
        localStorage.setItem('prowess-marital-statuses', JSON.stringify(seeded));
    }
    if (!localStorage.getItem('prowess-relationship-types')) {
        const seeded = DEFAULT_RELATIONSHIP_TYPES.map((v, i) => ({
            id: i + 1, refId: 'R' + String(i + 1).padStart(3, '0'), value: v, active: true
        }));
        localStorage.setItem('prowess-relationship-types', JSON.stringify(seeded));
    }
    // Backfill any existing data that was seeded before refIds were introduced
    backfillRefIds('prowess-designations',      'D');
    backfillRefIds('prowess-nationalities',     'N');
    backfillRefIds('prowess-marital-statuses',  'M');
    backfillRefIds('prowess-relationship-types','R');
}

/**
 * One-time migration: for any employee whose string fields (designation,
 * nationality, maritalStatus, ecRelationship) contain the human-readable label
 * instead of a refId, look up the matching ref item and replace with its refId.
 * Safe to run repeatedly — skips fields that already look like a refId.
 */
function migrateEmployeeRefIds() {
    const empKey  = 'prowess-employees';
    const empList = JSON.parse(localStorage.getItem(empKey) || '[]');
    if (!empList.length) return;

    const desgs   = JSON.parse(localStorage.getItem('prowess-designations')      || '[]');
    const nats    = JSON.parse(localStorage.getItem('prowess-nationalities')     || '[]');
    const marits  = JSON.parse(localStorage.getItem('prowess-marital-statuses')  || '[]');
    const rels    = JSON.parse(localStorage.getItem('prowess-relationship-types')|| '[]');

    function isRefId(val) {
        // refIds look like D001, N014, M003, R007 — 1 letter + 3 digits
        return val && /^[A-Z]\d{3}$/.test(val);
    }
    function findRefId(arr, label) {
        if (!label) return null;
        const item = arr.find(i => i.value && i.value.toLowerCase() === label.toLowerCase());
        return item ? item.refId : null;
    }

    let changed = false;
    const updated = empList.map(function (emp) {
        const clone = Object.assign({}, emp);
        if (clone.designation  && !isRefId(clone.designation)) {
            const rid = findRefId(desgs, clone.designation);
            if (rid) { clone.designation  = rid; changed = true; }
        }
        if (clone.nationality  && !isRefId(clone.nationality)) {
            const rid = findRefId(nats, clone.nationality);
            if (rid) { clone.nationality  = rid; changed = true; }
        }
        if (clone.maritalStatus && !isRefId(clone.maritalStatus)) {
            const rid = findRefId(marits, clone.maritalStatus);
            if (rid) { clone.maritalStatus = rid; changed = true; }
        }
        if (clone.ecRelationship && !isRefId(clone.ecRelationship)) {
            const rid = findRefId(rels, clone.ecRelationship);
            if (rid) { clone.ecRelationship = rid; changed = true; }
        }
        return clone;
    });

    if (changed) {
        localStorage.setItem(empKey, JSON.stringify(updated));
        // Refresh in-memory array
        employees.length = 0;
        updated.forEach(function(e) { employees.push(e); });
    }
}

// ── Populate dropdowns in employee form ──────────

// ── Employee form dropdowns — value is refId, display text is label ──────────
// Storing refId means renaming a reference value never breaks existing records.

function populateDesignationDropdown() {
    var sel = document.getElementById('emp-designation');
    if (!sel) return;
    var cur = sel.value;
    sel.innerHTML = '<option value="">-- Select Designation --</option>';
    plQuery('DESIGNATION', {activeOnly:true}).forEach(function(item) {
        var opt = document.createElement('option');
        opt.value = item.refId || String(item.id);
        opt.textContent = item.value;
        sel.appendChild(opt);
    });
    sel.value = cur;
}

function populateNationalityDropdown() {
    var sel = document.getElementById('emp-nationality');
    if (!sel) return;
    var cur = sel.value;
    sel.innerHTML = '<option value="">-- Select Nationality --</option>';
    plQuery('NATIONALITY', {activeOnly:true}).forEach(function(item) {
        var opt = document.createElement('option');
        opt.value = item.refId || String(item.id);
        opt.textContent = item.value;
        sel.appendChild(opt);
    });
    sel.value = cur;
}

function populateMaritalStatusDropdown() {
    var sel = document.getElementById('emp-marital-status');
    if (!sel) return;
    var cur = sel.value;
    sel.innerHTML = '<option value="">-- Select --</option>';
    plQuery('MARITAL_STATUS', {activeOnly:true}).forEach(function(item) {
        var opt = document.createElement('option');
        opt.value = item.refId || String(item.id);
        opt.textContent = item.value;
        sel.appendChild(opt);
    });
    sel.value = cur;
}

function populateRelationshipTypeDropdown() {
    var sel = document.getElementById('ec-relationship');
    if (!sel) return;
    var cur = sel.value;
    sel.innerHTML = '<option value="">-- Select --</option>';
    plQuery('RELATIONSHIP_TYPE', {activeOnly:true}).forEach(function(item) {
        var opt = document.createElement('option');
        opt.value = item.refId || String(item.id);
        opt.textContent = item.value;
        sel.appendChild(opt);
    });
    sel.value = cur;
}


// ═══════════════════════════════════════════════
// ── SECTION 6: EXCEL EXPORT ─────────────────────
// ═══════════════════════════════════════════════

function formatDateDisplay(val) {
    if (!val) return '';
    if (val === '9999-12-31') return 'Open-ended';
    return val;
}

// ── Export Employees ─────────────────────────────

function exportEmployees() {
    const departments = JSON.parse(localStorage.getItem('prowess-departments')) || [];

    // Use currently filtered list
    const filterName   = (document.getElementById('filter-emp-name')?.value   || '').trim().toLowerCase();
    const filterId     = (document.getElementById('filter-emp-id')?.value     || '').trim().toLowerCase();
    const filterDesg   = (document.getElementById('filter-designation')?.value || '');
    const filterDept   = (document.getElementById('filter-department')?.value  || '');
    const filterStatus = (document.getElementById('filter-status')?.value      || '');

    const list = employees.filter(function (emp) {
        if (filterName   && !emp.name.toLowerCase().includes(filterName))       return false;
        if (filterId     && !emp.employeeId.toLowerCase().includes(filterId))   return false;
        if (filterDesg   && emp.designation !== filterDesg)                     return false;
        if (filterDept   && emp.departmentId !== filterDept)                    return false;
        if (filterStatus && getEmpStatus(emp) !== filterStatus)                 return false;
        return true;
    });

    if (list.length === 0) { alert('No data to export.'); return; }

    const rows = list.map(function (emp, i) {
        const deptName    = emp.departmentId
            ? (departments.find(d => d.deptId === emp.departmentId)?.name || emp.departmentId)
            : '';
        const managerName = emp.managerId
            ? (employees.find(e => e.employeeId === emp.managerId)?.name || emp.managerId)
            : '';
        // Resolve primary ID (explicit primary flag, or fall back to first record)
        const _idVals     = plVals();
        const primaryId   = getPrimaryId(emp.identifications);
        const primCountry = primaryId ? ((_idVals.find(v => v.picklistId === 'ID_COUNTRY' && String(v.id) === String(primaryId.countryId)) || {}).value || '') : '';
        const primType    = primaryId ? ((_idVals.find(v => v.picklistId === 'ID_TYPE'    && String(v.id) === String(primaryId.idTypeId))  || {}).value || '') : '';

        return {
            '#':                   i + 1,
            'Employee ID':         emp.employeeId,
            'Full Name':           emp.name,
            'Designation':         resolveRefLabel(emp.designation,   'prowess-designations'),
            'Department':          deptName,
            'Manager':             managerName,
            'Mobile':              emp.mobile          || '',
            'Business Email':      emp.businessEmail   || '',
            'Personal Email':      emp.personalEmail   || '',
            'Passport Country':    emp.passportCountry
                ? (COUNTRIES.find(c => c.code === emp.passportCountry)?.name || emp.passportCountry)
                : '',
            'Passport Number':     emp.passportNumber     || '',
            'Passport Issue Date': formatDateDisplay(emp.passportIssueDate),
            'Passport Expiry':     formatDateDisplay(emp.passportExpiryDate),
            'Nationality':         resolveRefLabel(emp.nationality,   'prowess-nationalities'),
            'Marital Status':      resolveRefLabel(emp.maritalStatus, 'prowess-marital-statuses'),
            'Hire Date':           formatDateDisplay(emp.hireDate),
            'End Date':            formatDateDisplay(emp.endDate),
            'Role':                emp.role            || 'Employee',
            'Status':              getEmpStatus(emp),
            'Primary ID Country':  primCountry,
            'Primary ID Type':     primType,
            'Primary ID Number':   primaryId ? primaryId.idNumber   : '',
            'Primary ID Expiry':   primaryId ? formatDateDisplay(primaryId.expiryDate) : '',
        };
    });

    // ── Sheet 1: Employees ──────────────────────────
    const ws1 = XLSX.utils.json_to_sheet(rows);
    // Column widths: #, EmpID, Name, Designation, Dept, Manager,
    //   Mobile, BizEmail, PersEmail, PassportCountry, PassportNum,
    //   PassportIssue, PassportExpiry, Nationality, MaritalStatus,
    //   HireDate, EndDate, Role, Status,
    //   PrimaryIDCountry, PrimaryIDType, PrimaryIDNumber, PrimaryIDExpiry
    ws1['!cols'] = [
        {wch:4},{wch:12},{wch:22},{wch:20},{wch:20},{wch:20},
        {wch:18},{wch:28},{wch:28},{wch:18},{wch:16},{wch:14},{wch:14},
        {wch:14},{wch:14},{wch:12},{wch:12},{wch:10},{wch:12},
        {wch:18},{wch:20},{wch:18},{wch:14}
    ];

    // ── Sheet 2: All ID Records ─────────────────────
    const idRows = [];
    list.forEach(function (emp) {
        (emp.identifications || []).forEach(function (r) {
            const cn     = idCountries.find(c => String(c.id) === String(r.countryId))?.name || '—';
            const tn     = idTypes.find(t => String(t.id) === String(r.idTypeId))?.name      || '—';
            const status = getIdStatus(r);
            // Determine record type: explicit flag, or first record = Primary as fallback
            const recType = r.isPrimary
                ? 'Primary'
                : (!r.hasOwnProperty('isPrimary') && emp.identifications.indexOf(r) === 0)
                    ? 'Primary (auto)'
                    : 'Secondary';
            idRows.push({
                'Employee Name':  emp.name,
                'Employee ID':    emp.employeeId,
                'Department':     emp.departmentId
                    ? (JSON.parse(localStorage.getItem('prowess-departments') || '[]')
                        .find(d => d.deptId === emp.departmentId)?.name || emp.departmentId)
                    : '',
                'Country':        cn,
                'ID Type':        tn,
                'ID Number':      r.idNumber,
                'Expiry Date':    r.expiryDate ? formatDateDisplay(r.expiryDate) : '',
                'Status':         status,
                'Record Type':    recType,
            });
        });
    });
    const ws2 = XLSX.utils.json_to_sheet(
        idRows.length > 0 ? idRows : [{ 'Note': 'No ID records found for exported employees.' }]
    );
    ws2['!cols'] = [
        {wch:22},{wch:12},{wch:20},{wch:16},{wch:22},{wch:18},{wch:14},{wch:14},{wch:14}
    ];

    const wb = XLSX.utils.book_new();
    XLSX.utils.book_append_sheet(wb, ws1, 'Employees');
    XLSX.utils.book_append_sheet(wb, ws2, 'ID Records');

    const today = new Date().toISOString().split('T')[0];
    const filename = `Prowess_Employees_${today}.xlsx`;
    XLSX.writeFile(wb, filename);
    showExportToast(filename, list.length, list.length === 1 ? 'employee' : 'employees');
}

// ── Export Departments ───────────────────────────

function exportDepartments() {
    const departments = JSON.parse(localStorage.getItem('prowess-departments')) || [];

    if (departments.length === 0) { alert('No data to export.'); return; }

    const rows = departments.map(function (dept, i) {
        const headName = dept.headId
            ? (employees.find(e => e.employeeId === dept.headId)?.name || dept.headId)
            : '';
        const parentName = dept.parentId
            ? (departments.find(d => d.deptId === dept.parentId)?.name || dept.parentId)
            : '';
        const status = dept.endDate && dept.endDate < new Date().toISOString().split('T')[0]
            ? 'Expired'
            : dept.startDate > new Date().toISOString().split('T')[0]
                ? 'Upcoming'
                : 'Active';
        return {
            '#':                 i + 1,
            'Dept ID':           dept.deptId,
            'Department Name':   dept.name,
            'Department Head':   headName,
            'Parent Department': parentName,
            'Start Date':        formatDateDisplay(dept.startDate),
            'End Date':          formatDateDisplay(dept.endDate),
            'Status':            status
        };
    });

    const ws = XLSX.utils.json_to_sheet(rows);
    ws['!cols'] = [
        {wch:4},{wch:10},{wch:24},{wch:22},{wch:22},{wch:12},{wch:12},{wch:10}
    ];

    const wb = XLSX.utils.book_new();
    XLSX.utils.book_append_sheet(wb, ws, 'Departments');

    const today = new Date().toISOString().split('T')[0];
    const filename = `Prowess_Departments_${today}.xlsx`;
    XLSX.writeFile(wb, filename);
    showExportToast(filename, departments.length, departments.length === 1 ? 'department' : 'departments');
}

// ── Export toast notification ────────────────────

function showExportToast(filename, count, noun) {
    const toast = document.getElementById('export-toast');
    if (!toast) return;
    toast.innerHTML = `<i class="fa-solid fa-circle-check"></i>&nbsp; <strong>${count} ${noun}</strong> exported &mdash; <em>${filename}</em>`;
    toast.classList.add('export-toast--show');
    clearTimeout(toast._hideTimer);
    toast._hideTimer = setTimeout(function () {
        toast.classList.remove('export-toast--show');
    }, 3500);
}

// ── Dynamic export button label helpers ─────────

function updateEmpExportLabel(visibleCount, totalCount) {
    const mainEl = document.getElementById('export-emp-main');
    const subEl  = document.getElementById('export-emp-sub');
    if (!mainEl || !subEl) return;
    const isFiltered = visibleCount < totalCount;
    mainEl.textContent = isFiltered
        ? `Export ${visibleCount} of ${totalCount} Employees`
        : `Export ${totalCount} Employee${totalCount !== 1 ? 's' : ''}`;
    subEl.textContent  = isFiltered ? 'filtered view' : 'all records · Excel';
}

function updateDeptExportLabel(visibleCount, totalCount) {
    const allDepts = JSON.parse(localStorage.getItem('prowess-departments')) || [];
    const total = totalCount !== undefined ? totalCount : allDepts.length;
    const visible = visibleCount !== undefined ? visibleCount : total;
    const mainEl  = document.getElementById('export-dept-main');
    const subEl   = document.getElementById('export-dept-sub');
    const countEl = document.getElementById('dept-table-count');
    const isFiltered = visible < total;
    if (mainEl) mainEl.textContent = isFiltered
        ? `Export ${visible} of ${total} Departments`
        : `Export ${total} Department${total !== 1 ? 's' : ''}`;
    if (subEl)  subEl.textContent  = isFiltered ? 'filtered view' : 'all records · Excel';
    if (countEl) countEl.textContent = total > 0 ? `${total} record${total !== 1 ? 's' : ''}` : '';
}

// ── Wire export buttons ──────────────────────────

document.getElementById('btn-export-employees').addEventListener('click', exportEmployees);
document.getElementById('btn-export-departments').addEventListener('click', exportDepartments);

// ═══════════════════════════════════════════════
// ── SECTION 6: EMPLOYEE IDENTIFICATION ─────────
// ═══════════════════════════════════════════════

// ── 6A. Reference Data: ID Countries & ID Types ─

const DEFAULT_ID_COUNTRIES = [
    { id: 10001, name: 'India' },
    { id: 10002, name: 'Saudi Arabia' },
    { id: 10003, name: 'United Arab Emirates' },
    { id: 10004, name: 'Malaysia' },
    { id: 10005, name: 'Singapore' },
    { id: 10006, name: 'United States' },
    { id: 10007, name: 'United Kingdom' },
    { id: 10008, name: 'Qatar' },
    { id: 10009, name: 'Kuwait' },
    { id: 10010, name: 'Bahrain' },
    { id: 10011, name: 'Oman' },
    { id: 10012, name: 'Pakistan' },
    { id: 10013, name: 'Sri Lanka' },
    { id: 10014, name: 'Bangladesh' },
    { id: 10015, name: 'Nepal' },
];

const DEFAULT_ID_TYPES = [
    // India
    { id: 20001, countryId: 10001, name: 'Aadhaar' },
    { id: 20002, countryId: 10001, name: 'PAN' },
    { id: 20003, countryId: 10001, name: 'Voter ID' },
    { id: 20004, countryId: 10001, name: 'Driving License' },
    // Saudi Arabia
    { id: 20005, countryId: 10002, name: 'Iqama' },
    { id: 20006, countryId: 10002, name: 'Saudi National ID' },
    // UAE
    { id: 20007, countryId: 10003, name: 'Emirates ID' },
    { id: 20008, countryId: 10003, name: 'UAE Residence Visa' },
    // Malaysia
    { id: 20009, countryId: 10004, name: 'MyKad' },
    { id: 20010, countryId: 10004, name: 'MyPR' },
    { id: 20011, countryId: 10004, name: 'Work Permit' },
    // Singapore
    { id: 20012, countryId: 10005, name: 'NRIC' },
    { id: 20013, countryId: 10005, name: 'FIN' },
    { id: 20014, countryId: 10005, name: 'Employment Pass' },
    // United States
    { id: 20015, countryId: 10006, name: 'Social Security' },
    { id: 20016, countryId: 10006, name: 'Green Card' },
    { id: 20017, countryId: 10006, name: "Driver's License" },
    // United Kingdom
    { id: 20018, countryId: 10007, name: 'National Insurance' },
    { id: 20019, countryId: 10007, name: 'BRP' },
    // Qatar
    { id: 20020, countryId: 10008, name: 'Qatar ID' },
    { id: 20021, countryId: 10008, name: 'Qatar Residence Permit' },
    // Kuwait
    { id: 20022, countryId: 10009, name: 'Civil ID' },
    // Bahrain
    { id: 20023, countryId: 10010, name: 'CPR' },
    // Oman
    { id: 20024, countryId: 10011, name: 'Oman Resident Card' },
    // Pakistan
    { id: 20025, countryId: 10012, name: 'CNIC' },
    { id: 20026, countryId: 10012, name: 'NICOP' },
    // Sri Lanka
    { id: 20027, countryId: 10013, name: 'NIC' },
    // Bangladesh
    { id: 20028, countryId: 10014, name: 'NID' },
    // Nepal
    { id: 20029, countryId: 10015, name: 'Citizenship Certificate' },
];

// ── DEFAULT LOCATIONS ────────────────────────────────────────────────────
// Each location is mapped to a countryId from prowess-id-countries.
// Country → Location mapping: when the employee selects a Country of Work,
// only locations whose countryId matches the selected country are shown.
// Admin can add new locations, change their country mapping, and
// activate/deactivate them via Reference Data → Locations.
const DEFAULT_LOCATIONS = [
    // India (countryId: 10001)
    { id: 30001, countryId: 10001, name: 'Chennai',      active: true },
    { id: 30002, countryId: 10001, name: 'Bangalore',    active: true },
    { id: 30003, countryId: 10001, name: 'Hyderabad',    active: true },
    { id: 30004, countryId: 10001, name: 'Osmanabad',    active: true },
    { id: 30005, countryId: 10001, name: 'Mumbai',       active: true },
    { id: 30006, countryId: 10001, name: 'Delhi',        active: true },
    // Saudi Arabia (countryId: 10002)
    { id: 30007, countryId: 10002, name: 'Riyadh',       active: true },
    { id: 30008, countryId: 10002, name: 'Jeddah',       active: true },
    { id: 30009, countryId: 10002, name: 'Jubail',       active: true },
    { id: 30010, countryId: 10002, name: 'Dammam',       active: true },
    // United Arab Emirates (countryId: 10003)
    { id: 30011, countryId: 10003, name: 'Dubai',        active: true },
    { id: 30012, countryId: 10003, name: 'Abu Dhabi',    active: true },
    { id: 30013, countryId: 10003, name: 'Sharjah',      active: true },
    // Malaysia (countryId: 10004)
    { id: 30014, countryId: 10004, name: 'Kuala Lumpur', active: true },
    { id: 30015, countryId: 10004, name: 'Johor Bahru',  active: true },
    // Singapore (countryId: 10005)
    { id: 30016, countryId: 10005, name: 'Singapore',    active: true },
    // United States (countryId: 10006)
    { id: 30017, countryId: 10006, name: 'New York',     active: true },
    { id: 30018, countryId: 10006, name: 'Houston',      active: true },
    // United Kingdom (countryId: 10007)
    { id: 30019, countryId: 10007, name: 'London',       active: true },
    // Qatar (countryId: 10008)
    { id: 30020, countryId: 10008, name: 'Doha',         active: true },
    // Kuwait (countryId: 10009)
    { id: 30021, countryId: 10009, name: 'Kuwait City',  active: true },
    // Bahrain (countryId: 10010)
    { id: 30022, countryId: 10010, name: 'Manama',       active: true },
    // Oman (countryId: 10011)
    { id: 30023, countryId: 10011, name: 'Muscat',       active: true },
    // Pakistan (countryId: 10012)
    { id: 30024, countryId: 10012, name: 'Karachi',      active: true },
    { id: 30025, countryId: 10012, name: 'Lahore',       active: true },
    // Sri Lanka (countryId: 10013)
    { id: 30026, countryId: 10013, name: 'Colombo',      active: true },
    // Bangladesh (countryId: 10014)
    { id: 30027, countryId: 10014, name: 'Dhaka',        active: true },
    // Nepal (countryId: 10015)
    { id: 30028, countryId: 10015, name: 'Kathmandu',    active: true },
];

// ── Populate all country selects used in the ID feature ──────

function populateIdCountrySelects() {
    var items  = plQuery('ID_COUNTRY', {activeOnly: true});
    var empSel = document.getElementById('emp-id-country');
    if (empSel) {
        var cur = empSel.value;
        empSel.innerHTML = '<option value="">-- Select Country --</option>';
        items.forEach(function(item) {
            var o = document.createElement('option');
            o.value = item.id; o.textContent = item.value;
            empSel.appendChild(o);
        });
        empSel.value = cur;
    }
}

// ── Populate Country of Work dropdown in the employee form ───────────────

function populateWorkCountrySelect() {
    var items = plQuery('ID_COUNTRY', {activeOnly: true});
    var sel   = document.getElementById('emp-work-country');
    if (!sel) return;
    var cur = sel.value;
    sel.innerHTML = '<option value="">-- Select Country --</option>';
    items.forEach(function(item) {
        var o = document.createElement('option');
        o.value = item.id; o.textContent = item.value;
        sel.appendChild(o);
    });
    sel.value = cur;
}

// ── Filter Location dropdown by selected Country of Work ─────────────────

function populateWorkLocationSelect(countryId) {
    var sel = document.getElementById('emp-work-location');
    if (!sel) return;
    if (!countryId) {
        sel.innerHTML = '<option value="">-- Select Country First --</option>';
        sel.disabled  = true;
        return;
    }
    var items = plQuery('LOCATION', {activeOnly: true, parentValueId: countryId});
    sel.innerHTML = '<option value="">-- Select Location --</option>';
    items.forEach(function(item) {
        var o = document.createElement('option');
        o.value = item.id; o.textContent = item.value;
        sel.appendChild(o);
    });
    sel.disabled = (items.length === 0);
}

// Wire Country of Work change → refresh dependent Location dropdown
document.getElementById('emp-work-country').addEventListener('change', function () {
    // Clear saved location when country changes — prevents stale foreign-key
    document.getElementById('emp-work-location').value = '';
    populateWorkLocationSelect(this.value);
});

/** Filter ID Types dropdown by selected country */
function populateIdTypeSelect(countryId) {
    var sel = document.getElementById('emp-id-type');
    if (!sel) return;
    if (!countryId) {
        sel.innerHTML = '<option value="">-- Select Country first --</option>';
        sel.disabled  = true;
        return;
    }
    var items = plQuery('ID_TYPE', {activeOnly: true, parentValueId: countryId});
    sel.innerHTML = '<option value="">-- Select ID Type --</option>';
    items.forEach(function(item) {
        var o = document.createElement('option');
        o.value = item.id; o.textContent = item.value;
        sel.appendChild(o);
    });
    sel.disabled = (items.length === 0);
}

// ID Type selection makes ID Number mandatory and Record Type required
document.getElementById('emp-id-type').addEventListener('change', function () {
    const idNumberInput = document.getElementById('emp-id-number');
    if (this.value) {
        idNumberInput.setAttribute('required', '');
        requirePrimaryField();
    } else {
        idNumberInput.removeAttribute('required');
    }
});

// ── 6B. Employee ID Records (per-employee, stored in employee.identifications) ─

/** Temp buffer: holds the ID records for the employee currently in the form */
let tempEmpIds    = [];
let editingIdIdx  = null; // index into tempEmpIds being edited

/** Status helpers for a single ID record */
const ID_EXPIRY_ALERT_DAYS = 15;

function getIdStatus(record) {
    if (!record.expiryDate) return 'Active';
    const today    = new Date(); today.setHours(0, 0, 0, 0);
    const expiry   = new Date(record.expiryDate);
    const diffDays = Math.floor((expiry - today) / 86400000);
    if (diffDays < 0)                      return 'Expired';
    if (diffDays <= ID_EXPIRY_ALERT_DAYS)  return 'Expiring Soon';
    return 'Active';
}

function getIdStatusBadge(status) {
    const map = {
        'Active':        'id-badge-active',
        'Expiring Soon': 'id-badge-expiring',
        'Expired':       'id-badge-expired',
    };
    return `<span class="id-status-badge ${map[status] || 'id-badge-active'}">${status}</span>`;
}

/** Helper: resolve the primary record for an employee's identifications.
 *  Falls back to the first record if none is explicitly marked primary. */
function getPrimaryId(identifications) {
    if (!identifications || identifications.length === 0) return null;
    return identifications.find(r => r.isPrimary) || identifications[0];
}

/** Render the mini ID table inside the employee form */
function renderEmpIdList() {
    var allVals = plVals();
    const listWrap  = document.getElementById('emp-id-records-list');
    const tbody     = document.getElementById('emp-id-tbody');
    if (!listWrap || !tbody) return;

    if (tempEmpIds.length === 0) {
        listWrap.style.display = 'none';
        return;
    }
    listWrap.style.display = 'block';

    tbody.innerHTML = '';
    tempEmpIds.forEach(function (rec, idx) {
        var cItem = allVals.find(function(v) { return v.picklistId === 'ID_COUNTRY' && String(v.id) === String(rec.countryId); });
        var tItem = allVals.find(function(v) { return v.picklistId === 'ID_TYPE'    && String(v.id) === String(rec.idTypeId); });
        const countryName  = cItem ? cItem.value : '—';
        const typeName     = tItem ? tItem.value : '—';
        const status       = getIdStatus(rec);
        const statusBadge  = getIdStatusBadge(status);
        const primaryBadge = rec.isPrimary
            ? '<span class="id-primary-badge"><i class="fa-solid fa-star"></i> Primary</span>'
            : '<span class="id-secondary-badge">Secondary</span>';
        const tr = document.createElement('tr');
        tr.innerHTML = `
            <td>${primaryBadge}</td>
            <td>${countryName}</td>
            <td>${typeName}</td>
            <td><strong>${rec.idNumber}</strong></td>
            <td>${rec.expiryDate || '—'}</td>
            <td>${statusBadge}</td>
            <td>
                <div class="emp-id-row-actions">
                    <button type="button" class="emp-id-edit-btn"   data-idx="${idx}" title="Edit">
                        <i class="fa-solid fa-pen-to-square"></i>
                    </button>
                    <button type="button" class="emp-id-delete-btn" data-idx="${idx}" title="Delete">
                        <i class="fa-solid fa-trash"></i>
                    </button>
                </div>
            </td>`;
        tbody.appendChild(tr);
    });
}

/** Reset the ID add/edit sub-form */
function resetIdAddForm() {
    document.getElementById('emp-id-country').value    = '';
    document.getElementById('emp-id-type').innerHTML   = '<option value="">-- Select Country first --</option>';
    document.getElementById('emp-id-type').disabled    = true;
    document.getElementById('emp-id-is-primary').value = '';
    document.getElementById('emp-id-is-primary').removeAttribute('required');
    const idNumInput = document.getElementById('emp-id-number');
    idNumInput.value = '';
    idNumInput.removeAttribute('required');
    document.getElementById('emp-id-expiry').value          = '';
    document.getElementById('emp-id-error').style.display   = 'none';
    document.getElementById('emp-id-add-btn').innerHTML     = '<i class="fa-solid fa-plus"></i> Add ID';
    document.getElementById('emp-id-cancel-edit-btn').style.display = 'none';
    editingIdIdx = null;
}

/** Make Record Type required as soon as Country or ID Type is touched */
function requirePrimaryField() {
    document.getElementById('emp-id-is-primary').setAttribute('required', '');
}

// Country change also drives Record Type required
document.getElementById('emp-id-country').addEventListener('change', function () {
    populateIdTypeSelect(this.value);
    document.getElementById('emp-id-number').removeAttribute('required');
    if (this.value) requirePrimaryField();
    else document.getElementById('emp-id-is-primary').removeAttribute('required');
});

/** Add / Update ID record button */
document.getElementById('emp-id-add-btn').addEventListener('click', function () {
    const countryId  = document.getElementById('emp-id-country').value;
    const idTypeId   = document.getElementById('emp-id-type').value;
    const isPrimaryV = document.getElementById('emp-id-is-primary').value;   // 'primary' | 'secondary' | ''
    const idNumber   = document.getElementById('emp-id-number').value.trim();
    const expiryDate = document.getElementById('emp-id-expiry').value;
    const errEl      = document.getElementById('emp-id-error');
    errEl.style.display = 'none';

    // Validation
    if (!countryId) {
        errEl.textContent = 'Please select a country.'; errEl.style.display = 'inline'; return;
    }
    if (!idTypeId) {
        errEl.textContent = 'Please select an ID type.'; errEl.style.display = 'inline'; return;
    }
    if (!isPrimaryV) {
        errEl.textContent = 'Please select a Record Type (Primary or Secondary).'; errEl.style.display = 'inline'; return;
    }
    if (!idNumber) {
        errEl.textContent = 'ID Number is mandatory.'; errEl.style.display = 'inline'; return;
    }
    if (expiryDate) {
        const today = new Date().toISOString().split('T')[0];
        if (expiryDate <= today) {
            errEl.textContent = 'Expiry Date must be a future date.'; errEl.style.display = 'inline'; return;
        }
    }

    const isPrimary = (isPrimaryV === 'primary');

    // If marking as primary, demote any existing primary to secondary
    if (isPrimary) {
        tempEmpIds = tempEmpIds.map(function (r, i) {
            if (i === editingIdIdx) return r; // will be replaced below
            return r.isPrimary ? { ...r, isPrimary: false } : r;
        });
    }

    // Duplicate ID Type check
    const dupIdx = tempEmpIds.findIndex(function (r, i) {
        return String(r.idTypeId) === String(idTypeId) && i !== editingIdIdx;
    });
    if (dupIdx !== -1) {
        if (!confirm('This employee already has a record for this ID type. Add anyway?')) return;
    }

    if (editingIdIdx !== null) {
        tempEmpIds[editingIdIdx] = { ...tempEmpIds[editingIdIdx], countryId, idTypeId, isPrimary, idNumber, expiryDate };
    } else {
        tempEmpIds.push({ id: Date.now(), countryId, idTypeId, isPrimary, idNumber, expiryDate });
    }
    resetIdAddForm();
    renderEmpIdList();
});

/** Cancel edit on ID sub-form */
document.getElementById('emp-id-cancel-edit-btn').addEventListener('click', function () {
    resetIdAddForm();
});

/** Edit / Delete row clicks (event delegation on tbody) */
document.getElementById('emp-id-tbody').addEventListener('click', function (e) {
    const editBtn   = e.target.closest('.emp-id-edit-btn');
    const deleteBtn = e.target.closest('.emp-id-delete-btn');

    if (editBtn) {
        const idx = Number(editBtn.getAttribute('data-idx'));
        const rec = tempEmpIds[idx];
        if (!rec) return;
        editingIdIdx = idx;

        document.getElementById('emp-id-country').value    = rec.countryId;
        requirePrimaryField();
        populateIdTypeSelect(rec.countryId);
        setTimeout(function () {
            document.getElementById('emp-id-type').value       = rec.idTypeId;
            document.getElementById('emp-id-is-primary').value = rec.isPrimary ? 'primary' : 'secondary';
            if (rec.idTypeId) document.getElementById('emp-id-number').setAttribute('required', '');
        }, 0);
        document.getElementById('emp-id-number').value = rec.idNumber;
        document.getElementById('emp-id-expiry').value = rec.expiryDate || '';
        document.getElementById('emp-id-add-btn').innerHTML = '<i class="fa-solid fa-floppy-disk"></i> Update ID';
        document.getElementById('emp-id-cancel-edit-btn').style.display = 'inline-flex';
    }

    if (deleteBtn) {
        const idx = Number(deleteBtn.getAttribute('data-idx'));
        if (!confirm('Remove this ID record?')) return;
        tempEmpIds.splice(idx, 1);
        renderEmpIdList();
        if (editingIdIdx === idx) resetIdAddForm();
    }
});

// ── 6C. ID Alerts ──────────────────────────────

function buildIdNotifyMailto(emp, record, status) {
    const _allIdVals  = plVals();
    const countryName = (_allIdVals.find(v => v.picklistId === 'ID_COUNTRY' && String(v.id) === String(record.countryId)) || {}).value || '—';
    const typeName    = (_allIdVals.find(v => v.picklistId === 'ID_TYPE'    && String(v.id) === String(record.idTypeId))  || {}).value || '—';

    const hrEmails  = getHrEmails();
    const toAddress = emp.businessEmail || emp.personalEmail || '';
    const ccAddress = hrEmails.filter(e => e !== toAddress).join(',');

    let subject, body;
    if (status === 'Expired') {
        subject = `Your ${typeName} has expired`;
        body    = `Dear ${emp.name},\n\nYour ${typeName} for ${countryName} has expired on ${record.expiryDate}.\n` +
                  `Please update your records immediately.\n\nRegards,\nHR Team`;
    } else {
        const today    = new Date(); today.setHours(0, 0, 0, 0);
        const diffDays = Math.floor((new Date(record.expiryDate) - today) / 86400000);
        subject = `Your ${typeName} is expiring soon`;
        body    = `Dear ${emp.name},\n\nYour ${typeName} for ${countryName} will expire on ${record.expiryDate} ` +
                  `(in ${diffDays} day${diffDays !== 1 ? 's' : ''}).\n` +
                  `Please take necessary action to renew it.\n\nRegards,\nHR Team`;
    }

    let href = `mailto:${toAddress}?subject=${encodeURIComponent(subject)}&body=${encodeURIComponent(body)}`;
    if (ccAddress) href += `&cc=${encodeURIComponent(ccAddress)}`;
    return href;
}

function renderIdAlerts() {
    const panel = document.getElementById('id-alerts-panel');
    if (!panel) return;

    // Collect all ID records needing attention across all employees
    const alerts = [];
    employees.forEach(function (emp) {
        (emp.identifications || []).forEach(function (rec) {
            const status = getIdStatus(rec);
            if (status === 'Expired' || status === 'Expiring Soon') {
                alerts.push({ emp, record: rec, status });
            }
        });
    });

    // Update sidebar badge for IDs (combine with passport badge later if needed)
    if (alerts.length === 0) {
        panel.style.display = 'none';
        panel.innerHTML     = '';
        return;
    }

    // Sort: Expired first, then Expiring Soon; within each group, soonest first
    const statusOrder = { 'Expired': 0, 'Expiring Soon': 1 };
    alerts.sort((a, b) => {
        const so = statusOrder[a.status] - statusOrder[b.status];
        if (so !== 0) return so;
        return (a.record.expiryDate || '').localeCompare(b.record.expiryDate || '');
    });

    const _alertVals = plVals();

    function buildRows(items) {
        return items.map(function ({ emp, record, status }) {
            const countryName = (_alertVals.find(v => v.picklistId === 'ID_COUNTRY' && String(v.id) === String(record.countryId)) || {}).value || '—';
            const typeName    = (_alertVals.find(v => v.picklistId === 'ID_TYPE'    && String(v.id) === String(record.idTypeId))  || {}).value || '—';
            const today       = new Date(); today.setHours(0,0,0,0);
            const diffDays    = record.expiryDate
                ? Math.floor((new Date(record.expiryDate) - today) / 86400000)
                : null;
            const dayLabel    = status === 'Expired'
                ? `Expired ${Math.abs(diffDays)}d ago`
                : `Expires in ${diffDays}d`;
            const levelClass  = status === 'Expired' ? 'id-alert-expired' : 'id-alert-expiring';
            const mailtoHref  = buildIdNotifyMailto(emp, record, status);

            return `
              <div class="pa-row">
                <div class="pa-emp-info">
                    <strong>${emp.name}</strong>
                    <span class="pa-empid">${emp.employeeId}</span>
                </div>
                <div class="pa-passport-info">
                    <span>${countryName}</span>
                    <span class="pa-sep">·</span>
                    <span><strong>${typeName}</strong></span>
                    <span class="pa-sep">·</span>
                    <span>${record.idNumber}</span>
                    <span class="pa-sep">·</span>
                    <span>${record.expiryDate || '—'}</span>
                </div>
                <div class="pa-days-badge ${levelClass}">${dayLabel}</div>
                <a class="pa-notify-btn" href="${mailtoHref}" title="Notify ${emp.name}">
                    <i class="fa-solid fa-envelope"></i> Notify
                </a>
              </div>`;
        }).join('');
    }

    const expired  = alerts.filter(a => a.status === 'Expired');
    const expiring = alerts.filter(a => a.status === 'Expiring Soon');

    let html = `<div class="passport-alerts-card id-alerts-card">
      <div class="pa-header">
        <i class="fa-solid fa-id-card-clip"></i>
        ID Expiry Alerts &nbsp;<span class="pa-total-badge">${alerts.length} record${alerts.length !== 1 ? 's' : ''}</span>
        <span class="pa-header-hint">Clicking "Notify" opens a pre-filled email in your mail client.</span>
      </div>`;

    if (expired.length)  html += `<div class="pa-section-title pa-title-expired"><i class="fa-solid fa-circle-xmark"></i> Expired (${expired.length})</div>${buildRows(expired)}`;
    if (expiring.length) html += `<div class="pa-section-title pa-title-critical"><i class="fa-solid fa-circle-exclamation"></i> Expiring within ${ID_EXPIRY_ALERT_DAYS} days (${expiring.length})</div>${buildRows(expiring)}`;

    html += `</div>`;
    panel.innerHTML    = html;
    panel.style.display = 'block';
}

// ── Wire export buttons ── (already done above, this is just init ordering)

// ── INITIALIZE ──────────────────────────────────

initPicklists();
migrateEmployeeRefIds();
populateEmployeeFormDropdowns();

// ── LOCATIONS infrastructure removed – managed via generic Reference Data module ──

populateIdCountrySelects();
populateDeptFormDropdowns();
renderEmployees();
renderDepartments();
renderOrgChart();
renderProjects();
renderWfRoles();

// ═══════════════════════════════════════════════════════════════════
// ── DEPARTMENT ORG CHART  (doc-* prefix, admin Departments tab) ────
// ═══════════════════════════════════════════════════════════════════

function escHtml(str) {
    return String(str || '')
        .replace(/&/g,'&amp;').replace(/</g,'&lt;')
        .replace(/>/g,'&gt;').replace(/"/g,'&quot;');
}

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

// State
let docMap        = {};
let docRoots      = [];
let docCollapsed  = new Set();
let docSelectedId = null;
let docFocusId    = null;
let docZoom       = 1;
let docPanX       = 0;
let docPanY       = 0;
let docDragging   = false;
let docDragStart  = { x: 0, y: 0, px: 0, py: 0 };

// ── Color helpers ──────────────────────────────────────────────────

function docColor(deptId) {
    const n = String(deptId || 'a').split('').reduce((a, c) => a + c.charCodeAt(0), 0);
    return DOC_PALETTE[Math.abs(n) % DOC_PALETTE.length];
}

// ── Tree builders ──────────────────────────────────────────────────

function docBuildTree(deptList) {
    docMap   = {};
    docRoots = [];
    deptList.forEach(d => { docMap[d.deptId] = Object.assign({}, d, { children: [] }); });
    deptList.forEach(d => {
        if (d.parentDeptId && docMap[d.parentDeptId]) {
            docMap[d.parentDeptId].children.push(docMap[d.deptId]);
        } else {
            docRoots.push(docMap[d.deptId]);
        }
    });
    function sortChildren(node) {
        node.children.sort((a, b) => a.name.localeCompare(b.name));
        node.children.forEach(sortChildren);
    }
    docRoots.forEach(sortChildren);
}

function docSubDeptCount(deptId) {
    const node = docMap[deptId];
    if (!node) return 0;
    let count = node.children.length;
    node.children.forEach(c => { count += docSubDeptCount(c.deptId); });
    return count;
}

function docReportingChain(deptId) {
    const chain = [];
    let cur = docMap[deptId];
    while (cur) {
        chain.unshift(cur.deptId);
        cur = cur.parentDeptId ? docMap[cur.parentDeptId] : null;
    }
    return chain;
}

function docAllSubDepts(deptId) {
    const result = [];
    const node   = docMap[deptId];
    if (!node) return result;
    node.children.forEach(c => {
        result.push(c.deptId);
        result.push(...docAllSubDepts(c.deptId));
    });
    return result;
}

// ── Card renderer (recursive) ──────────────────────────────────────

function docRenderNode(node) {
    const color      = docColor(node.deptId);
    const initial    = (node.name || '?').charAt(0).toUpperCase();
    const hasChildren = node.children.length > 0;
    const collapsed   = docCollapsed.has(node.deptId);
    const subCount    = docSubDeptCount(node.deptId);
    const empCount    = employees.filter(e => e.departmentId === node.deptId).length;
    const headName    = node.headId
        ? (employees.find(e => e.employeeId === node.headId)?.name || node.headId)
        : 'No Head';
    const parentName  = node.parentDeptId && docMap[node.parentDeptId]
        ? docMap[node.parentDeptId].name : null;

    const wrap = document.createElement('div');
    wrap.className     = 'eoc-node-wrap';
    wrap.dataset.deptId = node.deptId;

    const card = document.createElement('div');
    card.className     = 'eoc-card doc-dept-card';
    card.dataset.deptId = node.deptId;
    card.style.setProperty('--eoc-border', color.border);
    card.style.setProperty('--eoc-bg',     color.bg);
    card.title = node.name + ' — click for details, double-click to focus';

    card.innerHTML =
        '<div class="eoc-avatar" style="background:' + color.avatar + ';">' + initial + '</div>' +
        '<div class="eoc-card-body">' +
            '<div class="eoc-card-name">' + escHtml(node.name) + '</div>' +
            '<div class="eoc-card-desg"><i class="fa-solid fa-user-tie" style="font-size:10px;margin-right:3px;"></i>' + escHtml(headName) + '</div>' +
            (parentName ? '<div class="eoc-card-dept">' + escHtml(parentName) + '</div>' : '') +
            '<div class="eoc-card-id">' + escHtml(node.deptId) + '</div>' +
        '</div>' +
        '<div class="eoc-team-badge" style="gap:6px;">' +
            '<i class="fa-solid fa-users"></i> ' + empCount + ' emp' +
            (subCount > 0 ? ' &nbsp;·&nbsp; <i class="fa-solid fa-sitemap"></i> ' + subCount + ' sub' : '') +
        '</div>';

    wrap.appendChild(card);

    if (hasChildren) {
        const toggle = document.createElement('button');
        toggle.className     = 'eoc-toggle-btn';
        toggle.dataset.deptId = node.deptId;
        toggle.title   = collapsed ? 'Expand' : 'Collapse';
        toggle.innerHTML = collapsed
            ? '<i class="fa-solid fa-plus"></i>'
            : '<i class="fa-solid fa-minus"></i>';
        wrap.appendChild(toggle);
    }

    if (hasChildren && !collapsed) {
        const childRow = document.createElement('div');
        childRow.className        = 'eoc-children-row';
        childRow.dataset.parentDeptId = node.deptId;
        node.children.forEach(child => {
            const cWrap = document.createElement('div');
            cWrap.className = 'eoc-child-wrap';
            cWrap.appendChild(docRenderNode(child));
            childRow.appendChild(cWrap);
        });
        wrap.appendChild(childRow);
    }

    return wrap;
}

// ── SVG connector lines ────────────────────────────────────────────

function docDrawLines() {
    const canvas = document.getElementById('doc-canvas');
    if (!canvas) return;
    const old = document.getElementById('doc-svg');
    if (old) old.remove();

    const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    svg.id = 'doc-svg';
    svg.style.cssText = 'position:absolute;top:0;left:0;width:100%;height:100%;pointer-events:none;overflow:visible;z-index:0;';

    const canvasRect = canvas.getBoundingClientRect();

    document.querySelectorAll('.eoc-children-row[data-parent-dept-id]').forEach(row => {
        const parentId   = row.dataset.parentDeptId;
        const parentCard = canvas.querySelector('.eoc-card[data-dept-id="' + parentId + '"]');
        if (!parentCard) return;
        const childCards = Array.from(
            row.querySelectorAll(':scope > .eoc-child-wrap > .eoc-node-wrap > .eoc-card')
        );
        if (!childCards.length) return;

        const pr  = parentCard.getBoundingClientRect();
        const px  = pr.left + pr.width / 2 - canvasRect.left;
        const py  = pr.bottom               - canvasRect.top;
        const gap = 24;

        const pts = childCards.map(c => {
            const r = c.getBoundingClientRect();
            return { x: r.left + r.width / 2 - canvasRect.left, y: r.top - canvasRect.top };
        });

        const onChain = parentCard.classList.contains('eoc-card--chain') ||
                        parentCard.classList.contains('eoc-card--selected');
        const lineCol = onChain ? '#3B82F6' : '#C8D8EA';
        const lineW   = onChain ? '2.5'     : '1.5';

        function mkLine(x1, y1, x2, y2) {
            const el = document.createElementNS('http://www.w3.org/2000/svg', 'line');
            el.setAttribute('x1', x1); el.setAttribute('y1', y1);
            el.setAttribute('x2', x2); el.setAttribute('y2', y2);
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

// ── Highlight ──────────────────────────────────────────────────────

function docApplyHighlight() {
    const cards = document.querySelectorAll('.doc-dept-card');
    cards.forEach(c => c.classList.remove('eoc-card--selected','eoc-card--chain','eoc-card--sub','eoc-card--dimmed'));

    if (!docFocusId && !docSelectedId) return;
    const focusId = docFocusId || docSelectedId;
    const chain   = docReportingChain(focusId);
    const subs    = docAllSubDepts(focusId);

    cards.forEach(c => {
        const id = c.dataset.deptId;
        if (id === focusId)               c.classList.add('eoc-card--selected');
        else if (chain.includes(id))       c.classList.add('eoc-card--chain');
        else if (subs.includes(id))        c.classList.add('eoc-card--sub');
        else                               c.classList.add('eoc-card--dimmed');
    });

    docDrawLines();
}

// ── Zoom / pan ─────────────────────────────────────────────────────

function docApplyTransform() {
    const canvas = document.getElementById('doc-canvas');
    if (canvas) {
        canvas.style.transform       = `translate(${docPanX}px,${docPanY}px) scale(${docZoom})`;
        canvas.style.transformOrigin = '0 0';
    }
    const lbl = document.getElementById('doc-zoom-level');
    if (lbl) lbl.textContent = Math.round(docZoom * 100) + '%';
}

function docResetView() {
    setTimeout(() => {
        const viewport = document.getElementById('doc-viewport');
        const canvas   = document.getElementById('doc-canvas');
        if (!viewport || !canvas) return;
        const vw = viewport.clientWidth;
        const ch = canvas.scrollWidth;
        docZoom = 1;
        docPanX = Math.max(0, (vw - ch) / 2);
        docPanY = 40;
        docApplyTransform();
    }, 80);
}

function docSetupZoomPan() {
    const viewport = document.getElementById('doc-viewport');
    if (!viewport || viewport._docReady) return;
    viewport._docReady = true;

    viewport.addEventListener('wheel', e => {
        e.preventDefault();
        const factor  = e.deltaY > 0 ? 0.9 : 1.1;
        const newZoom = Math.max(0.25, Math.min(2.5, docZoom * factor));
        const rect    = viewport.getBoundingClientRect();
        const mx = e.clientX - rect.left;
        const my = e.clientY - rect.top;
        docPanX = mx - (mx - docPanX) * (newZoom / docZoom);
        docPanY = my - (my - docPanY) * (newZoom / docZoom);
        docZoom = newZoom;
        docApplyTransform();
    }, { passive: false });

    viewport.addEventListener('mousedown', e => {
        if (e.target.closest('.eoc-card') || e.target.closest('.eoc-toggle-btn')) return;
        docDragging  = true;
        docDragStart = { x: e.clientX, y: e.clientY, px: docPanX, py: docPanY };
        viewport.style.cursor = 'grabbing';
        e.preventDefault();
    });
    document.addEventListener('mousemove', e => {
        if (!docDragging) return;
        docPanX = docDragStart.px + (e.clientX - docDragStart.x);
        docPanY = docDragStart.py + (e.clientY - docDragStart.y);
        docApplyTransform();
    });
    document.addEventListener('mouseup', () => {
        if (!docDragging) return;
        docDragging = false;
        const vp = document.getElementById('doc-viewport');
        if (vp) vp.style.cursor = 'grab';
    });
}

// ── Details panel ──────────────────────────────────────────────────

function docShowDetails(deptId) {
    const dept  = docMap[deptId];
    if (!dept) return;
    docSelectedId = deptId;

    const panel = document.getElementById('doc-details-panel');
    const body  = document.getElementById('doc-details-body');
    if (!panel || !body) return;

    const color    = docColor(deptId);
    const initial  = (dept.name || '?').charAt(0).toUpperCase();
    const headEmp  = dept.headId ? employees.find(e => e.employeeId === dept.headId) : null;
    const headName = headEmp ? headEmp.name : (dept.headId || '—');
    const deptEmps = employees.filter(e => e.departmentId === deptId);
    const empCount = deptEmps.length;
    const subDepts = (docMap[deptId]?.children || []).map(c => c.name);
    const parentName = dept.parentDeptId && docMap[dept.parentDeptId]
        ? docMap[dept.parentDeptId].name : 'Top Level';
    const chain    = docReportingChain(deptId);

    const chainHtml = chain.map(id => {
        const n = docMap[id];
        return n ? '<span class="eoc-chain-pill">' + escHtml(n.name) + '</span>' : '';
    }).join('<i class="fa-solid fa-angle-right eoc-chain-arrow"></i>');

    function detRow(icon, label, value) {
        return '<div class="eoc-det-row">' +
            '<div class="eoc-det-icon"><i class="fa-solid fa-' + icon + '"></i></div>' +
            '<div><div class="eoc-det-label">' + label + '</div>' +
            '<div class="eoc-det-value">' + escHtml(String(value)) + '</div></div>' +
            '</div>';
    }

    // Build employees list HTML
    const empListHtml = empCount === 0
        ? '<span class="eoc-det-value">None</span>'
        : '<div class="eoc-det-value">' + empCount + ' member' + (empCount !== 1 ? 's' : '') + '</div>' +
          '<div class="doc-emp-list">' +
          deptEmps.map(e =>
              '<div class="doc-emp-list-item" data-emp-id="' + escHtml(e.employeeId) + '" title="View ' + escHtml(e.name) + '\'s details">' +
                  '<span class="doc-emp-list-name">' + escHtml(e.name) + '</span>' +
                  '<span class="doc-emp-list-id">' + escHtml(e.employeeId) + '</span>' +
              '</div>'
          ).join('') +
          '</div>';

    const empRowHtml =
        '<div class="eoc-det-row">' +
            '<div class="eoc-det-icon"><i class="fa-solid fa-users"></i></div>' +
            '<div style="flex:1;min-width:0;"><div class="eoc-det-label">Employees</div>' +
            empListHtml +
            '</div>' +
        '</div>';

    body.innerHTML =
        '<div class="eoc-det-hero">' +
            '<div class="eoc-det-avatar" style="background:' + color.avatar + ';">' + initial + '</div>' +
            '<div class="eoc-det-name">'  + escHtml(dept.name)   + '</div>' +
            '<div class="eoc-det-desg" style="color:#888;">Department</div>' +
            '<div class="eoc-det-id">'    + escHtml(dept.deptId) + '</div>' +
        '</div>' +
        '<div class="eoc-det-grid">' +
            detRow('user-tie',      'Department Head',  headName) +
            detRow('sitemap',       'Parent',           parentName) +
            empRowHtml +
            detRow('code-branch',   'Sub-Departments',  subDepts.length > 0 ? subDepts.join(', ') : 'None') +
            detRow('calendar-plus', 'Start Date',       formatDateDisplay(dept.startDate)) +
            detRow('calendar-xmark','End Date',         formatDateDisplay(dept.endDate)) +
        '</div>' +
        (chain.length > 1
            ? '<div class="eoc-det-section"><div class="eoc-det-section-title"><i class="fa-solid fa-route"></i> Hierarchy Chain</div>' +
              '<div class="eoc-chain-row">' + chainHtml + '</div></div>'
            : '') +
        '<div class="eoc-det-actions">' +
            '<button class="oc-btn oc-btn-primary btn-focus-mode" onclick="docFocusOn(\'' + deptId + '\')"><i class="fa-solid fa-crosshairs"></i> Focus on this dept</button>' +
        '</div>';

    panel.classList.add('eoc-details-panel--open');
    docApplyHighlight();
}

// ── Employee popover (from dept details panel) ─────────────────────

function docShowEmpPopover(empId, triggerEl) {
    const emp = employees.find(e => e.employeeId === empId);
    if (!emp) return;

    const popover  = document.getElementById('doc-emp-popover');
    const body     = document.getElementById('doc-emp-popover-body');
    const backdrop = document.getElementById('doc-emp-popover-backdrop');
    if (!popover || !body || !backdrop) return;

    // ── Gather data ────────────────────────────────
    const initial     = (emp.name || '?').charAt(0).toUpperCase();
    const avatarColor = getAvatarColor(emp.name);
    const deptObj     = emp.departmentId
        ? (JSON.parse(localStorage.getItem('prowess-departments') || '[]')
            .find(d => d.deptId === emp.departmentId))
        : null;
    const deptName = deptObj ? deptObj.name : (emp.departmentId || '—');
    const _popLocObj  = emp.workLocationId
        ? plVals().find(function(v) { return v.picklistId === 'LOCATION' && String(v.id) === String(emp.workLocationId); })
        : null;
    const popLocName  = _popLocObj ? _popLocObj.value : '—';

    function popRow(iconCls, label, value) {
        return '<div class="dep-pop-row">' +
            '<div class="dep-pop-row-icon"><i class="fa-solid fa-' + iconCls + '"></i></div>' +
            '<div><div class="dep-pop-row-label">' + label + '</div>' +
            '<div class="dep-pop-row-value">' + escHtml(String(value)) + '</div></div>' +
            '</div>';
    }

    const avatarContent = emp.photo
        ? '<img src="' + emp.photo + '" alt="' + escHtml(emp.name) + '" style="width:100%;height:100%;object-fit:cover;border-radius:50%;" />'
        : initial;

    body.innerHTML =
        '<div class="dep-pop-hero">' +
            '<div class="dep-pop-avatar" style="background:' + (emp.photo ? 'transparent' : avatarColor) + ';">' + avatarContent + '</div>' +
            '<div class="dep-pop-name">'  + escHtml(emp.name) + ' <span style="opacity:.7;font-weight:500;font-size:13px;">(' + escHtml(emp.employeeId) + ')</span></div>' +
        '</div>' +
        '<div class="dep-pop-body">' +
            popRow('id-badge',        'Designation', resolveRefLabel(emp.designation, 'prowess-designations') || '—') +
            popRow('sitemap',         'Department',  deptName) +
            popRow('location-dot',    'Location',    popLocName) +
            popRow('envelope',        'Email',       emp.businessEmail || '—') +
            popRow('phone',           'Mobile No',   emp.mobile || '—') +
        '</div>';

    // ── Position near trigger ──────────────────────
    popover.style.display = 'block';
    backdrop.style.display = 'block';

    const tRect  = triggerEl.getBoundingClientRect();
    const pW     = popover.offsetWidth  || 300;
    const pH     = popover.offsetHeight || 420;
    const vw     = window.innerWidth;
    const vh     = window.innerHeight;
    const margin = 10;

    // Prefer left of the details panel; fall back to right
    let left = tRect.left - pW - margin;
    if (left < margin) left = tRect.right + margin;
    if (left + pW > vw - margin) left = Math.max(margin, vw - pW - margin);

    let top = tRect.top + tRect.height / 2 - pH / 2;
    if (top < margin)              top = margin;
    if (top + pH > vh - margin)    top = vh - pH - margin;

    popover.style.left = left + 'px';
    popover.style.top  = top  + 'px';
}

function docCloseEmpPopover() {
    const popover  = document.getElementById('doc-emp-popover');
    const backdrop = document.getElementById('doc-emp-popover-backdrop');
    if (popover)  popover.style.display  = 'none';
    if (backdrop) backdrop.style.display = 'none';
}

// Wire up popover events (once)
(function docSetupEmpPopover() {
    // Delegate clicks on employee list items inside the dept details panel
    document.addEventListener('click', function (e) {
        const item = e.target.closest('.doc-emp-list-item[data-emp-id]');
        if (item) {
            e.stopPropagation();
            docShowEmpPopover(item.dataset.empId, item);
            return;
        }
        // Close button
        if (e.target.closest('#doc-emp-popover-close')) {
            docCloseEmpPopover();
            return;
        }
        // Backdrop click closes
        if (e.target.id === 'doc-emp-popover-backdrop') {
            docCloseEmpPopover();
        }
    });
    // Escape key closes
    document.addEventListener('keydown', function (e) {
        if (e.key === 'Escape') docCloseEmpPopover();
    });
})();

// ── Focus mode ─────────────────────────────────────────────────────

function docFocusOn(deptId) {
    docFocusId = deptId;
    const dept = docMap[deptId];
    if (!dept) return;

    const bar    = document.getElementById('doc-focus-bar');
    const nameEl = document.getElementById('doc-focus-name');
    if (bar)    bar.style.display  = 'flex';
    if (nameEl) nameEl.textContent = dept.name;

    docReportingChain(deptId).forEach(id => docCollapsed.delete(id));
    docAllSubDepts(deptId).forEach(id => docCollapsed.delete(id));

    docRenderOrgChart();
    docApplyHighlight();

    setTimeout(() => {
        const card = document.querySelector('.doc-dept-card[data-dept-id="' + deptId + '"]');
        if (card) card.scrollIntoView({ behavior: 'smooth', block: 'center', inline: 'center' });
    }, 150);
}

function docClearFocus() {
    docFocusId    = null;
    docSelectedId = null;
    const bar = document.getElementById('doc-focus-bar');
    if (bar) bar.style.display = 'none';
    const panel = document.getElementById('doc-details-panel');
    if (panel) panel.classList.remove('eoc-details-panel--open');
    docApplyHighlight();
    docDrawLines();
}

// ── Main render ─────────────────────────────────────────────────────

function docRenderOrgChart() {
    const root = document.getElementById('doc-tree-root');
    if (!root) return;

    const activeDepts   = departments.filter(d => isDeptActive(d));
    const activeDeptIds = new Set(activeDepts.map(d => d.deptId));

    if (activeDepts.length === 0) {
        const msg = departments.length === 0
            ? 'Add departments to see the org chart.'
            : `No active departments on ${formatViewDate()}.`;
        root.innerHTML = '<p class="no-data" style="padding:40px;text-align:center;">' + msg + '</p>';
        return;
    }

    // Apply search filter if active
    const searchQ = (document.getElementById('doc-search')?.value || '').trim().toLowerCase();
    let deptList = activeDepts;
    if (searchQ) {
        const matched = new Set(
            activeDepts
                .filter(d => d.name.toLowerCase().includes(searchQ) || d.deptId.toLowerCase().includes(searchQ))
                .map(d => d.deptId)
        );
        // Include ancestors so tree is coherent
        matched.forEach(id => {
            docReportingChain(id).forEach(aid => matched.add(aid));
        });
        deptList = activeDepts.filter(d => matched.has(d.deptId));
    }

    docBuildTree(deptList);

    root.innerHTML = '';

    if (docRoots.length === 0) {
        root.innerHTML = '<p class="no-data" style="padding:40px;text-align:center;">No matching departments.</p>';
        return;
    }

    const rootRow = document.createElement('div');
    rootRow.className = 'eoc-roots-row';

    docRoots.forEach(node => {
        const wrap = document.createElement('div');
        wrap.className = 'eoc-root-wrap';
        wrap.appendChild(docRenderNode(node));
        rootRow.appendChild(wrap);
    });

    root.appendChild(rootRow);

    requestAnimationFrame(() => {
        docDrawLines();
        docApplyHighlight();
    });
}

// ── Event wiring ────────────────────────────────────────────────────

(function docSetupEvents() {

    // Card click → details; double-click → focus
    document.addEventListener('click', e => {
        const card = e.target.closest('.doc-dept-card');
        if (card) { docShowDetails(card.dataset.deptId); return; }

        const toggle = e.target.closest('.eoc-toggle-btn[data-dept-id]');
        if (toggle) {
            const id = toggle.dataset.deptId;
            if (docCollapsed.has(id)) docCollapsed.delete(id);
            else docCollapsed.add(id);
            docRenderOrgChart();
            return;
        }

        const detClose = e.target.closest('#doc-details-close');
        if (detClose) {
            document.getElementById('doc-details-panel').classList.remove('eoc-details-panel--open');
            docSelectedId = null;
            docApplyHighlight();
            docDrawLines();
        }
    });

    document.addEventListener('dblclick', e => {
        const card = e.target.closest('.doc-dept-card');
        if (card) docFocusOn(card.dataset.deptId);
    });

    // Expand / Collapse All
    document.getElementById('doc-expand-all')?.addEventListener('click', () => {
        docCollapsed.clear();
        docRenderOrgChart();
    });
    document.getElementById('doc-collapse-all')?.addEventListener('click', () => {
        Object.keys(docMap).forEach(id => {
            if (docMap[id].children.length > 0) docCollapsed.add(id);
        });
        docRenderOrgChart();
    });

    // Zoom buttons
    document.getElementById('doc-zoom-in')?.addEventListener('click', () => {
        docZoom = Math.min(2.5, docZoom * 1.2); docApplyTransform();
    });
    document.getElementById('doc-zoom-out')?.addEventListener('click', () => {
        docZoom = Math.max(0.25, docZoom / 1.2); docApplyTransform();
    });
    document.getElementById('doc-zoom-reset')?.addEventListener('click', () => {
        docZoom = 1; docPanX = 0; docPanY = 0;
        docApplyTransform();
        docResetView();
    });

    // Search
    const docSearchEl = document.getElementById('doc-search');
    const docClearEl  = document.getElementById('doc-search-clear');
    if (docSearchEl) {
        docSearchEl.addEventListener('input', function () {
            const q = this.value.trim();
            if (docClearEl) docClearEl.style.display = q ? 'flex' : 'none';
            docRenderOrgChart();
            setTimeout(docResetView, 80);
        });
    }
    if (docClearEl) {
        docClearEl.addEventListener('click', () => {
            if (docSearchEl) docSearchEl.value = '';
            docClearEl.style.display = 'none';
            docClearFocus();
            docRenderOrgChart();
        });
    }

    // Focus bar — clear
    document.getElementById('doc-focus-clear')?.addEventListener('click', () => {
        if (docSearchEl) docSearchEl.value = '';
        if (docClearEl)  docClearEl.style.display = 'none';
        docClearFocus();
        docRenderOrgChart();
    });

    // Re-draw lines on resize when dept tab is active
    window.addEventListener('resize', () => {
        if (document.getElementById('tab-departments')?.classList.contains('active')) {
            docDrawLines();
        }
    });

    // Tab activation → setup zoom/pan
    document.querySelectorAll('.tab-item[data-tab="departments"]').forEach(item => {
        item.addEventListener('click', () => {
            docSetupZoomPan();
            setTimeout(docResetView, 120);
        });
    });

})();

// ═══════════════════════════════════════════════════════════════════════════
// ── EMPLOYEE VIEW PANEL ──────────────────────────────────────────────────
//
//  Architecture:
//  • EV_TABS array drives tab order — add a new entry to add a new tab,
//    no other code changes required.
//  • switchEmpViewTab(id) dispatches to a render function map; each render
//    function receives only the employee object and the content container.
//  • All data is read directly from the employee object and existing
//    localStorage keys — no new data models.
//  • Passport tab displays emp.passportCountry / passportNumber / etc.
//    (dedicated fields), reusing getPassportAlertLevel() from the existing
//    passport-alert system.
//  • Identification tab resolves countryId → name and idTypeId → name via
//    prowess-id-countries and prowess-id-types, the same keys used by the
//    employee form.
// ═══════════════════════════════════════════════════════════════════════════

// ── Tab registry — extend here to add new tabs ──────────────────────────────
var EV_TABS = [
    { id: 'personal',       label: 'Personal',        icon: 'fa-circle-user'    },
    { id: 'contact',        label: 'Contact',          icon: 'fa-phone'          },
    { id: 'address',        label: 'Address',          icon: 'fa-location-dot'   },
    { id: 'passport',       label: 'Passport',         icon: 'fa-passport'       },
    { id: 'identification', label: 'Identification',   icon: 'fa-id-card-clip'   },
    { id: 'emergency',      label: 'Emergency Contact', icon: 'fa-phone-volume'  },
    { id: 'employment',     label: 'Employment',       icon: 'fa-briefcase'      },
];

var evCurrentEmp = null;
var evCurrentTab = 'personal';

// ── Open / close ─────────────────────────────────────────────────────────────

function openEmpView(empId) {
    var emp = employees.find(function(e) { return e.id === empId; });
    if (!emp) return;
    evCurrentEmp = emp;
    evCurrentTab = 'personal';

    evRenderHeader(emp);
    evRenderTabNav();
    switchEmpViewTab('personal');

    document.getElementById('ev-overlay').classList.add('ev-open');
    document.body.style.overflow = 'hidden';
}

function closeEmpView() {
    document.getElementById('ev-overlay').classList.remove('ev-open');
    document.body.style.overflow = '';
    evCurrentEmp = null;
}

// ── Header ───────────────────────────────────────────────────────────────────

function evRenderHeader(emp) {
    var photoEl = document.getElementById('ev-header-photo');
    var nameEl  = document.getElementById('ev-header-name');
    var metaEl  = document.getElementById('ev-header-meta');

    // Photo or initial
    if (emp.photo) {
        photoEl.innerHTML = '<img src="' + emp.photo + '" alt="' + (emp.name || '') + '" />';
    } else {
        var initial = emp.name ? emp.name.charAt(0).toUpperCase() : '?';
        photoEl.innerHTML = '<span style="font-size:22px;color:rgba(255,255,255,0.9);">' + initial + '</span>';
    }

    nameEl.textContent = emp.name || '—';

    metaEl.innerHTML =
        '<span><i class="fa-solid fa-id-card fa-fw"></i>' + (emp.employeeId || '—') + '</span>' +
        '<span><i class="fa-solid fa-id-badge fa-fw"></i>' + (resolveRefLabel(emp.designation, 'prowess-designations') || '—') + '</span>' +
        '<span><i class="fa-solid fa-sitemap fa-fw"></i>' + evDeptName(emp.departmentId) + '</span>';
}

// ── Tab navigation ───────────────────────────────────────────────────────────

function evRenderTabNav() {
    var nav = document.getElementById('ev-tab-nav');
    nav.innerHTML = '';
    EV_TABS.forEach(function(tab) {
        var btn = document.createElement('button');
        btn.className = 'ev-tab' + (tab.id === evCurrentTab ? ' ev-tab-active' : '');
        btn.setAttribute('role', 'tab');
        btn.dataset.tab = tab.id;
        btn.innerHTML = '<i class="fa-solid ' + tab.icon + ' fa-fw"></i>' + tab.label;
        btn.addEventListener('click', function() { switchEmpViewTab(tab.id); });
        nav.appendChild(btn);
    });
}

// switchEmpViewTab — update active tab indicator and render content
function switchEmpViewTab(tabId) {
    evCurrentTab = tabId;

    // Highlight correct tab button
    document.querySelectorAll('#ev-tab-nav .ev-tab').forEach(function(btn) {
        btn.classList.toggle('ev-tab-active', btn.dataset.tab === tabId);
    });

    // Dispatch to render function
    var renderMap = {
        personal:       evTabPersonal,
        contact:        evTabContact,
        address:        evTabAddress,
        passport:       evTabPassport,
        identification: evTabIdentification,
        emergency:      evTabEmergency,
        employment:     evTabEmployment,
    };

    var content = document.getElementById('ev-content');
    content.innerHTML = '';
    var fn = renderMap[tabId];
    if (fn && evCurrentEmp) fn(evCurrentEmp, content);
    content.scrollTop = 0;
}

// ── Shared helpers ───────────────────────────────────────────────────────────

// Render a labelled field; shows italic placeholder if value is absent
function evField(label, value) {
    var displayVal = (value !== null && value !== undefined && value !== '' && value !== '—')
        ? '<span class="ev-field-value">' + value + '</span>'
        : '<span class="ev-field-value ev-empty">Not provided</span>';
    return '<div class="ev-field"><div class="ev-field-label">' + label + '</div>' + displayVal + '</div>';
}

function evSectionTitle(icon, text) {
    return '<div class="ev-section-title"><i class="fa-solid ' + icon + '"></i>' + text + '</div>';
}

// Resolve department name from ID using existing prowess-departments key
function evDeptName(deptId) {
    if (!deptId) return '—';
    var depts = JSON.parse(localStorage.getItem('prowess-departments')) || [];
    var dept  = depts.find(function(d) { return d.deptId === deptId; });
    return dept ? dept.name : deptId;
}

// Resolve manager display name from managerId (matches employeeId or id)
function evManagerName(managerId) {
    if (!managerId) return '—';
    var mgr = employees.find(function(e) {
        return e.employeeId === managerId || String(e.id) === String(managerId);
    });
    return mgr ? mgr.name + ' (' + mgr.employeeId + ')' : managerId;
}

// Format ISO date string to readable display
function evFmtDate(dateStr) {
    if (!dateStr) return null;
    if (dateStr === '9999-12-31') return 'Open-ended';
    var d = new Date(dateStr + 'T00:00:00');
    if (isNaN(d.getTime())) return dateStr;
    return d.toLocaleDateString('en-IN', { day: '2-digit', month: 'short', year: 'numeric' });
}

// ── Tab 1 — Personal Information ────────────────────────────────────────────
// Displays: name, employeeId, nationality, maritalStatus
// Data source: emp object (stored by employee form Section 1)

function evTabPersonal(emp, el) {
    el.innerHTML =
        evSectionTitle('fa-circle-user', 'Personal Information') +
        '<div class="ev-field-grid ev-grid-2">' +
            evField('Full Name',      emp.name) +
            evField('Employee ID',    emp.employeeId) +
            evField('Nationality',    resolveRefLabel(emp.nationality,    'prowess-nationalities')) +
            evField('Marital Status', resolveRefLabel(emp.maritalStatus,  'prowess-marital-statuses')) +
        '</div>';
}

// ── Tab 2 — Contact Information ──────────────────────────────────────────────
// Displays: mobile (pre-formatted with country code), businessEmail, personalEmail
// Data source: emp.mobile (combined), emp.businessEmail, emp.personalEmail

function evTabContact(emp, el) {
    el.innerHTML =
        evSectionTitle('fa-phone', 'Contact Information') +
        '<div class="ev-field-grid ev-grid-2">' +
            evField('Mobile No.',       emp.mobile) +
            evField('Business Email',   emp.businessEmail) +
            evField('Personal Email',   emp.personalEmail) +
        '</div>';
}

// ── Tab 3 — Address Information ──────────────────────────────────────────────
// Displays all address fields from Section 6 of employee form
// Data source: emp.addrLine1 … emp.addrCountry

function evTabAddress(emp, el) {
    el.innerHTML =
        evSectionTitle('fa-location-dot', 'Address Information') +
        '<div class="ev-field-grid ev-grid-2">' +
            evField('Address Line 1',   emp.addrLine1) +
            evField('Address Line 2',   emp.addrLine2) +
            evField('Landmark',         emp.addrLandmark) +
            evField('City',             emp.addrCity) +
            evField('District',         emp.addrDistrict) +
            evField('State',            emp.addrState) +
            evField('PIN / ZIP Code',   emp.addrPin) +
            evField('Country',          emp.addrCountry) +
        '</div>';
}

// ── Tab 4 — Passport Information ────────────────────────────────────────────
// Passport data is stored as dedicated fields on the employee object
// (passportCountry, passportNumber, passportIssueDate, passportExpiryDate).
// Reuses getPassportAlertLevel() for expiry warnings, consistent with the
// passport alert system already in place on the employee list.

function evTabPassport(emp, el) {
    var hasPassport = emp.passportNumber || emp.passportCountry;

    if (!hasPassport) {
        el.innerHTML =
            evSectionTitle('fa-passport', 'Passport Information') +
            '<div class="ev-empty-state">' +
            '<i class="fa-solid fa-passport"></i>' +
            '<p>No passport information on record.</p></div>';
        return;
    }

    // Reuse existing alert logic
    var alertHtml = '';
    if (emp.passportExpiryDate) {
        var alert = getPassportAlertLevel(emp.passportExpiryDate);
        if (alert) {
            var msg = alert.level === 'expired'
                ? '<i class="fa-solid fa-triangle-exclamation"></i> Passport expired ' + alert.days + ' day' + (alert.days !== 1 ? 's' : '') + ' ago'
                : '<i class="fa-solid fa-triangle-exclamation"></i> Expires in ' + alert.days + ' day' + (alert.days !== 1 ? 's' : '');
            alertHtml = '<div class="ev-passport-alert ' + alert.level + '">' + msg + '</div>';
        }
    }

    el.innerHTML =
        evSectionTitle('fa-passport', 'Passport Information') +
        alertHtml +
        '<div class="ev-field-grid ev-grid-2">' +
            evField('Issue Country',  emp.passportCountry) +
            evField('Passport No.',   emp.passportNumber) +
            evField('Issue Date',     evFmtDate(emp.passportIssueDate)) +
            evField('Expiry Date',    evFmtDate(emp.passportExpiryDate)) +
        '</div>';
}

// ── Tab 5 — Identification Details ──────────────────────────────────────────
// Reads emp.identifications[] and resolves countryId / idTypeId to display
// names using prowess-id-countries and prowess-id-types — the same
// localStorage keys used by the employee form identification sub-section.

function evTabIdentification(emp, el) {
    var ids     = emp.identifications || [];
    var idVals  = plVals();

    if (ids.length === 0) {
        el.innerHTML =
            evSectionTitle('fa-id-card-clip', 'Identification Details') +
            '<div class="ev-empty-state">' +
            '<i class="fa-solid fa-id-card-clip"></i>' +
            '<p>No identification records on file.</p></div>';
        return;
    }

    var rows = ids.map(function(rec) {
        var cName  = (idVals.find(function(v) { return v.picklistId === 'ID_COUNTRY' && String(v.id) === String(rec.countryId); }) || {}).value || '—';
        var tName  = (idVals.find(function(v) { return v.picklistId === 'ID_TYPE'    && String(v.id) === String(rec.idTypeId);  }) || {}).value || '—';
        var expiry = evFmtDate(rec.expiryDate) || '—';
        var status = rec.isPrimary === 'primary'
            ? '<span class="ev-badge ev-badge-primary">⭐ Primary</span>'
            : '<span style="color:#8a9ab0;font-size:12px;">Secondary</span>';
        return '<tr>' +
            '<td>' + cName + '</td>' +
            '<td>' + tName + '</td>' +
            '<td class="ev-mono">' + (rec.idNumber || '—') + '</td>' +
            '<td>' + expiry + '</td>' +
            '<td>' + status + '</td>' +
        '</tr>';
    }).join('');

    el.innerHTML =
        evSectionTitle('fa-id-card-clip', 'Identification Details') +
        '<table class="ev-id-table">' +
            '<thead><tr>' +
                '<th>Country</th><th>ID Type</th>' +
                '<th>ID Number</th><th>Expiry</th><th>Status</th>' +
            '</tr></thead>' +
            '<tbody>' + rows + '</tbody>' +
        '</table>';
}

// ── Tab 6 — Emergency Contact Information ────────────────────────────────────
// Data source: emp.ecName, ecRelationship, ecPhone, ecAltPhone, ecEmail

function evTabEmergency(emp, el) {
    if (!emp.ecName && !emp.ecPhone) {
        el.innerHTML =
            evSectionTitle('fa-phone-volume', 'Emergency Contact Information') +
            '<div class="ev-empty-state">' +
            '<i class="fa-solid fa-phone-volume"></i>' +
            '<p>No emergency contact on record.</p></div>';
        return;
    }

    el.innerHTML =
        evSectionTitle('fa-phone-volume', 'Emergency Contact Information') +
        '<div class="ev-field-grid ev-grid-2">' +
            evField('Contact Name',    emp.ecName) +
            evField('Relationship',    resolveRefLabel(emp.ecRelationship, 'prowess-relationship-types')) +
            evField('Phone Number',    emp.ecPhone) +
            evField('Alternate Phone', emp.ecAltPhone) +
            evField('Email',           emp.ecEmail) +
        '</div>';
}

// ── Tab 7 — Employment Information ──────────────────────────────────────────
// Resolves departmentId → name (prowess-departments) and managerId → name
// from the in-memory employees array — same resolution used by renderEmployees()

function evTabEmployment(emp, el) {
    var today    = new Date(); today.setHours(0,0,0,0);
    var endDate  = emp.endDate ? new Date(emp.endDate) : null;
    var isActive = !endDate || emp.endDate === '9999-12-31' || endDate >= today;

    var statusBadge = isActive
        ? '<span class="ev-badge ev-badge-active"><i class="fa-solid fa-circle-dot"></i> Active</span>'
        : '<span class="ev-badge ev-badge-inactive"><i class="fa-solid fa-circle-dot"></i> Inactive</span>';

    var roleBadge =
        emp.role === 'admin'   ? '<span class="ev-badge" style="background:#f3e5f5;color:#7b1fa2;">Admin</span>' :
        emp.role === 'manager' ? '<span class="ev-badge" style="background:#e3f2fd;color:#1565c0;">Manager</span>' :
                                 '<span class="ev-badge" style="background:#f0f4fa;color:#546e7a;">Employee</span>';

    el.innerHTML =
        evSectionTitle('fa-briefcase', 'Employment Information') +
        '<div class="ev-field-grid ev-grid-2">' +
            '<div class="ev-field"><div class="ev-field-label">Status</div>'      + statusBadge + '</div>' +
            '<div class="ev-field"><div class="ev-field-label">Role</div>'        + roleBadge   + '</div>' +
            evField('Designation',    resolveRefLabel(emp.designation, 'prowess-designations')) +
            evField('Base Currency',  emp.baseCurrencyCode || '—') +
            evField('Department',   evDeptName(emp.departmentId)) +
            evField('Manager',      evManagerName(emp.managerId)) +
            evField('Hire Date',    evFmtDate(emp.hireDate)) +
            evField('End Date',     evFmtDate(emp.endDate)) +
        '</div>';
}

// ── Event wiring ─────────────────────────────────────────────────────────────

// Close: backdrop click
document.getElementById('ev-overlay').addEventListener('click', function(e) {
    if (e.target === this) closeEmpView();
});

// Close: X button
document.getElementById('ev-close-btn').addEventListener('click', closeEmpView);

// Edit: open the employee's edit form and close the panel
document.getElementById('ev-edit-btn').addEventListener('click', function() {
    if (!evCurrentEmp) return;
    var id = evCurrentEmp.id;
    closeEmpView();
    // Small delay so the overlay transition completes before scrolling the form
    setTimeout(function() {
        var editBtn = document.querySelector('.btn-edit[data-id="' + id + '"]');
        if (editBtn) editBtn.click();
    }, 200);
});

// Close: Escape key
document.addEventListener('keydown', function(e) {
    if (e.key === 'Escape' && document.getElementById('ev-overlay').classList.contains('ev-open')) {
        closeEmpView();
    }
});

// ═══════════════════════════════════════════════════════════════════
// ── CURRENCIES – managed via generic Reference Data module ───────
// Populate functions use plQuery('CURRENCY') from the picklist engine
// ═══════════════════════════════════════════════════════════════════

function populateCurrencyDropdowns() {
    var items = plQuery('CURRENCY', {activeOnly: true});

    // Base currency on employee form
    var bcSel = document.getElementById('emp-base-currency');
    if (bcSel) {
        var cur = bcSel.value;
        bcSel.innerHTML = '<option value="">-- Select Currency --</option>';
        items.forEach(function(item) {
            var code   = item.meta && item.meta.code   ? item.meta.code   : item.value;
            var symbol = item.meta && item.meta.symbol ? item.meta.symbol : '';
            var o = document.createElement('option');
            o.value = code;
            o.textContent = code + ' \u2013 ' + item.value + (symbol ? ' (' + symbol + ')' : '');
            bcSel.appendChild(o);
        });
        bcSel.value = cur;
    }

    // Exchange rate from/to selects
    ['er-from-currency', 'er-to-currency'].forEach(function(selId) {
        var sel = document.getElementById(selId);
        if (!sel) return;
        var cur = sel.value;
        sel.innerHTML = '<option value="">-- Select --</option>';
        items.forEach(function(item) {
            var code = item.meta && item.meta.code ? item.meta.code : item.value;
            var flag = CURRENCY_FLAGS[code] || '';
            var o = document.createElement('option');
            o.value = code;
            o.textContent = (flag ? flag + ' ' : '') + code + ' \u2013 ' + item.value;
            sel.appendChild(o);
        });
        sel.value = cur;
    });
}

// ═══════════════════════════════════════════════════════════════════
// ── REFERENCE DATA MODULE (Generic Picklist UI) ──────────────────
// Page 1: Picklist directory  |  Page 2: Values for selected picklist
// ═══════════════════════════════════════════════════════════════════

var rdCurrentPicklistId = null; // which picklist is open in page 2

// ── Helpers ─────────────────────────────────────────────────────

function rdPicklistValCount(plId) {
    return plVals().filter(function(v) { return v.picklistId === plId; }).length;
}

function rdPicklistDesc(plId) {
    var pls = plGet();
    var pl  = pls.find(function(p) { return p.id === plId; });
    return pl ? pl.description : plId;
}

function rdParentLabel(parentPicklistId) {
    if (!parentPicklistId) return '—';
    return rdPicklistDesc(parentPicklistId);
}

// ── Page 1: Picklist Directory ───────────────────────────────────

function rdRenderPage1() {
    document.getElementById('rd-page1').style.display = '';
    document.getElementById('rd-page2').style.display = 'none';
    rdCurrentPicklistId = null;

    var pls   = plGet();
    var tbody = document.getElementById('rd-pl-tbody');
    if (!tbody) return;

    tbody.innerHTML = '';
    if (!pls.length) {
        tbody.innerHTML = '<tr><td colspan="5" class="rd-empty">No picklists defined.</td></tr>';
        return;
    }

    pls.forEach(function(pl) {
        var count  = rdPicklistValCount(pl.id);
        var parent = rdParentLabel(pl.parentPicklistId);
        var tr = document.createElement('tr');
        tr.innerHTML =
            '<td><span class="rd-id-badge">' + pl.id + '</span></td>' +
            '<td>' + pl.description + '</td>' +
            '<td>' + parent + '</td>' +
            '<td><span class="rd-count-badge">' + count + '</span></td>' +
            '<td class="rd-actions">' +
                '<button class="rd-btn-values" data-plid="' + pl.id + '" title="Manage Values">' +
                    '<i class="fa-solid fa-list"></i> Values' +
                '</button>' +
                (pl.system ? '' :
                    '<button class="rd-btn-edit-pl" data-plid="' + pl.id + '" title="Edit Picklist"><i class="fa-solid fa-pen-to-square"></i></button>' +
                    '<button class="rd-btn-del-pl"  data-plid="' + pl.id + '" title="Delete Picklist"><i class="fa-solid fa-trash"></i></button>'
                ) +
            '</td>';
        tbody.appendChild(tr);
    });
}

// Page 1 form: Add / Edit picklist definition
document.getElementById('rd-add-pl-btn').addEventListener('click', function() {
    rdShowPlForm(null);
});

document.getElementById('rd-pl-cancel-btn').addEventListener('click', function() {
    rdHidePlForm();
});

document.getElementById('rd-pl-save-btn').addEventListener('click', function() {
    var editId  = document.getElementById('rd-pl-edit-id').value.trim();
    var newId   = document.getElementById('rd-pl-id-input').value.trim().toUpperCase().replace(/\s+/g, '_');
    var desc    = document.getElementById('rd-pl-desc-input').value.trim();
    var parentId = document.getElementById('rd-pl-parent-select').value;
    if (!newId || !desc) { alert('Picklist ID and Description are required.'); return; }

    var pls = plGet();
    if (editId) {
        // Edit existing (non-system)
        var updated = pls.map(function(p) {
            return p.id === editId ? Object.assign({}, p, {description: desc, parentPicklistId: parentId || null}) : p;
        });
        plSave(updated);
    } else {
        // Add new
        if (pls.find(function(p) { return p.id === newId; })) {
            alert('A picklist with this ID already exists.');
            return;
        }
        pls.push({id: newId, description: desc, parentPicklistId: parentId || null, system: false, metaFields: []});
        plSave(pls);
    }
    rdHidePlForm();
    rdRenderPage1();
});

// Page 1 table: Values / Edit / Delete picklist buttons
document.getElementById('rd-pl-tbody').addEventListener('click', function(e) {
    var valBtn  = e.target.closest('.rd-btn-values');
    var editBtn = e.target.closest('.rd-btn-edit-pl');
    var delBtn  = e.target.closest('.rd-btn-del-pl');

    if (valBtn) {
        rdOpenPage2(valBtn.getAttribute('data-plid'));
    }
    if (editBtn) {
        var plId = editBtn.getAttribute('data-plid');
        rdShowPlForm(plId);
    }
    if (delBtn) {
        var plId = delBtn.getAttribute('data-plid');
        var count = rdPicklistValCount(plId);
        if (count > 0) {
            if (!confirm('Delete picklist "' + plId + '" and all ' + count + ' of its values?')) return;
            var vals = plVals().filter(function(v) { return v.picklistId !== plId; });
            plSaveVals(vals);
        } else {
            if (!confirm('Delete picklist "' + plId + '"?')) return;
        }
        var pls = plGet().filter(function(p) { return p.id !== plId; });
        plSave(pls);
        rdRenderPage1();
    }
});

function rdShowPlForm(editPlId) {
    var wrap    = document.getElementById('rd-pl-form-wrap');
    var idInput = document.getElementById('rd-pl-id-input');
    var descIn  = document.getElementById('rd-pl-desc-input');
    var parentSel = document.getElementById('rd-pl-parent-select');

    // Populate parent picklist select
    parentSel.innerHTML = '<option value="">\u2014 None \u2014</option>';
    plGet().forEach(function(p) {
        if (!editPlId || p.id !== editPlId) {
            var o = document.createElement('option');
            o.value = p.id; o.textContent = p.description + ' (' + p.id + ')';
            parentSel.appendChild(o);
        }
    });

    if (editPlId) {
        var pl = plGet().find(function(p) { return p.id === editPlId; });
        if (!pl) return;
        document.getElementById('rd-pl-edit-id').value = editPlId;
        idInput.value = editPlId;
        idInput.readOnly = true;
        descIn.value  = pl.description;
        parentSel.value = pl.parentPicklistId || '';
    } else {
        document.getElementById('rd-pl-edit-id').value = '';
        idInput.value = '';
        idInput.readOnly = false;
        descIn.value  = '';
        parentSel.value = '';
    }

    wrap.style.display = '';
    descIn.focus();
}

function rdHidePlForm() {
    document.getElementById('rd-pl-form-wrap').style.display = 'none';
    document.getElementById('rd-pl-edit-id').value = '';
    document.getElementById('rd-pl-id-input').value = '';
    document.getElementById('rd-pl-id-input').readOnly = false;
    document.getElementById('rd-pl-desc-input').value = '';
}

// ── Page 2: Values for selected picklist ─────────────────────────

function rdOpenPage2(plId) {
    rdCurrentPicklistId = plId;
    document.getElementById('rd-page1').style.display = 'none';
    document.getElementById('rd-page2').style.display = '';

    var pl = plGet().find(function(p) { return p.id === plId; });
    document.getElementById('rd-page2-title').textContent = pl ? pl.description : plId;

    // Hide value form
    rdHideValForm();

    // Parent filter
    rdSetupParentFilter(plId, pl);

    // Render values table
    rdRenderPage2Values();
}

function rdSetupParentFilter(plId, pl) {
    var filterBar = document.getElementById('rd-parent-filter');
    var filterSel = document.getElementById('rd-parent-filter-sel');
    if (pl && pl.parentPicklistId) {
        // Populate filter options from parent picklist values
        var parentVals = plQuery(pl.parentPicklistId);
        filterSel.innerHTML = '<option value="">All</option>';
        parentVals.forEach(function(pv) {
            var o = document.createElement('option');
            o.value = pv.id; o.textContent = pv.value;
            filterSel.appendChild(o);
        });
        filterBar.style.display = '';
    } else {
        filterBar.style.display = 'none';
        filterSel.value = '';
    }
}

document.getElementById('rd-parent-filter-sel').addEventListener('change', function() {
    rdRenderPage2Values();
});

function rdRenderPage2Values() {
    var plId = rdCurrentPicklistId;
    var pl   = plGet().find(function(p) { return p.id === plId; });
    if (!pl) return;

    var filterVal = document.getElementById('rd-parent-filter-sel').value;
    var allVals   = plVals().filter(function(v) { return v.picklistId === plId; });

    if (filterVal) {
        allVals = allVals.filter(function(v) { return String(v.parentValueId) === String(filterVal); });
    }

    // Sort
    allVals = allVals.slice().sort(function(a, b) { return (a.value || '').localeCompare(b.value || ''); });

    // Build header
    var thead = document.getElementById('rd-val-thead');
    var hasParent = !!pl.parentPicklistId;
    var metaFields = pl.metaFields || [];
    var cols = ['Value ID', 'Value'];
    if (hasParent) cols.push('Parent Value');
    metaFields.forEach(function(f) { cols.push(f.label); });
    cols.push('Status', 'Actions');
    thead.innerHTML = '<tr>' + cols.map(function(c) { return '<th>' + c + '</th>'; }).join('') + '</tr>';

    // Build rows
    var tbody = document.getElementById('rd-val-tbody');
    tbody.innerHTML = '';

    if (!allVals.length) {
        tbody.innerHTML = '<tr><td colspan="' + cols.length + '" class="rd-empty">No values defined.</td></tr>';
        return;
    }

    allVals.forEach(function(val) {
        var isActive = val.active !== false;
        var parentLabel = '';
        if (hasParent && val.parentValueId) {
            var pv = plVals().find(function(v) { return String(v.id) === String(val.parentValueId); });
            parentLabel = pv ? pv.value : '(' + val.parentValueId + ')';
        }
        var tr = document.createElement('tr');
        var cells = [
            '<td><span class="rd-id-badge">' + val.id + '</span></td>',
            '<td>' + (val.value || '') + '</td>'
        ];
        if (hasParent) {
            cells.push('<td>' + (parentLabel || '—') + '</td>');
        }
        metaFields.forEach(function(f) {
            cells.push('<td>' + ((val.meta && val.meta[f.key]) ? val.meta[f.key] : '—') + '</td>');
        });
        cells.push(
            '<td><button class="rd-toggle-btn ' + (isActive ? 'is-active' : 'is-inactive') + '" ' +
                'data-vid="' + val.id + '" title="' + (isActive ? 'Active – click to deactivate' : 'Inactive – click to activate') + '">' +
                (isActive ? 'Active' : 'Inactive') + '</button></td>',
            '<td class="rd-actions">' +
                '<button class="rd-btn-edit-val" data-vid="' + val.id + '" title="Edit"><i class="fa-solid fa-pen-to-square"></i></button>' +
                '<button class="rd-btn-del-val"  data-vid="' + val.id + '" title="Delete"><i class="fa-solid fa-trash"></i></button>' +
            '</td>'
        );
        tr.innerHTML = cells.join('');
        tbody.appendChild(tr);
    });
}

// Page 2: Back button
document.getElementById('rd-back-btn').addEventListener('click', function() {
    rdCurrentPicklistId = null;
    rdRenderPage1();
});

// Page 2: Add Value button
document.getElementById('rd-add-val-btn').addEventListener('click', function() {
    rdShowValForm(null);
});

document.getElementById('rd-val-cancel-btn').addEventListener('click', function() {
    rdHideValForm();
});

// Page 2: Value table actions (toggle / edit / delete)
document.getElementById('rd-val-tbody').addEventListener('click', function(e) {
    var toggleBtn = e.target.closest('.rd-toggle-btn');
    var editBtn   = e.target.closest('.rd-btn-edit-val');
    var delBtn    = e.target.closest('.rd-btn-del-val');

    if (toggleBtn) {
        rdToggleValue(Number(toggleBtn.getAttribute('data-vid')));
    }
    if (editBtn) {
        rdShowValForm(Number(editBtn.getAttribute('data-vid')));
    }
    if (delBtn) {
        rdDeleteValue(Number(delBtn.getAttribute('data-vid')));
    }
});

function rdToggleValue(vid) {
    var plId    = rdCurrentPicklistId;
    var pl      = plGet().find(function(p) { return p.id === plId; });
    var vals    = plVals();
    var val     = vals.find(function(v) { return v.id === vid; });
    if (!val) return;

    var willDeactivate = val.active !== false;
    if (willDeactivate) {
        // Check for children that are active
        var hasActiveChildren = vals.some(function(v) {
            return String(v.parentValueId) === String(vid) && v.active !== false;
        });
        if (hasActiveChildren) {
            if (!confirm('Deactivating "' + val.value + '" will also deactivate all its child values. Continue?')) return;
            // Cascade deactivate children
            vals = vals.map(function(v) {
                if (String(v.parentValueId) === String(vid)) return Object.assign({}, v, {active: false});
                return v;
            });
        }
        // Check in-use
        if (plIsInUse(vid)) {
            if (!confirm('"' + val.value + '" is used in employee or expense records. Deactivating it will hide it from new entries but existing records will still show "(Inactive)". Continue?')) return;
        }
    }

    vals = vals.map(function(v) {
        return v.id === vid ? Object.assign({}, v, {active: !willDeactivate}) : v;
    });
    plSaveVals(vals);
    rdRenderPage2Values();
    // Refresh employee form dropdowns that use this picklist
    rdRefreshDropdowns(plId);
}

function rdDeleteValue(vid) {
    var vals = plVals();
    var val  = vals.find(function(v) { return v.id === vid; });
    if (!val) return;

    if (plIsInUse(vid)) {
        alert('"' + val.value + '" is currently used in employee or expense records and cannot be deleted. Deactivate it instead.');
        return;
    }
    // Check for children
    var children = vals.filter(function(v) { return String(v.parentValueId) === String(vid); });
    var msg = children.length
        ? 'Delete "' + val.value + '" and its ' + children.length + ' child value(s)?'
        : 'Delete "' + val.value + '"?';
    if (!confirm(msg)) return;

    var toDelete = [vid];
    children.forEach(function(c) { toDelete.push(c.id); });
    vals = vals.filter(function(v) { return toDelete.indexOf(v.id) === -1; });
    plSaveVals(vals);
    rdRenderPage2Values();
    rdRefreshDropdowns(rdCurrentPicklistId);
}

// Page 2: Show value add/edit form
function rdShowValForm(editVid) {
    var plId      = rdCurrentPicklistId;
    var pl        = plGet().find(function(p) { return p.id === plId; });
    var metaFields = pl ? (pl.metaFields || []) : [];
    var wrap      = document.getElementById('rd-val-form-wrap');
    var fieldsDiv = document.getElementById('rd-val-form-fields');

    var editVal = null;
    if (editVid !== null) {
        editVal = plVals().find(function(v) { return v.id === editVid; });
    }

    // Build form fields dynamically
    var html = '';

    // Parent value select (only if picklist has a parent)
    if (pl && pl.parentPicklistId) {
        var parentVals = plQuery(pl.parentPicklistId, {activeOnly: true});
        html += '<div class="form-group">';
        html += '<label>Parent Value</label>';
        html += '<select id="rd-val-parent-sel" required>';
        html += '<option value="">-- Select --</option>';
        parentVals.forEach(function(pv) {
            var sel = editVal && String(editVal.parentValueId) === String(pv.id) ? ' selected' : '';
            html += '<option value="' + pv.id + '"' + sel + '>' + pv.value + '</option>';
        });
        html += '</select></div>';
    }

    // Value input
    html += '<div class="form-group">';
    html += '<label>Value</label>';
    html += '<input type="text" id="rd-val-value-input" value="' + (editVal ? (editVal.value || '') : '') + '" required />';
    html += '</div>';

    // Meta fields
    metaFields.forEach(function(f) {
        var metaVal = editVal && editVal.meta ? (editVal.meta[f.key] || '') : '';
        html += '<div class="form-group"' + (f.width ? ' style="max-width:' + f.width + 'px"' : '') + '>';
        html += '<label>' + f.label + '</label>';
        html += '<input type="text" id="rd-val-meta-' + f.key + '" placeholder="' + (f.placeholder || '') + '" value="' + metaVal + '"' + (f.required ? ' required' : '') + ' />';
        html += '</div>';
    });

    fieldsDiv.innerHTML = html;
    document.getElementById('rd-val-edit-id').value = editVid !== null ? editVid : '';
    wrap.style.display = '';
    var firstInput = fieldsDiv.querySelector('input, select');
    if (firstInput) firstInput.focus();
}

function rdHideValForm() {
    document.getElementById('rd-val-form-wrap').style.display = 'none';
    document.getElementById('rd-val-edit-id').value = '';
    document.getElementById('rd-val-form-fields').innerHTML = '';
}

// Page 2: Save value
document.getElementById('rd-val-save-btn').addEventListener('click', function() {
    var plId      = rdCurrentPicklistId;
    var pl        = plGet().find(function(p) { return p.id === plId; });
    var metaFields = pl ? (pl.metaFields || []) : [];
    var editVid   = document.getElementById('rd-val-edit-id').value;
    editVid = editVid ? Number(editVid) : null;

    var value = (document.getElementById('rd-val-value-input') || {}).value;
    if (!value || !value.trim()) { alert('Value is required.'); return; }
    value = value.trim();

    var parentValueId = null;
    if (pl && pl.parentPicklistId) {
        var pSel = document.getElementById('rd-val-parent-sel');
        if (!pSel || !pSel.value) { alert('Parent value is required.'); return; }
        parentValueId = Number(pSel.value);
    }

    var meta = {};
    var metaValid = true;
    metaFields.forEach(function(f) {
        var inp = document.getElementById('rd-val-meta-' + f.key);
        var v = inp ? inp.value.trim() : '';
        if (f.required && !v) { alert(f.label + ' is required.'); metaValid = false; }
        meta[f.key] = v;
    });
    if (!metaValid) return;

    var vals = plVals();
    if (editVid !== null) {
        vals = vals.map(function(v) {
            if (v.id !== editVid) return v;
            var updated = Object.assign({}, v, {value: value, parentValueId: parentValueId});
            if (metaFields.length) updated.meta = Object.assign({}, v.meta || {}, meta);
            return updated;
        });
    } else {
        var newId = plNextId();
        var newVal = {id: newId, picklistId: plId, value: value, parentValueId: parentValueId, active: true};
        if (metaFields.length) newVal.meta = meta;
        vals.push(newVal);
    }
    plSaveVals(vals);
    rdHideValForm();
    rdRenderPage2Values();
    rdRefreshDropdowns(plId);
});

// Refresh employee-form dropdowns after picklist changes
function rdRefreshDropdowns(plId) {
    if (plId === 'DESIGNATION')      populateDesignationDropdown();
    if (plId === 'NATIONALITY')      populateNationalityDropdown();
    if (plId === 'MARITAL_STATUS')   populateMaritalStatusDropdown();
    if (plId === 'RELATIONSHIP_TYPE') populateRelationshipTypeDropdown();
    if (plId === 'ID_COUNTRY')       { populateIdCountrySelects(); populateWorkCountrySelect(); }
    if (plId === 'ID_TYPE')          populateIdTypeSelect(document.getElementById('emp-id-country') ? document.getElementById('emp-id-country').value : '');
    if (plId === 'LOCATION')         populateWorkLocationSelect(document.getElementById('emp-work-country') ? document.getElementById('emp-work-country').value : '');
    if (plId === 'CURRENCY')         populateCurrencyDropdowns();
}

// ═══════════════════════════════════════════════════════════════════
// ── EXCHANGE RATES ──────────────────────────────────────────────
// prowess-exchange-rates: [{id, fromCode, toCode, rate, effectiveDate}]
// ═══════════════════════════════════════════════════════════════════

// ── Toast notification system ────────────────────────────────────
function showErToast(message, type, duration) {
    type     = type     || 'success';
    duration = duration || 3000;
    var container = document.getElementById('er-toast-container');
    if (!container) return;

    var toast = document.createElement('div');
    toast.className = 'er-toast er-toast--' + type;

    var iconMap = {
        success: 'fa-circle-check',
        error:   'fa-circle-xmark',
        warning: 'fa-triangle-exclamation',
        info:    'fa-circle-info'
    };
    toast.innerHTML =
        '<i class="fa-solid ' + (iconMap[type] || 'fa-circle-info') + '"></i>' +
        '<span>' + message + '</span>' +
        '<button class="er-toast-close" title="Dismiss"><i class="fa-solid fa-xmark"></i></button>';

    container.appendChild(toast);

    // Animate in
    requestAnimationFrame(function () {
        requestAnimationFrame(function () { toast.classList.add('er-toast--visible'); });
    });

    // Dismiss
    function dismiss() {
        toast.classList.remove('er-toast--visible');
        toast.addEventListener('transitionend', function () { toast.remove(); }, { once: true });
    }
    toast.querySelector('.er-toast-close').addEventListener('click', dismiss);
    setTimeout(dismiss, duration);
}

function initExchangeRates() {
    if (!localStorage.getItem('prowess-exchange-rates')) {
        localStorage.setItem('prowess-exchange-rates', JSON.stringify([]));
    }
}

/**
 * getExchangeRate(fromCode, toCode, dateStr)
 *
 * Returns the applicable exchange rate for a currency pair on a given date.
 * Logic (in priority order):
 *   1. Same currency          → 1  (no lookup, no storage needed)
 *   2. Direct rate exists     → stored rate
 *   3. Reverse rate exists    → 1 / stored rate  (auto-calculated)
 *   4. No rate found          → null
 *
 * Why same-currency rates are not stored:
 *   The rate is always exactly 1 by definition, so storing it would be
 *   redundant data with no informational value. The short-circuit keeps the
 *   table clean and the lookup fast.
 *
 * How reverse rate calculation works:
 *   Admins enter rates in ONE direction only (e.g. SAR → INR = 22.50).
 *   When the system needs INR → SAR it divides 1 by the stored rate:
 *   1 / 22.50 ≈ 0.04444 — mathematically equivalent to the true inverse.
 *   This halves the maintenance burden while keeping a single source of truth.
 */
function getExchangeRate(fromCode, toCode, dateStr) {
    if (!fromCode || !toCode) return null;

    // Rule 1: same currency — always 1, skip storage entirely
    if (fromCode === toCode) return 1;

    var rates = JSON.parse(localStorage.getItem('prowess-exchange-rates') || '[]');

    // Helper: pick the most-recent rate on or before dateStr from a candidate list
    function bestRate(candidates) {
        var eligible = candidates.filter(function(r) { return r.effectiveDate <= dateStr; });
        if (!eligible.length) return null;
        eligible.sort(function(a, b) { return b.effectiveDate.localeCompare(a.effectiveDate); });
        return Number(eligible[0].rate);
    }

    // Rule 2: direct rate (fromCode → toCode)
    var direct = bestRate(rates.filter(function(r) {
        return r.fromCode === fromCode && r.toCode === toCode;
    }));
    if (direct !== null) return direct;

    // Rule 3: reverse rate (toCode → fromCode) → return 1 / rate
    var reverse = bestRate(rates.filter(function(r) {
        return r.fromCode === toCode && r.toCode === fromCode;
    }));
    if (reverse !== null) return 1 / reverse;

    // Rule 4: no rate available
    return null;
}

// Keep old name as an alias so any call sites in other modules still work
var lookupExchangeRate = getExchangeRate;

// ── Data repair: remove records with blank/corrupt fromCode / toCode ──
// Guards against: null, undefined, "", "undefined", "null", whitespace-only
function erIsValidCurrencyCode(code) {
    if (!code) return false;                              // null / undefined / ""
    var s = String(code).trim();
    if (!s) return false;                                 // whitespace only
    if (s === 'undefined' || s === 'null') return false;  // serialised JS primitives
    return s.length >= 2 && s.length <= 10;               // plausible currency code length
}

function erRepairExchangeRateData() {
    var stored = JSON.parse(localStorage.getItem('prowess-exchange-rates') || '[]');
    var bad    = stored.filter(function (r) {
        return !erIsValidCurrencyCode(r.fromCode) || !erIsValidCurrencyCode(r.toCode);
    });
    if (!bad.length) return;
    var good = stored.filter(function (r) {
        return erIsValidCurrencyCode(r.fromCode) && erIsValidCurrencyCode(r.toCode);
    });
    localStorage.setItem('prowess-exchange-rates', JSON.stringify(good));
    showErToast(
        bad.length + ' exchange rate record' + (bad.length > 1 ? 's' : '') +
        ' with missing currency code' + (bad.length > 1 ? 's were' : ' was') +
        ' removed automatically.',
        'warning', 5000
    );
}

function renderExchangeRates() {
    erRepairExchangeRateData();                                        // purge bad data first
    const rates  = JSON.parse(localStorage.getItem('prowess-exchange-rates') || '[]');
    const tbody  = document.getElementById('exrate-tbody');
    if (!tbody) return;
    tbody.innerHTML = '';

    if (!rates.length) {
        // Smart empty state with CTA
        const tr = document.createElement('tr');
        tr.innerHTML =
            `<td colspan="6" class="er-empty-state">` +
                `<div class="er-empty-icon"><i class="fa-solid fa-arrow-right-arrow-left"></i></div>` +
                `<p class="er-empty-msg">No exchange rates defined yet.<br>Add your first rate to enable multi-currency expenses.</p>` +
                `<button class="btn-add er-empty-cta" id="er-empty-cta-btn">` +
                    `<i class="fa-solid fa-plus"></i> Add First Rate` +
                `</button>` +
            `</td>`;
        tbody.appendChild(tr);
        document.getElementById('er-empty-cta-btn').addEventListener('click', function () {
            document.querySelector('.er-form-card').scrollIntoView({behavior:'smooth', block:'start'});
            setTimeout(function () { document.getElementById('er-from-currency').focus(); }, 300);
        });
        return;
    }

    [...rates].sort((a, b) => b.effectiveDate.localeCompare(a.effectiveDate)).forEach(function (r) {
        const fmtRate  = Number(r.rate).toLocaleString(undefined, {minimumFractionDigits:4, maximumFractionDigits:6});
        const revRate  = (1 / Number(r.rate)).toLocaleString(undefined, {minimumFractionDigits:4, maximumFractionDigits:6});
        const fromFlag    = erFlag(r.fromCode);
        const toFlag      = erFlag(r.toCode);
        // Defensive display — guard against records that slipped past repair
        const fromDisplay = erIsValidCurrencyCode(r.fromCode) ? r.fromCode : '?';
        const toDisplay   = erIsValidCurrencyCode(r.toCode)   ? r.toCode   : '?';
        const fromCls     = erIsValidCurrencyCode(r.fromCode) ? 'er-currency-badge' : 'er-currency-badge er-badge-warn';
        const toCls       = erIsValidCurrencyCode(r.toCode)   ? 'er-currency-badge' : 'er-currency-badge er-badge-warn';

        // ── Trend indicator ───────────────────────────────────────
        const peersBefore = rates.filter(function (p) {
            return p.fromCode === r.fromCode && p.toCode === r.toCode &&
                   p.id !== r.id && p.effectiveDate < r.effectiveDate;
        }).sort((a, b) => b.effectiveDate.localeCompare(a.effectiveDate));
        let trendHtml = '';
        if (peersBefore.length) {
            const prev = Number(peersBefore[0].rate);
            const curr = Number(r.rate);
            if (curr > prev)      trendHtml = '<span class="er-trend er-trend--up"   title="Higher than previous rate ('+prev+')">↑</span>';
            else if (curr < prev) trendHtml = '<span class="er-trend er-trend--down" title="Lower than previous rate ('+prev+')">↓</span>';
            else                  trendHtml = '<span class="er-trend er-trend--same" title="Same as previous rate">→</span>';
        }

        const tr = document.createElement('tr');
        tr.dataset.id = r.id;
        // Mark new rows for highlight animation (set externally via renderExchangeRates(newId))
        if (r.id === renderExchangeRates._newId) {
            tr.classList.add('er-row-new');
            renderExchangeRates._newId = null;
        }
        tr.innerHTML =
            `<td>` +
                `<span class="${fromCls}">${fromFlag}${fromDisplay}</span>` +
                `<span class="er-direction-arrow">→</span>` +
                `<span class="${toCls}">${toFlag}${toDisplay}</span>` +
            `</td>` +
            `<td class="er-rate-val er-rate-display" data-raw="${r.rate}">${fmtRate} ${trendHtml}</td>` +
            `<td>` +
                `<span class="er-currency-badge er-badge-muted">${toFlag}${toDisplay}</span>` +
                `<span class="er-direction-arrow">→</span>` +
                `<span class="er-currency-badge er-badge-muted">${fromFlag}${fromDisplay}</span>` +
            `</td>` +
            `<td class="er-rate-val er-rate-derived er-rev-display" title="Auto-calculated: 1 ÷ ${fmtRate}">${revRate} <span class="er-auto-tag">auto</span></td>` +
            `<td class="er-date-display">${r.effectiveDate}</td>` +
            `<td class="er-actions">` +
                `<button class="ref-btn-edit er-inline-edit-btn"  data-id="${r.id}" title="Edit inline"><i class="fa-solid fa-pen-to-square"></i></button>` +
                `<button class="ref-btn-delete er-delete-btn"     data-id="${r.id}" title="Delete"><i class="fa-solid fa-trash"></i></button>` +
            `</td>`;
        tbody.appendChild(tr);
    });
}
renderExchangeRates._newId = null; // slot for highlighting newly added row

// ── Inline edit: replace a display row with an editable row ─────────
function erOpenInlineEdit(id) {
    const rates = JSON.parse(localStorage.getItem('prowess-exchange-rates') || '[]');
    const r = rates.find(x => x.id === id);
    if (!r) return;

    const tr = document.querySelector(`#exrate-tbody tr[data-id="${id}"]`);
    if (!tr || tr.classList.contains('er-editing')) return;
    tr.classList.add('er-editing');

    const fmtRate = Number(r.rate).toLocaleString(undefined, {minimumFractionDigits:4, maximumFractionDigits:6});

    tr.innerHTML =
        // Currency pair — read-only in inline edit (changing pair = delete + add)
        `<td>` +
            `<span class="er-currency-badge">${r.fromCode}</span>` +
            `<span class="er-direction-arrow">→</span>` +
            `<span class="er-currency-badge">${r.toCode}</span>` +
        `</td>` +
        // Editable rate
        `<td><input class="er-inline-input" id="er-il-rate-${id}" type="number" value="${r.rate}" min="0.000001" step="any" style="width:110px" /></td>` +
        // Reverse — updates as user types
        `<td>` +
            `<span class="er-currency-badge er-badge-muted">${r.toCode}</span>` +
            `<span class="er-direction-arrow">→</span>` +
            `<span class="er-currency-badge er-badge-muted">${r.fromCode}</span>` +
        `</td>` +
        `<td class="er-rate-val er-rate-derived" id="er-il-rev-${id}" title="Auto-calculated">` +
            `${fmtRate ? (1/Number(r.rate)).toLocaleString(undefined,{minimumFractionDigits:4,maximumFractionDigits:6}) : ''} <span class="er-auto-tag">auto</span>` +
        `</td>` +
        // Editable date
        `<td><input class="er-inline-input" id="er-il-date-${id}" type="date" value="${r.effectiveDate}" /></td>` +
        // Save / cancel
        `<td class="er-actions">` +
            `<button class="ref-btn-edit er-il-save-btn"   data-id="${id}" title="Save"><i class="fa-solid fa-floppy-disk"></i></button>` +
            `<button class="ref-btn-delete er-il-cancel-btn" data-id="${id}" title="Cancel"><i class="fa-solid fa-xmark"></i></button>` +
        `</td>`;

    // Live reverse update while typing in inline row
    const rateInput = document.getElementById(`er-il-rate-${id}`);
    const revCell   = document.getElementById(`er-il-rev-${id}`);
    rateInput.addEventListener('input', function () {
        const v = parseFloat(this.value);
        if (!isNaN(v) && v > 0) {
            revCell.innerHTML = (1/v).toLocaleString(undefined,{minimumFractionDigits:4,maximumFractionDigits:6}) + ' <span class="er-auto-tag">auto</span>';
        } else {
            revCell.innerHTML = '— <span class="er-auto-tag">auto</span>';
        }
    });
    rateInput.focus();
}

function erSaveInlineEdit(id) {
    const rateInput = document.getElementById(`er-il-rate-${id}`);
    const dateInput = document.getElementById(`er-il-date-${id}`);
    if (!rateInput || !dateInput) return;

    const newRate = parseFloat(rateInput.value);
    const newDate = dateInput.value;

    if (isNaN(newRate) || newRate <= 0) {
        rateInput.style.borderColor = '#e53e3e';
        rateInput.focus();
        return;
    }
    if (!newDate) {
        dateInput.style.borderColor = '#e53e3e';
        dateInput.focus();
        return;
    }

    const rates = JSON.parse(localStorage.getItem('prowess-exchange-rates') || '[]');
    const rec   = rates.find(r => r.id === id);
    if (!rec) return;

    // Duplicate check: same direction + same date, different record
    const dup = rates.find(r => r.id !== id && r.fromCode === rec.fromCode && r.toCode === rec.toCode && r.effectiveDate === newDate);
    if (dup) {
        dateInput.style.borderColor = '#e53e3e';
        dateInput.title = `A rate for ${rec.fromCode} → ${rec.toCode} on ${newDate} already exists.`;
        dateInput.focus();
        return;
    }

    rec.rate          = newRate;
    rec.effectiveDate = newDate;
    localStorage.setItem('prowess-exchange-rates', JSON.stringify(rates));
    showErToast(erFlag(rec.fromCode) + rec.fromCode + ' → ' + erFlag(rec.toCode) + rec.toCode + ' rate updated.', 'success');
    renderExchangeRates._newId = id;
    renderExchangeRates();
}

// ── Live reverse preview (form) ──────────────────────────────────────
function erUpdatePreview() {
    const from  = document.getElementById('er-from-currency').value;
    const to    = document.getElementById('er-to-currency').value;
    const rate  = parseFloat(document.getElementById('er-rate').value);
    const prev  = document.getElementById('er-reverse-preview');

    if (from && to && from !== to && !isNaN(rate) && rate > 0) {
        document.getElementById('er-preview-from').textContent = erFlag(from) + from;
        document.getElementById('er-preview-to').textContent   = erFlag(to)   + to;
        document.getElementById('er-preview-val').textContent  = (1 / rate).toFixed(4);
        prev.style.display = '';
    } else {
        prev.style.display = 'none';
    }
}

// ── Reverse-duplicate check (form) ───────────────────────────────────
function erCheckReverseDuplicate() {
    const from   = document.getElementById('er-from-currency').value;
    const to     = document.getElementById('er-to-currency').value;
    const editId = Number(document.getElementById('er-edit-id').value);
    const warn   = document.getElementById('er-reverse-warning');
    const msg    = document.getElementById('er-reverse-warning-msg');

    if (!from || !to || from === to) { warn.style.display = 'none'; return; }

    const rates = JSON.parse(localStorage.getItem('prowess-exchange-rates') || '[]');
    const reverseExists = rates.find(function (r) {
        if (editId && r.id === editId) return false;
        return r.fromCode === to && r.toCode === from;
    });

    if (reverseExists) {
        msg.textContent = `This currency pair already exists in reverse direction (${to} → ${from}). ` +
            `The reverse rate is calculated automatically — no need to add ${from} → ${to}.`;
        warn.style.display = '';
    } else {
        warn.style.display = 'none';
    }
}

// ── Date validation (form) ───────────────────────────────────────────
function erCheckDate() {
    const dateVal = document.getElementById('er-effective-date').value;
    const from    = document.getElementById('er-from-currency').value;
    const to      = document.getElementById('er-to-currency').value;
    const editId  = Number(document.getElementById('er-edit-id').value);
    const warn    = document.getElementById('er-date-warning');
    const msg     = document.getElementById('er-date-warning-msg');

    if (!dateVal) { warn.style.display = 'none'; return; }

    const today    = new Date().toISOString().slice(0, 10);
    const messages = [];

    if (dateVal > today) {
        messages.push('Future date — this rate will apply once that date is reached.');
    }

    if (from && to && from !== to) {
        const rates = JSON.parse(localStorage.getItem('prowess-exchange-rates') || '[]');
        const newer = rates.find(function (r) {
            if (editId && r.id === editId) return false;
            return r.fromCode === from && r.toCode === to && r.effectiveDate > dateVal;
        });
        if (newer) {
            messages.push(`A newer rate for ${from} → ${to} already exists (${newer.effectiveDate}). This rate will only apply for expenses before that date.`);
        }
    }

    if (messages.length) {
        msg.textContent = messages.join('  ');
        warn.style.display = '';
    } else {
        warn.style.display = 'none';
    }
}

// Attach live-update listeners (form fields)
['er-from-currency', 'er-to-currency', 'er-rate'].forEach(function (id) {
    document.getElementById(id).addEventListener('change', function () { erUpdatePreview(); erCheckReverseDuplicate(); erCheckDate(); });
});
document.getElementById('er-rate').addEventListener('input', erUpdatePreview);
document.getElementById('er-effective-date').addEventListener('change', erCheckDate);

// ── Swap button ──────────────────────────────────────────────────────
document.getElementById('er-swap-btn').addEventListener('click', function () {
    const fromSel = document.getElementById('er-from-currency');
    const toSel   = document.getElementById('er-to-currency');
    const tmp     = fromSel.value;
    fromSel.value = toSel.value;
    toSel.value   = tmp;
    // Animate the icon
    const icon = this.querySelector('i');
    icon.style.transition = 'transform 0.35s cubic-bezier(.4,2,.55,.9)';
    icon.style.transform  = 'rotate(180deg)';
    setTimeout(function () { icon.style.transform = ''; icon.style.transition = ''; }, 380);
    erUpdatePreview(); erCheckReverseDuplicate(); erCheckDate();
});

// ── Submit ───────────────────────────────────────────────────────────
document.getElementById('er-submit-btn').addEventListener('click', function () {
    const fromCode      = document.getElementById('er-from-currency').value;
    const toCode        = document.getElementById('er-to-currency').value;
    const rateRaw       = document.getElementById('er-rate').value;
    const rate          = parseFloat(rateRaw);
    const effectiveDate = document.getElementById('er-effective-date').value;
    const editId        = Number(document.getElementById('er-edit-id').value);

    // Basic completeness
    if (!fromCode || !toCode || !rateRaw || !effectiveDate) {
        showErToast('Please fill in all fields.', 'error');
        return;
    }
    // Same-currency
    if (fromCode === toCode) {
        showErToast('From and To currencies must be different — same-currency conversions always use a rate of 1.', 'warning');
        return;
    }
    // Rate > 0
    if (isNaN(rate) || rate <= 0) {
        showErToast('Exchange rate must be a positive number greater than 0.', 'error');
        return;
    }

    const rates = JSON.parse(localStorage.getItem('prowess-exchange-rates') || '[]');

    // Block reverse duplicate
    const reverseExists = rates.find(function (r) {
        if (editId && r.id === editId) return false;
        return r.fromCode === toCode && r.toCode === fromCode;
    });
    if (reverseExists) {
        showErToast(
            erFlag(toCode) + toCode + ' → ' + erFlag(fromCode) + fromCode +
            ' already exists. The reverse rate is derived automatically — no need to add ' + fromCode + ' → ' + toCode + '.',
            'error', 5000
        );
        return;
    }

    // Exact duplicate (same direction + same date)
    const duplicate = rates.find(function (r) {
        if (editId && r.id === editId) return false;
        return r.fromCode === fromCode && r.toCode === toCode && r.effectiveDate === effectiveDate;
    });
    if (duplicate) {
        showErToast(
            'A rate for ' + erFlag(fromCode) + fromCode + ' → ' + erFlag(toCode) + toCode +
            ' on ' + effectiveDate + ' already exists. Edit that entry instead.',
            'warning', 4500
        );
        return;
    }

    // ── Save ─────────────────────────────────────────────────────
    let savedId;
    if (editId) {
        const updated = rates.map(r => r.id === editId ? { ...r, fromCode, toCode, rate, effectiveDate } : r);
        localStorage.setItem('prowess-exchange-rates', JSON.stringify(updated));
        savedId = editId;
        showErToast(erFlag(fromCode) + fromCode + ' → ' + erFlag(toCode) + toCode + ' rate updated.', 'success');
    } else {
        const newId = rates.length ? Math.max(...rates.map(r => r.id)) + 1 : 1;
        rates.push({ id: newId, fromCode, toCode, rate, effectiveDate });
        localStorage.setItem('prowess-exchange-rates', JSON.stringify(rates));
        savedId = newId;
        showErToast(erFlag(fromCode) + fromCode + ' → ' + erFlag(toCode) + toCode + ' rate saved.', 'success');
    }
    resetExchangeRateForm();
    renderExchangeRates._newId = savedId;
    renderExchangeRates();
});

// ── Table click handler (inline edit + delete) ───────────────────────
document.getElementById('exrate-tbody').addEventListener('click', function (e) {
    const inlineEditBtn = e.target.closest('.er-inline-edit-btn');
    const ilSaveBtn     = e.target.closest('.er-il-save-btn');
    const ilCancelBtn   = e.target.closest('.er-il-cancel-btn');
    const deleteBtn     = e.target.closest('.er-delete-btn');

    if (inlineEditBtn) {
        erOpenInlineEdit(Number(inlineEditBtn.getAttribute('data-id')));
        return;
    }
    if (ilSaveBtn) {
        erSaveInlineEdit(Number(ilSaveBtn.getAttribute('data-id')));
        return;
    }
    if (ilCancelBtn) {
        renderExchangeRates(); // discard — re-render
        return;
    }
    if (deleteBtn) {
        if (!confirm('Delete this exchange rate?')) return;
        const id    = Number(deleteBtn.getAttribute('data-id'));
        const rates = JSON.parse(localStorage.getItem('prowess-exchange-rates') || '[]');
        const rec   = rates.find(r => r.id === id);
        localStorage.setItem('prowess-exchange-rates', JSON.stringify(rates.filter(r => r.id !== id)));
        if (rec) showErToast(erFlag(rec.fromCode) + rec.fromCode + ' → ' + erFlag(rec.toCode) + rec.toCode + ' rate deleted.', 'info');
        renderExchangeRates();
    }
});

document.getElementById('er-cancel-btn').addEventListener('click', resetExchangeRateForm);

function resetExchangeRateForm() {
    document.getElementById('er-edit-id').value        = '';
    document.getElementById('er-from-currency').value  = '';
    document.getElementById('er-to-currency').value    = '';
    document.getElementById('er-rate').value           = '';
    document.getElementById('er-effective-date').value = '';
    document.getElementById('er-form-title-text').textContent = 'Add Exchange Rate';
    document.getElementById('er-form-title-text').previousElementSibling.className = 'fa-solid fa-plus';
    document.getElementById('er-submit-btn').innerHTML = '<i class="fa-solid fa-floppy-disk"></i> Save Rate';
    document.getElementById('er-cancel-btn').style.display = 'none';
    // Clear all inline notices
    document.getElementById('er-reverse-preview').style.display  = 'none';
    document.getElementById('er-reverse-warning').style.display  = 'none';
    document.getElementById('er-date-warning').style.display     = 'none';
}

// ═══════════════════════════════════════════════════════════════════
// ── BASE CURRENCY on Employee ────────────────────────────────────
// emp.baseCurrencyCode: 'INR' | 'USD' | etc.
// Auto-suggested when Country of Work changes, independently stored.
// ═══════════════════════════════════════════════════════════════════

function populateBaseCurrencySelect() {
    populateCurrencyDropdowns();
}

// Wire Country of Work change → suggest base currency
(function () {
    var wcSel = document.getElementById('emp-work-country');
    var bcSel = document.getElementById('emp-base-currency');
    if (!wcSel || !bcSel) return;
    wcSel.addEventListener('change', function () {
        var countryId = wcSel.value;
        if (!countryId) return;
        var allVals  = plVals();
        var country  = allVals.find(function(v) {
            return v.picklistId === 'ID_COUNTRY' && String(v.id) === String(countryId);
        });
        if (!country || !country.meta || !country.meta.code) return;
        var suggested = COUNTRY_CURRENCY_MAP[country.meta.code];
        if (suggested) {
            var currencies = plQuery('CURRENCY', {activeOnly: true});
            if (currencies.some(function(c) { return c.meta && c.meta.code === suggested; })) {
                bcSel.value = suggested;
            }
        }
    });
})();

// ── Init calls ───────────────────────────────────────────────────

initExchangeRates();
populateCurrencyDropdowns();
renderExchangeRates();
