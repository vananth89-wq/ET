// ── Expense module state ────────────────────────
let expCurrentReportId = null;  // ID of the currently open report

// ── Generic picklist engine helpers (mirrors admin.js) ───────────
// Reads from prowess-picklist-values; falls back to old storage if not migrated.

var _PL_KEY_MAP = {
    'prowess-designations':       'DESIGNATION',
    'prowess-nationalities':      'NATIONALITY',
    'prowess-marital-statuses':   'MARITAL_STATUS',
    'prowess-relationship-types': 'RELATIONSHIP_TYPE',
    'prowess-id-countries':       'ID_COUNTRY',
    'prowess-id-types':           'ID_TYPE',
    'prowess-locations':          'LOCATION',
    'prowess-currencies':         'CURRENCY',
};

function plValsScript() {
    return JSON.parse(localStorage.getItem('prowess-picklist-values') || '[]');
}

function plQueryScript(picklistId, opts) {
    var activeOnly = opts && opts.activeOnly;
    var vals = plValsScript().filter(function(v) { return v.picklistId === picklistId; });
    if (activeOnly) vals = vals.filter(function(v) { return v.active !== false; });
    return vals.sort(function(a, b) { return (a.value || '').localeCompare(b.value || ''); });
}

// ═══════════════════════════════════════════════════════════════════
// ── EXPENSE REPORT MODULE ───────────────────────────────────────────
//
//  Architecture (3-section layout):
//  Section A — Report List: table of all employee reports
//  Section B — Report Detail:
//    TOP    → Report Header (name, status, base currency)
//    MIDDLE → Line Items (add/edit form + table)
//    BOTTOM → Total in base currency + workflow actions
//
//  Data model (prowess-expense-reports):
//  [{
//    id, employeeId, name, status, baseCurrencyCode,
//    createdAt, updatedAt,
//    lineItems: [{
//      id, category, date, projectId, amount,
//      currencyCode, exchangeRate, convertedAmount, note
//    }]
//  }]
//
//  Workflow (placeholder — configurable in future):
//  draft → submitted → approved
//                    ↓
//                 rejected → draft (editable again)
// ═══════════════════════════════════════════════════════════════════

// ── Workflow config (replace with dynamic config later) ────────────
var EXPENSE_WORKFLOW_STEPS = [
    { step: 1, role: 'manager',  label: 'Manager Approval'  },
    { step: 2, role: 'hr',       label: 'HR Approval'       },
    { step: 3, role: 'finance',  label: 'Finance Approval'  },
];

// ── Validation config — tune thresholds here without touching logic ─
var EXP_VALIDATION_CONFIG = {
    // Amount threshold: require a note if expense exceeds this value (in expense currency)
    noteRequiredAbove: 10000,
    // Category IDs that must have a project assigned. Add IDs to enforce.
    // Example: ['3', '7'] means categories with id 3 and 7 require a project.
    requireProjectForCategories: [],
};

// ── Helpers ────────────────────────────────────────────────────────

function expGetReports() {
    return JSON.parse(localStorage.getItem('prowess-expense-reports') || '[]');
}

function expSaveReports(reports) {
    localStorage.setItem('prowess-expense-reports', JSON.stringify(reports));
}

function expGetCurrentEmployee() {
    var employees = JSON.parse(localStorage.getItem('prowess-employees') || '[]');

    // Primary: explicit active-employee key
    var empId = localStorage.getItem('prowess-active-employee');
    if (empId) {
        var byId = employees.find(function (e) { return e.employeeId === empId; });
        if (byId) return byId;
    }

    // Fallback: match via prowess-profile (employeeId, then name)
    var profile = JSON.parse(localStorage.getItem('prowess-profile') || 'null');
    if (profile) {
        if (profile.employeeId) {
            var byEmpId = employees.find(function (e) {
                return String(e.employeeId) === String(profile.employeeId);
            });
            if (byEmpId) return byEmpId;
        }
        if (profile.name) {
            var byName = employees.find(function (e) {
                return e.name && e.name.trim().toLowerCase() === profile.name.trim().toLowerCase();
            });
            if (byName) return byName;
        }
    }

    return null;
}

function expGetCurrencySymbol(code) {
    if (!code) return '';
    // Try new picklist storage first
    var vals = plValsScript().filter(function(v) { return v.picklistId === 'CURRENCY'; });
    if (vals.length) {
        var c = vals.find(function(v) { return v.meta && v.meta.code === code; });
        return c ? (c.meta.symbol || code) : code;
    }
    // Fallback to old storage (pre-migration)
    var currencies = JSON.parse(localStorage.getItem('prowess-currencies') || '[]');
    var c = currencies.find(function(x) { return x.code === code; });
    return c ? c.symbol : code;
}

function expFmtAmount(amount, currencyCode) {
    if (amount === null || amount === undefined || isNaN(amount)) return '—';
    var sym = expGetCurrencySymbol(currencyCode);
    return sym + Number(amount).toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

function expStatusBadgeHtml(status) {
    var map = {
        draft:      { cls: 'exp-status-draft',     label: 'Draft'      },
        submitted:  { cls: 'exp-status-submitted',  label: 'Submitted'  },
        approved:   { cls: 'exp-status-approved',   label: 'Approved'   },
        rejected:   { cls: 'exp-status-rejected',   label: 'Rejected'   },
    };
    var s = map[status] || { cls: 'exp-status-draft', label: status || 'Draft' };
    return '<span class="exp-status-badge ' + s.cls + '">' + s.label + '</span>';
}

function expIsEditable(status) {
    return status === 'draft' || status === 'rejected';
}

/**
 * expLookupRate — mirrors getExchangeRate() in admin.js.
 * 1. Same currency  → 1
 * 2. Direct rate    → stored rate
 * 3. Reverse rate   → 1 / stored rate (auto-calculated)
 * 4. Not found      → null
 */
function expLookupRate(fromCode, toCode, dateStr) {
    if (!fromCode || !toCode || !dateStr) return null;
    if (fromCode === toCode) return 1;
    var rates = JSON.parse(localStorage.getItem('prowess-exchange-rates') || '[]');

    function best(candidates) {
        var eligible = candidates.filter(function(r) { return r.effectiveDate <= dateStr; });
        if (!eligible.length) return null;
        eligible.sort(function(a, b) { return b.effectiveDate.localeCompare(a.effectiveDate); });
        return Number(eligible[0].rate);
    }

    // Direct
    var direct = best(rates.filter(function(r) { return r.fromCode === fromCode && r.toCode === toCode; }));
    if (direct !== null) return direct;

    // Reverse
    var reverse = best(rates.filter(function(r) { return r.fromCode === toCode && r.toCode === fromCode; }));
    if (reverse !== null) return 1 / reverse;

    return null;
}

// ── Section A: Report List ─────────────────────────────────────────

var expReportFilter = 'all'; // active filter chip

// Returns age text + CSS class for a report's status age
function expStatusAgeBadgeHtml(report) {
    if (!report.updatedAt) return '';
    var now      = new Date();
    var updated  = new Date(report.updatedAt);
    var diffMs   = now - updated;
    var diffDays = Math.floor(diffMs / 86400000);
    var diffHrs  = Math.floor(diffMs / 3600000);
    var ageText  = diffDays >= 1 ? diffDays + 'd' : (diffHrs >= 1 ? diffHrs + 'h' : 'now');
    var cls = 'exp-age-badge';
    var stale7  = report.status === 'draft'     && diffDays > 7;
    var stale14 = report.status === 'submitted' && diffDays > 14;
    var alert14 = report.status === 'draft'     && diffDays > 14;
    var alert21 = report.status === 'submitted' && diffDays > 21;
    if (alert14 || alert21)      cls += ' exp-age-badge--alert';
    else if (stale7 || stale14)  cls += ' exp-age-badge--warn';
    return '<span class="' + cls + '">' + ageText + '</span>';
}

function expRenderReportList() {
    var emp        = expGetCurrentEmployee();
    var reports    = expGetReports();
    var empReports = emp
        ? reports.filter(function (r) { return r.employeeId === emp.employeeId; })
        : [];

    // Sort: most recently updated first
    empReports.sort(function (a, b) { return (b.updatedAt || '').localeCompare(a.updatedAt || ''); });

    // ── KPI Strip ────────────────────────────────────────────────────
    var kpiEl = document.getElementById('exp-kpi-strip');
    if (kpiEl) {
        var calcTotal = function (arr) {
            return arr.reduce(function (s, r) {
                return s + (r.lineItems || []).reduce(function (t, li) { return t + (li.convertedAmount || 0); }, 0);
            }, 0);
        };
        var pendingReports  = empReports.filter(function (r) { return r.status === 'draft' || r.status === 'submitted'; });
        var approvedReports = empReports.filter(function (r) { return r.status === 'approved'; });
        var baseSym = empReports.length ? expGetCurrencySymbol((empReports[0] || {}).baseCurrencyCode) : '';
        var fmt = function (v) { return baseSym + v.toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 }); };

        kpiEl.innerHTML =
            '<div class="exp-kpi-card">' +
                '<span class="exp-kpi-icon"><i class="fa-solid fa-file-invoice-dollar"></i></span>' +
                '<div class="exp-kpi-body">' +
                    '<span class="exp-kpi-value">' + empReports.length + '</span>' +
                    '<span class="exp-kpi-label">Total Reports</span>' +
                '</div>' +
            '</div>' +
            '<div class="exp-kpi-card exp-kpi-card--pending">' +
                '<span class="exp-kpi-icon"><i class="fa-solid fa-clock"></i></span>' +
                '<div class="exp-kpi-body">' +
                    '<span class="exp-kpi-value">' + fmt(calcTotal(pendingReports)) + '</span>' +
                    '<span class="exp-kpi-label">Pending Approval</span>' +
                '</div>' +
            '</div>' +
            '<div class="exp-kpi-card exp-kpi-card--approved">' +
                '<span class="exp-kpi-icon"><i class="fa-solid fa-circle-check"></i></span>' +
                '<div class="exp-kpi-body">' +
                    '<span class="exp-kpi-value">' + fmt(calcTotal(approvedReports)) + '</span>' +
                    '<span class="exp-kpi-label">Approved</span>' +
                '</div>' +
            '</div>';
    }

    // ── Filter Chips ─────────────────────────────────────────────────
    var chipsEl = document.getElementById('exp-filter-chips');
    if (chipsEl) {
        var allStatuses = ['all', 'draft', 'submitted', 'approved', 'rejected'];
        var chipLabels  = { all: 'All', draft: 'Draft', submitted: 'Submitted', approved: 'Approved', rejected: 'Rejected' };
        var counts      = { all: empReports.length };
        allStatuses.slice(1).forEach(function (s) {
            counts[s] = empReports.filter(function (r) { return r.status === s; }).length;
        });

        chipsEl.innerHTML = allStatuses.map(function (s) {
            if (s !== 'all' && counts[s] === 0) return '';
            var active = expReportFilter === s;
            return '<button class="exp-filter-chip' + (active ? ' exp-filter-chip--active' : '') + '" data-filter="' + s + '">' +
                chipLabels[s] +
                '<span class="exp-filter-chip-count">' + counts[s] + '</span>' +
            '</button>';
        }).join('');

        chipsEl.querySelectorAll('.exp-filter-chip').forEach(function (btn) {
            btn.addEventListener('click', function () {
                expReportFilter = this.getAttribute('data-filter');
                expRenderReportList();
            });
        });
    }

    // Apply active filter
    var visible = expReportFilter === 'all'
        ? empReports
        : empReports.filter(function (r) { return r.status === expReportFilter; });

    // ── Table body ───────────────────────────────────────────────────
    var tbody = document.getElementById('exp-report-tbody');
    if (!tbody) return;
    tbody.innerHTML = '';

    if (!empReports.length) {
        tbody.innerHTML =
            '<tr><td colspan="4" class="exp-empty-state">' +
                '<div class="exp-empty-icon"><i class="fa-solid fa-file-invoice-dollar"></i></div>' +
                '<p class="exp-empty-msg">No reports yet.<br>Start by creating your first expense report.</p>' +
                '<button class="exp-empty-cta" id="exp-empty-cta-btn">' +
                    '<i class="fa-solid fa-plus"></i> Create Report' +
                '</button>' +
            '</td></tr>';
        var ctaBtn = document.getElementById('exp-empty-cta-btn');
        if (ctaBtn) ctaBtn.addEventListener('click', expShowCreateModal);
        return;
    }

    if (!visible.length) {
        tbody.innerHTML =
            '<tr><td colspan="4" class="exp-empty-state">' +
                '<div class="exp-empty-icon"><i class="fa-solid fa-filter"></i></div>' +
                '<p class="exp-empty-msg">No ' + expReportFilter + ' reports.</p>' +
            '</td></tr>';
        return;
    }

    visible.forEach(function (report) {
        var total   = (report.lineItems || []).reduce(function (s, li) { return s + (li.convertedAmount || 0); }, 0);
        var baseSym = expGetCurrencySymbol(report.baseCurrencyCode);
        var dateStr = report.updatedAt ? report.updatedAt.substring(0, 10) : '—';
        var isDraft = report.status === 'draft';
        var tr = document.createElement('tr');
        tr.className = 'exp-report-row' + (report.id === expCurrentReportId ? ' exp-report-row--active' : '');
        tr.setAttribute('data-report-id', report.id);
        tr.innerHTML =
            '<td class="exp-report-name-cell">' +
                '<span class="exp-report-name-text">' + expEsc(report.name || 'Untitled') + '</span>' +
                (isDraft
                    ? '<button class="exp-rename-btn" data-report-id="' + report.id + '" title="Rename"><i class="fa-solid fa-pen"></i></button>' +
                      '<button class="exp-delete-report-btn" data-report-id="' + report.id + '" title="Delete report"><i class="fa-solid fa-trash"></i></button>'
                    : '') +
            '</td>' +
            '<td>' +
                '<div class="exp-status-age-wrap">' +
                    expStatusBadgeHtml(report.status) +
                    expStatusAgeBadgeHtml(report) +
                '</div>' +
            '</td>' +
            '<td class="exp-total-cell">' + baseSym + total.toLocaleString('en-IN', {minimumFractionDigits:2, maximumFractionDigits:2}) + '</td>' +
            '<td class="exp-date-cell">' + dateStr + '</td>';
        tbody.appendChild(tr);
    });
}

// ── Section B: Report Detail ───────────────────────────────────────

function expOpenReport(reportId) {
    expCurrentReportId = reportId;
    var reports = expGetReports();
    var report  = reports.find(function (r) { return r.id === reportId; });
    if (!report) return;

    document.getElementById('exp-report-list-panel').style.display = 'none';
    document.getElementById('exp-report-detail').style.display     = 'block';

    // TOP: name + status
    var nameInput = document.getElementById('exp-report-name-input');
    nameInput.value = report.name || '';
    var editable = expIsEditable(report.status);
    nameInput.readOnly = !editable;
    nameInput.className = 'exp-report-name-input' + (editable ? '' : ' exp-readonly');

    document.getElementById('exp-report-status-badge').outerHTML;  // swap
    var badge = document.getElementById('exp-report-status-badge');
    badge.className = 'exp-status-badge ' + ('exp-status-' + (report.status || 'draft'));
    badge.textContent = (report.status || 'draft').charAt(0).toUpperCase() + (report.status || 'draft').slice(1);

    // Base currency
    var baseSym  = expGetCurrencySymbol(report.baseCurrencyCode);
    document.getElementById('exp-base-currency-display').textContent =
        report.baseCurrencyCode ? (report.baseCurrencyCode + ' ' + baseSym) : '—';
    document.getElementById('exp-item-base-lbl').textContent = report.baseCurrencyCode || '—';

    // Key attributes — submitted date, approved date, approved-in duration
    var attrSubmitted = document.getElementById('exp-attr-submitted');
    var attrApproved  = document.getElementById('exp-attr-approved');
    var attrDuration  = document.getElementById('exp-attr-duration');
    if (attrSubmitted) attrSubmitted.textContent = expFmtDate(report.submittedAt);
    if (attrApproved)  attrApproved.textContent  = expFmtDate(report.approvedAt);
    if (attrDuration) {
        if (report.submittedAt && report.approvedAt) {
            var ms   = new Date(report.approvedAt) - new Date(report.submittedAt);
            var days = Math.max(1, Math.round(ms / 86400000));
            attrDuration.textContent = days + (days === 1 ? ' day' : ' days');
        } else {
            attrDuration.textContent = '—';
        }
    }

    // Approval flow stepper
    expRenderApprovalFlow(report.status || 'draft');

    // Show/hide Add Expense button based on editability
    document.getElementById('exp-btn-add-item').style.display = editable ? 'inline-flex' : 'none';

    // Status awareness banner (12)
    var banner = document.getElementById('exp-status-banner');
    if (banner) {
        var bannerCfg = {
            draft:     { cls: 'draft',     icon: 'fa-pen-to-square', msg: 'This report is in <strong>Draft</strong>. You can still add and edit expenses.' },
            rejected:  { cls: 'rejected',  icon: 'fa-circle-xmark',  msg: 'This report was <strong>Rejected</strong>. Please review comments and resubmit.' },
            submitted: { cls: 'submitted', icon: 'fa-clock',          msg: 'This report has been <strong>Submitted</strong> and is awaiting approval. No further edits allowed.' },
            approved:  { cls: 'approved',  icon: 'fa-circle-check',   msg: 'This report has been <strong>Approved</strong>.' },
        };
        var cfg = bannerCfg[report.status];
        if (cfg) {
            banner.className = 'exp-status-banner exp-status-banner--' + cfg.cls;
            banner.innerHTML = '<i class="fa-solid ' + cfg.icon + '"></i><span>' + cfg.msg + '</span>';
            banner.style.display = 'flex';
        } else {
            banner.style.display = 'none';
        }
    }

    // Hide submit confirmation strip when re-opening
    expHideSubmitConfirm();

    expRenderLineItems(report);
    expRenderFooter(report);
    expRenderReportList();   // refresh list highlights
}

function expCloseDetail() {
    expCurrentReportId = null;
    expHideItemForm();
    expCloseExpandEdit();
    expHideSubmitConfirm();
    document.getElementById('exp-report-detail').style.display     = 'none';
    document.getElementById('exp-report-list-panel').style.display = 'block';
    expRenderReportList();
}

// ── Line Items ─────────────────────────────────────────────────────

function expRenderLineItems(report) {
    var tbody    = document.getElementById('exp-items-tbody');
    if (!tbody) return;
    var items    = report.lineItems || [];
    var editable = expIsEditable(report.status);
    tbody.innerHTML = '';

    if (!items.length) {
        // Empty state (9)
        tbody.innerHTML =
            '<tr><td colspan="11" class="exp-items-empty-state">' +
                '<div class="exp-items-empty-icon"><i class="fa-solid fa-receipt"></i></div>' +
                '<p class="exp-items-empty-msg">No expenses yet.' +
                    (editable ? '<br>Add your first expense to get started.' : '') + '</p>' +
                (editable
                    ? '<button class="exp-items-empty-cta" id="exp-items-empty-cta-btn">' +
                          '<i class="fa-solid fa-plus"></i> Add Expense' +
                      '</button>'
                    : '') +
            '</td></tr>';
        if (editable) {
            var ctaBtn = document.getElementById('exp-items-empty-cta-btn');
            if (ctaBtn) ctaBtn.addEventListener('click', function () {
                expHideItemForm();
                expShowItemForm(null);
            });
        }
        return;
    }

    var projects = JSON.parse(localStorage.getItem('prowess-projects') || '[]');
    items.forEach(function (item, idx) {
        var proj     = projects.find(function (p) { return String(p.id) === String(item.projectId); });
        var projName = proj ? proj.name : '—';
        var isFx     = item.currencyCode && item.currencyCode !== report.baseCurrencyCode;
        var tr = document.createElement('tr');
        tr.setAttribute('data-item-id', item.id);  // needed for auto-scroll (13)
        if (isFx) tr.classList.add('exp-row-fx');   // foreign currency highlight (10)
        tr.innerHTML =
            '<td>' + (idx + 1) + '</td>' +
            '<td>' + expEsc(expResolveCategoryName(item.category_id, item.category_name)) + '</td>' +
            '<td>' + (item.date || '—') + '</td>' +
            '<td><span class="project-badge">' + expEsc(projName) + '</span></td>' +
            '<td class="er-rate-val">' + expFmtAmount(item.amount, item.currencyCode) + '</td>' +
            '<td><span class="er-currency-badge' + (isFx ? ' er-currency-badge--fx' : '') + '">' + (item.currencyCode || '—') + '</span></td>' +
            '<td class="er-rate-val">' + (item.exchangeRate != null ? Number(item.exchangeRate).toLocaleString(undefined, {minimumFractionDigits:4, maximumFractionDigits:6}) : '—') + '</td>' +
            '<td class="er-rate-val">' + expFmtAmount(item.convertedAmount, report.baseCurrencyCode) + '</td>' +
            '<td>' + expEsc(item.note || '—') + '</td>' +
            '<td class="exp-att-cell">' + expAttCellHtml(item) + '</td>' +
            '<td class="exp-item-actions-cell">' +
                (editable
                    ? '<button class="ref-btn-edit exp-item-edit-btn"      data-item-id="' + item.id + '" title="Edit"><i class="fa-solid fa-pen-to-square"></i></button>' +
                      '<button class="exp-item-dup-btn"                    data-item-id="' + item.id + '" title="Duplicate"><i class="fa-solid fa-copy"></i></button>' +
                      '<button class="ref-btn-delete exp-item-delete-btn"  data-item-id="' + item.id + '" title="Delete"><i class="fa-solid fa-trash"></i></button>'
                    : '<span style="color:#aaa;font-size:12px;">Locked</span>')
                +
            '</td>';
        tbody.appendChild(tr);
    });
}

// ══════════════════════════════════════════════════════════════════
// EXPENSE ATTACHMENT FEATURE
// ══════════════════════════════════════════════════════════════════

var expAttCurrentItemId = null;   // item whose modal is open

// ── Helpers ─────────────────────────────────────────────────────────

function expAttFmtSize(bytes) {
    if (bytes < 1024)       return bytes + ' B';
    if (bytes < 1048576)    return (bytes / 1024).toFixed(1) + ' KB';
    return (bytes / 1048576).toFixed(2) + ' MB';
}

function expAttFileIconClass(type) {
    if (type === 'application/pdf')                         return 'fa-solid fa-file-pdf exp-att-file-icon--pdf';
    if (type === 'image/jpeg' || type === 'image/png')      return 'fa-solid fa-file-image exp-att-file-icon--img';
    return 'fa-solid fa-file exp-att-file-icon--other';
}

// ── Cell HTML helper ─────────────────────────────────────────────────

function expAttCellHtml(item) {
    var atts  = item.attachments || [];
    var count = atts.length;
    var hasCls = count > 0 ? ' exp-att-btn--has' : '';
    var title  = count > 0
        ? count + ' attachment' + (count > 1 ? 's' : '')
        : 'Add attachment';
    return '<button class="exp-att-btn' + hasCls + '" ' +
               'data-item-id="' + item.id + '" ' +
               'title="' + title + '">' +
               '<i class="fa-solid fa-paperclip"></i>' +
               (count > 0 ? '<span class="exp-att-count">' + count + '</span>' : '') +
           '</button>';
}

// ── Open / close modal ───────────────────────────────────────────────

function expAttOpenModal(itemId) {
    expAttCurrentItemId = itemId;
    var overlay = document.getElementById('exp-att-overlay');
    if (overlay) {
        overlay.style.display = 'flex';
        expAttRenderModal();
        // Trap close on overlay click
        overlay.onclick = function (e) {
            if (e.target === overlay) expAttCloseModal();
        };
    }
}

function expAttCloseModal() {
    var overlay = document.getElementById('exp-att-overlay');
    if (overlay) overlay.style.display = 'none';
    expAttCurrentItemId = null;
}

// ── Render modal body ────────────────────────────────────────────────

function expAttRenderModal() {
    var body = document.getElementById('exp-att-modal-body');
    if (!body) return;

    var reports = expGetReports();
    var report  = reports.find(function (r) { return r.id === expCurrentReportId; });
    if (!report) return;

    var item = (report.lineItems || []).find(function (li) { return li.id === expAttCurrentItemId; });
    if (!item) return;

    var atts     = item.attachments || [];
    var editable = expIsEditable(report.status);  // draft/rejected = true

    // ── Upload zone ─────────────────────────────────────────────────
    var roClass  = editable ? '' : ' exp-att-upload-zone--readonly';
    var roAttr   = editable ? '' : ' disabled';
    var uploadHtml =
        '<div>' +
            '<div class="exp-att-upload-zone' + roClass + '" id="exp-att-drop-zone">' +
                (editable ? '<input type="file" id="exp-att-file-input" multiple accept=".pdf,.jpg,.jpeg,.png" ' + roAttr + '>' : '') +
                '<div class="exp-att-upload-icon"><i class="fa-solid fa-cloud-arrow-up"></i></div>' +
                '<div class="exp-att-upload-text">' + (editable ? 'Click or drag files here' : 'Upload disabled') + '</div>' +
                '<div class="exp-att-upload-hint">PDF, JPG, PNG · max 5 MB per file</div>' +
            '</div>' +
            '<div id="exp-att-error-wrap"></div>' +
        '</div>';

    // ── File list ────────────────────────────────────────────────────
    var listHtml = '<div>';
    listHtml += '<div class="exp-att-file-list-title">Uploaded Files (' + atts.length + ')</div>';
    if (atts.length === 0) {
        listHtml += '<div class="exp-att-empty">No files attached yet.</div>';
    } else {
        listHtml += '<div class="exp-att-file-list">';
        atts.forEach(function (att) {
            var iconCls = expAttFileIconClass(att.type);
            listHtml +=
                '<div class="exp-att-file-item">' +
                    '<i class="' + iconCls + ' exp-att-file-icon"></i>' +
                    '<div class="exp-att-file-info">' +
                        '<div class="exp-att-file-name" title="' + expEsc(att.name) + '">' + expEsc(att.name) + '</div>' +
                        '<div class="exp-att-file-size">' + expAttFmtSize(att.size) + '</div>' +
                    '</div>' +
                    '<div class="exp-att-file-actions">' +
                        '<button class="exp-att-file-btn exp-att-file-btn--view" data-att-id="' + att.id + '" title="View / Download">' +
                            '<i class="fa-solid fa-arrow-down-to-line"></i> View' +
                        '</button>' +
                        '<button class="exp-att-file-btn exp-att-file-btn--del" data-att-id="' + att.id + '" title="Delete"' +
                            (!editable ? ' disabled' : '') + '>' +
                            '<i class="fa-solid fa-trash"></i>' +
                        '</button>' +
                    '</div>' +
                '</div>';
        });
        listHtml += '</div>';
    }
    listHtml += '</div>';

    body.innerHTML = uploadHtml + listHtml;

    // Wire file input
    if (editable) {
        var fileInput = document.getElementById('exp-att-file-input');
        if (fileInput) {
            fileInput.addEventListener('change', function () {
                expAttHandleFiles(Array.from(this.files));
                this.value = '';
            });
        }

        // Drag-and-drop
        var dropZone = document.getElementById('exp-att-drop-zone');
        if (dropZone) {
            dropZone.addEventListener('dragover', function (e) {
                e.preventDefault();
                dropZone.classList.add('exp-att-drag-over');
            });
            dropZone.addEventListener('dragleave', function () {
                dropZone.classList.remove('exp-att-drag-over');
            });
            dropZone.addEventListener('drop', function (e) {
                e.preventDefault();
                dropZone.classList.remove('exp-att-drag-over');
                expAttHandleFiles(Array.from(e.dataTransfer.files));
            });
        }
    }

    // Wire view/delete buttons
    body.querySelectorAll('.exp-att-file-btn--view').forEach(function (btn) {
        btn.addEventListener('click', function () {
            expAttViewFile(this.getAttribute('data-att-id'));
        });
    });
    body.querySelectorAll('.exp-att-file-btn--del').forEach(function (btn) {
        btn.addEventListener('click', function () {
            expAttDeleteFile(this.getAttribute('data-att-id'));
        });
    });
}

// ── File validation + save ───────────────────────────────────────────

var EXP_ATT_ALLOWED_TYPES  = ['application/pdf', 'image/jpeg', 'image/png'];
var EXP_ATT_MAX_SIZE_BYTES = 5 * 1024 * 1024; // 5 MB

function expAttHandleFiles(files) {
    var errorWrap = document.getElementById('exp-att-error-wrap');
    if (errorWrap) errorWrap.innerHTML = '';

    var errors = [];
    var valid  = [];

    files.forEach(function (f) {
        if (!EXP_ATT_ALLOWED_TYPES.includes(f.type)) {
            errors.push('"' + f.name + '" — unsupported type. Allowed: PDF, JPG, PNG.');
        } else if (f.size > EXP_ATT_MAX_SIZE_BYTES) {
            errors.push('"' + f.name + '" — exceeds 5 MB limit (' + expAttFmtSize(f.size) + ').');
        } else {
            valid.push(f);
        }
    });

    if (errors.length && errorWrap) {
        errorWrap.innerHTML = errors.map(function (e) {
            return '<div class="exp-att-error" style="margin-top:8px;">' +
                       '<i class="fa-solid fa-triangle-exclamation"></i><span>' + expEsc(e) + '</span>' +
                   '</div>';
        }).join('');
    }

    if (!valid.length) return;

    var pending = valid.length;
    valid.forEach(function (f) {
        var reader = new FileReader();
        reader.onload = function (ev) {
            expAttSaveFile({ name: f.name, type: f.type, size: f.size, dataUrl: ev.target.result });
            pending--;
            if (pending === 0) expAttRenderModal();   // re-render once all files read
        };
        reader.readAsDataURL(f);
    });
}

// ── Persist to localStorage ──────────────────────────────────────────

function expAttSaveFile(fileObj) {
    var reports = expGetReports();
    var rIdx    = reports.findIndex(function (r) { return r.id === expCurrentReportId; });
    if (rIdx < 0) return;
    var iIdx = (reports[rIdx].lineItems || []).findIndex(function (li) { return li.id === expAttCurrentItemId; });
    if (iIdx < 0) return;

    if (!reports[rIdx].lineItems[iIdx].attachments) reports[rIdx].lineItems[iIdx].attachments = [];

    reports[rIdx].lineItems[iIdx].attachments.push({
        id:      'att_' + Date.now() + '_' + Math.random().toString(36).slice(2, 7),
        name:    fileObj.name,
        type:    fileObj.type,
        size:    fileObj.size,
        dataUrl: fileObj.dataUrl
    });
    expSaveReports(reports);

    // Refresh icon in table without full re-render
    expAttRefreshCell(expAttCurrentItemId, reports[rIdx].lineItems[iIdx].attachments.length);
}

function expAttDeleteFile(attId) {
    var reports = expGetReports();
    var rIdx    = reports.findIndex(function (r) { return r.id === expCurrentReportId; });
    if (rIdx < 0) return;
    var iIdx = (reports[rIdx].lineItems || []).findIndex(function (li) { return li.id === expAttCurrentItemId; });
    if (iIdx < 0) return;

    reports[rIdx].lineItems[iIdx].attachments =
        (reports[rIdx].lineItems[iIdx].attachments || []).filter(function (a) { return a.id !== attId; });
    expSaveReports(reports);

    var remaining = reports[rIdx].lineItems[iIdx].attachments.length;
    expAttRefreshCell(expAttCurrentItemId, remaining);
    expAttRenderModal();
}

function expAttViewFile(attId) {
    var reports = expGetReports();
    var report  = reports.find(function (r) { return r.id === expCurrentReportId; });
    if (!report) return;
    var item = (report.lineItems || []).find(function (li) { return li.id === expAttCurrentItemId; });
    if (!item) return;
    var att = (item.attachments || []).find(function (a) { return a.id === attId; });
    if (!att) return;

    var link = document.createElement('a');
    link.href     = att.dataUrl;
    link.download = att.name;
    link.click();
}

// ── Refresh attachment cell icon without re-rendering whole table ───

function expAttRefreshCell(itemId, count) {
    var btn = document.querySelector('.exp-att-btn[data-item-id="' + itemId + '"]');
    if (!btn) return;
    btn.className = 'exp-att-btn' + (count > 0 ? ' exp-att-btn--has' : '');
    btn.title     = count > 0 ? count + ' attachment' + (count > 1 ? 's' : '') : 'Add attachment';
    btn.innerHTML = '<i class="fa-solid fa-paperclip"></i>' +
                    (count > 0 ? '<span class="exp-att-count">' + count + '</span>' : '');
}

// ── Event delegation: open modal on paperclip click ─────────────────

document.addEventListener('click', function (e) {
    var btn = e.target.closest('.exp-att-btn');
    if (btn) expAttOpenModal(btn.getAttribute('data-item-id'));
});

document.addEventListener('click', function (e) {
    if (e.target.closest('#exp-att-modal-close')) expAttCloseModal();
});

document.addEventListener('keydown', function (e) {
    if (e.key === 'Escape') expAttCloseModal();
});

// ── End Attachment Feature ───────────────────────────────────────────

function expRenderFooter(report) {
    var items  = report.lineItems || [];
    var total  = items.reduce(function (s, li) { return s + (li.convertedAmount || 0); }, 0);
    var baseSym = expGetCurrencySymbol(report.baseCurrencyCode);
    var totalEl = document.getElementById('exp-total-display');
    if (totalEl) {
        totalEl.textContent = baseSym + total.toLocaleString('en-IN', {minimumFractionDigits:2, maximumFractionDigits:2}) +
            (report.baseCurrencyCode ? '  (' + report.baseCurrencyCode + ')' : '');
    }

    var actionsEl = document.getElementById('exp-footer-actions');
    if (!actionsEl) return;
    actionsEl.innerHTML = '';

    var status = report.status || 'draft';

    if (status === 'draft' || status === 'rejected') {
        var saveBtn = document.createElement('button');
        saveBtn.className = 'exp-btn-save-draft';
        saveBtn.innerHTML = '<i class="fa-solid fa-floppy-disk"></i> Save Draft';
        saveBtn.addEventListener('click', function () { expSaveReportName(); });
        actionsEl.appendChild(saveBtn);

        if (items.length > 0) {
            var submitBtn = document.createElement('button');
            submitBtn.className = 'exp-btn-submit';
            submitBtn.innerHTML = '<i class="fa-solid fa-paper-plane"></i> Submit';
            submitBtn.addEventListener('click', function () { expSubmitReport(); });
            actionsEl.appendChild(submitBtn);
        }
    } else if (status === 'submitted') {
        // Placeholder for future manager/HR/finance action buttons
        var infoEl = document.createElement('span');
        infoEl.className = 'exp-workflow-info';
        infoEl.innerHTML = '<i class="fa-solid fa-clock"></i> Awaiting approval · ' +
            EXPENSE_WORKFLOW_STEPS.map(function (s) { return s.label; }).join(' → ');
        actionsEl.appendChild(infoEl);
    } else if (status === 'approved') {
        var lockedEl = document.createElement('span');
        lockedEl.className = 'exp-workflow-info exp-workflow-approved';
        lockedEl.innerHTML = '<i class="fa-solid fa-circle-check"></i> Approved & Locked';
        actionsEl.appendChild(lockedEl);
    }
}

// ── Inline item form ───────────────────────────────────────────────

function expShowItemForm(item) {
    var report = expGetReports().find(function (r) { return r.id === expCurrentReportId; });
    if (!report) return;

    var wrap = document.getElementById('exp-item-form-wrap');
    wrap.style.display = 'block';

    // Populate dropdowns
    expPopulateCategoryDropdown('exp-item-category');
    expPopulateCurrencyDropdown('exp-item-currency');

    // Populate project dropdown
    expPopulateProjectDropdown('exp-item-project', item ? item.date : null);

    document.getElementById('exp-item-edit-id').value   = item ? item.id : '';
    document.getElementById('exp-item-base-lbl').textContent = report.baseCurrencyCode || '—';

    if (item) {
        // Editing existing item — use category_id as source of truth
        document.getElementById('exp-item-category').value  = item.category_id ? String(item.category_id) : '';
        document.getElementById('exp-item-date').value      = item.date || '';
        document.getElementById('exp-item-currency').value  = item.currencyCode || report.baseCurrencyCode || '';
        document.getElementById('exp-item-amount').value    = item.amount || '';
        document.getElementById('exp-item-rate').value      = item.exchangeRate || '';
        document.getElementById('exp-item-converted').value = item.convertedAmount || '';
        document.getElementById('exp-item-note').value      = item.note || '';
        if (item.projectId) {
            document.getElementById('exp-item-project').value = item.projectId;
        }
    } else {
        // New item — apply smart defaults (2); category_id is the default key
        var defs = expLoadDefaults();
        document.getElementById('exp-item-category').value  = defs.category_id || '';
        document.getElementById('exp-item-date').value      = '';
        document.getElementById('exp-item-amount').value    = '';
        document.getElementById('exp-item-rate').value      = '';
        document.getElementById('exp-item-converted').value = '';
        document.getElementById('exp-item-note').value      = '';
        // Apply default currency (smart default → fallback to base currency)
        var defaultCurrency = defs.currencyCode || report.baseCurrencyCode || '';
        document.getElementById('exp-item-currency').value = defaultCurrency;
        // Apply default project after dropdown rebuild
        if (defs.projectId) {
            document.getElementById('exp-item-project').value = defs.projectId;
        }
    }

    // Show/hide auto-fill badge (4)
    var badge = document.getElementById('exp-rate-autofill-badge');
    if (badge) badge.style.display = 'none';

    // Clear previous validation state and set future-date guard
    expClearAllFieldErrors();
    document.getElementById('exp-item-date').max = new Date().toISOString().substring(0, 10);

    document.getElementById('exp-item-amount').focus();
    wrap.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
}

function expHideItemForm() {
    var wrap = document.getElementById('exp-item-form-wrap');
    if (wrap) wrap.style.display = 'none';
    expClearAllFieldErrors();
}

function expPopulateCurrencyDropdown(selId) {
    var sel = document.getElementById(selId);
    if (!sel) return;
    var cur = sel.value;
    sel.innerHTML = '<option value="">-- Select --</option>';
    // Use new picklist storage; fall back to old prowess-currencies
    var items = plQueryScript('CURRENCY', {activeOnly: true});
    if (items.length) {
        items.forEach(function(item) {
            var code   = item.meta && item.meta.code   ? item.meta.code   : item.value;
            var symbol = item.meta && item.meta.symbol ? item.meta.symbol : '';
            var o = document.createElement('option');
            o.value = code;
            o.textContent = code + ' \u2013 ' + item.value + (symbol ? ' (' + symbol + ')' : '');
            sel.appendChild(o);
        });
    } else {
        var currencies = JSON.parse(localStorage.getItem('prowess-currencies') || '[]');
        currencies.filter(function(c) { return c.active !== false; }).forEach(function(c) {
            var o = document.createElement('option');
            o.value = c.code;
            o.textContent = c.code + ' \u2013 ' + c.name + ' (' + c.symbol + ')';
            sel.appendChild(o);
        });
    }
    sel.value = cur;
}

/**
 * Populate a category <select> from Reference Data (Expense_Category).
 * option.value = item.id  (category_id — source of truth)
 * option.text  = item.value (category_name — display only)
 * Preserves current selection across rebuilds.
 */
function expPopulateCategoryDropdown(selId) {
    var sel = document.getElementById(selId);
    if (!sel) return;
    var prevVal = sel.value;
    sel.innerHTML = '<option value="">-- Select --</option>';
    var items = plQueryScript('Expense_Category', { activeOnly: true });
    items.forEach(function (item) {
        var o = document.createElement('option');
        o.value = String(item.id);
        o.textContent = item.value;
        sel.appendChild(o);
    });
    if (prevVal) sel.value = prevVal;
}

/**
 * Resolve a category_id to its display name.
 * First checks stored name, then falls back to live Reference Data lookup.
 * Appends "(Inactive)" if the picklist value exists but is disabled.
 */
function expResolveCategoryName(categoryId, storedName) {
    if (!categoryId) return storedName || '—';
    var all = plValsScript().filter(function (v) { return v.picklistId === 'Expense_Category'; });
    var match = all.find(function (v) { return String(v.id) === String(categoryId); });
    if (match) return match.value + (match.active === false ? ' (Inactive)' : '');
    return storedName || '—';
}

function expPopulateProjectDropdown(selId, dateStr) {
    var sel      = document.getElementById(selId);
    if (!sel) return;
    var prevVal  = sel.value;   // preserve current selection across rebuilds
    var projects = JSON.parse(localStorage.getItem('prowess-projects') || '[]');
    sel.innerHTML = '<option value="">-- None --</option>';
    var active = projects.filter(function (p) {
        if (!dateStr) return true;
        return dateStr >= (p.startDate || '') && dateStr <= (p.endDate || '9999-12-31');
    });
    active.forEach(function (p) {
        var o = document.createElement('option');
        o.value = String(p.id);   // always string so select.value comparison works
        o.textContent = p.name;
        sel.appendChild(o);
    });
    // Restore previous selection if that project is still in the rebuilt list
    if (prevVal) sel.value = prevVal;
}

function expAutoFillRate() {
    var report = expGetReports().find(function (r) { return r.id === expCurrentReportId; });
    if (!report) return;
    var fromCode = document.getElementById('exp-item-currency').value;
    var toCode   = report.baseCurrencyCode;
    var dateStr  = document.getElementById('exp-item-date').value;
    var rateEl   = document.getElementById('exp-item-rate');
    var convEl   = document.getElementById('exp-item-converted');

    expClearRateError();

    var badge = document.getElementById('exp-rate-autofill-badge');
    if (!fromCode || !dateStr) {
        rateEl.value = ''; convEl.value = '';
        if (badge) badge.style.display = 'none';
        return;
    }

    if (fromCode === toCode) {
        rateEl.value = 1;
        if (badge) badge.style.display = 'none';
        expRecalcConverted();
        return;
    }

    var rate = expLookupRate(fromCode, toCode, dateStr);
    if (rate === null) {
        rateEl.value = '';
        convEl.value = '';
        if (badge) badge.style.display = 'none';
        expShowRateError('No exchange rate found for ' + fromCode + ' → ' + toCode + ' on or before ' + dateStr + '. Please add a rate in Admin → Exchange Rates.');
    } else {
        rateEl.value = rate;
        if (badge) badge.style.display = (fromCode !== toCode) ? 'inline-flex' : 'none';
        expRecalcConverted();
    }
}

function expRecalcConverted() {
    var amount  = parseFloat(document.getElementById('exp-item-amount').value);
    var rate    = parseFloat(document.getElementById('exp-item-rate').value);
    var convEl  = document.getElementById('exp-item-converted');
    if (!isNaN(amount) && !isNaN(rate)) {
        convEl.value = (amount * rate).toFixed(2);
    } else {
        convEl.value = '';
    }
}

function expShowRateError(msg) {
    expSetFieldError('exp-item-rate', msg);
}

function expClearRateError() {
    expClearFieldError('exp-item-rate');
}

// ── Inline field-level validation helpers ────────────────────────────
// Maps field IDs (e.g. "exp-item-category") to error spans (e.g. "exp-err-category")
// and toggles the form-group--error class on the parent container.

function expSetFieldError(fieldId, msg) {
    var inputEl = document.getElementById(fieldId);
    var suffix  = fieldId.replace('exp-item-', '');
    var errEl   = document.getElementById('exp-err-' + suffix);
    if (inputEl) {
        var group = inputEl.closest('.form-group');
        if (group) group.classList.add('form-group--error');
    }
    if (errEl) { errEl.textContent = msg; errEl.style.display = 'block'; }
}

function expClearFieldError(fieldId) {
    var inputEl = document.getElementById(fieldId);
    var suffix  = fieldId.replace('exp-item-', '');
    var errEl   = document.getElementById('exp-err-' + suffix);
    if (inputEl) {
        var group = inputEl.closest('.form-group');
        if (group) group.classList.remove('form-group--error');
    }
    if (errEl) { errEl.textContent = ''; errEl.style.display = 'none'; }
}

function expClearAllFieldErrors() {
    ['category', 'date', 'project', 'currency', 'amount', 'rate', 'note'].forEach(function (f) {
        expClearFieldError('exp-item-' + f);
    });
    var dup = document.getElementById('exp-dup-warning');
    if (dup) dup.style.display = 'none';
}

function expSaveLineItem() {
    var report = expGetReports().find(function (r) { return r.id === expCurrentReportId; });
    if (!report) return;

    var catSel       = document.getElementById('exp-item-category');
    var categoryId   = catSel.value;                                            // source of truth
    var categoryName = catSel.options[catSel.selectedIndex]
                        ? catSel.options[catSel.selectedIndex].textContent.trim()
                        : '';                                                    // display snapshot
    var date         = document.getElementById('exp-item-date').value;
    var projectId    = document.getElementById('exp-item-project').value;
    var currencyCode = document.getElementById('exp-item-currency').value;
    var amount       = parseFloat(document.getElementById('exp-item-amount').value);
    var exchangeRate = parseFloat(document.getElementById('exp-item-rate').value);
    var convertedAmount = parseFloat(document.getElementById('exp-item-converted').value);
    var note         = document.getElementById('exp-item-note').value.trim();
    var editId       = document.getElementById('exp-item-edit-id').value;

    // ── Status guard ───────────────────────────────────────────────
    if (!expIsEditable(report.status)) {
        expShowToast('This report cannot be edited in its current status.');
        return;
    }

    // ── Blocking validation ─────────────────────────────────────────
    expClearAllFieldErrors();
    var hasErrors = false;

    // 1. Category — required + must be active
    if (!categoryId) {
        expSetFieldError('exp-item-category', 'Category is required.');
        hasErrors = true;
    } else {
        var allCats   = plValsScript().filter(function (v) { return v.picklistId === 'Expense_Category'; });
        var selCat    = allCats.find(function (v) { return String(v.id) === String(categoryId); });
        if (selCat && selCat.active === false) {
            expSetFieldError('exp-item-category', 'This category is inactive. Please select an active category.');
            hasErrors = true;
        }
    }

    // 2. Date — required, not future, within optional report period
    var today = new Date().toISOString().substring(0, 10);
    if (!date) {
        expSetFieldError('exp-item-date', 'Expense date is required.');
        hasErrors = true;
    } else if (date > today) {
        expSetFieldError('exp-item-date', 'Expense date cannot be in the future.');
        hasErrors = true;
    } else if (report.startDate && date < report.startDate) {
        expSetFieldError('exp-item-date', 'Date is before the report period start (' + report.startDate + ').');
        hasErrors = true;
    } else if (report.endDate && date > report.endDate) {
        expSetFieldError('exp-item-date', 'Date is after the report period end (' + report.endDate + ').');
        hasErrors = true;
    }

    // 3. Currency — required
    if (!currencyCode) {
        expSetFieldError('exp-item-currency', 'Currency is required.');
        hasErrors = true;
    }

    // 4. Amount — required, > 0, numeric
    var rawAmtEl = document.getElementById('exp-item-amount');
    if (!rawAmtEl.value.trim()) {
        expSetFieldError('exp-item-amount', 'Amount is required.');
        hasErrors = true;
    } else if (isNaN(amount) || amount <= 0) {
        expSetFieldError('exp-item-amount', 'Amount must be greater than zero.');
        hasErrors = true;
    }

    // 5. Exchange rate — required when currency differs from base
    if (currencyCode && currencyCode !== report.baseCurrencyCode) {
        if (isNaN(exchangeRate) || exchangeRate <= 0) {
            expSetFieldError('exp-item-rate',
                'No exchange rate found for ' + currencyCode + ' → ' + report.baseCurrencyCode +
                ' on this date. Add a rate via Admin → Exchange Rates.');
            hasErrors = true;
        }
    } else {
        exchangeRate    = 1;
        convertedAmount = amount;
    }

    // 6. Project required for specific categories (configurable)
    if (!projectId && categoryId &&
        EXP_VALIDATION_CONFIG.requireProjectForCategories.indexOf(String(categoryId)) !== -1) {
        expSetFieldError('exp-item-project', 'A project is required for this category.');
        hasErrors = true;
    }

    // 7. Note required for high-value amounts (configurable threshold)
    if (!isNaN(amount) && amount > EXP_VALIDATION_CONFIG.noteRequiredAbove && !note) {
        expSetFieldError('exp-item-note',
            'A note is required for expenses over ' + EXP_VALIDATION_CONFIG.noteRequiredAbove + '.');
        hasErrors = true;
    }

    if (hasErrors) return;

    // ── Non-blocking: duplicate detection ─────────────────────────
    var isDuplicate = (report.lineItems || []).some(function (li) {
        return String(li.id) !== String(editId) &&
               li.date === date &&
               String(li.category_id) === String(categoryId) &&
               parseFloat(li.amount) === amount;
    });
    var dupWarn = document.getElementById('exp-dup-warning');
    if (dupWarn) dupWarn.style.display = isDuplicate ? 'flex' : 'none';

    var reports = expGetReports();
    var rIdx    = reports.findIndex(function (r) { return r.id === expCurrentReportId; });
    if (rIdx < 0) return;

    if (editId) {
        reports[rIdx].lineItems = (reports[rIdx].lineItems || []).map(function (li) {
            if (String(li.id) === String(editId)) {
                return {
                    id: li.id,
                    category_id: categoryId, category_name: categoryName,
                    date: date, projectId: projectId,
                    amount: amount, currencyCode: currencyCode,
                    exchangeRate: exchangeRate, convertedAmount: convertedAmount,
                    note: note
                };
            }
            return li;
        });
    } else {
        var newItem = {
            id:            'LI' + Date.now(),
            category_id:   categoryId,
            category_name: categoryName,
            date:          date,
            projectId:     projectId,
            amount:        amount,
            currencyCode:  currencyCode,
            exchangeRate:  exchangeRate,
            convertedAmount: convertedAmount,
            note:          note
        };
        reports[rIdx].lineItems = reports[rIdx].lineItems || [];
        reports[rIdx].lineItems.push(newItem);
    }

    reports[rIdx].updatedAt = new Date().toISOString();
    expSaveReports(reports);

    // Save smart defaults — store category_id as the default key (2)
    expSaveDefaults(categoryId, projectId, currencyCode);

    var savedItemId = editId || newItem && newItem.id;

    if (editId) {
        // Editing: close form, refresh
        expHideItemForm();
        expOpenReport(expCurrentReportId);
        expScrollToRow(savedItemId);
        expShowToast('Expense updated.');
    } else {
        // Quick Entry Mode (1): keep form open, reset transient fields
        var updatedReport = expGetReports().find(function(r) { return r.id === expCurrentReportId; });
        expRenderLineItems(updatedReport);
        expRenderFooter(updatedReport);
        expRenderReportList();

        // Reset transient fields; keep category/project/currency from defaults
        document.getElementById('exp-item-edit-id').value   = '';
        document.getElementById('exp-item-amount').value    = '';
        document.getElementById('exp-item-note').value      = '';
        document.getElementById('exp-item-date').value      = '';
        document.getElementById('exp-item-rate').value      = '';
        document.getElementById('exp-item-converted').value = '';
        var badge = document.getElementById('exp-rate-autofill-badge');
        if (badge) badge.style.display = 'none';
        expClearRateError();
        document.getElementById('exp-item-amount').focus();

        // Auto-scroll + flash (13)
        expScrollToRow(newItem.id);
        expShowToast('Expense added.');
    }
}

// ── Auto-scroll and row flash (13) ─────────────────────────────────
function expScrollToRow(itemId) {
    setTimeout(function () {
        var row = document.querySelector('#exp-items-tbody tr[data-item-id="' + itemId + '"]');
        if (!row) return;
        row.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
        row.classList.add('exp-row-flash');
        setTimeout(function () { row.classList.remove('exp-row-flash'); }, 1600);
    }, 60);
}

// ── Report-level actions ───────────────────────────────────────────

function expSaveReportName() {
    var name = (document.getElementById('exp-report-name-input').value || '').trim();
    if (!name) { alert('Please enter a report name.'); return; }
    var reports = expGetReports();
    var rIdx    = reports.findIndex(function (r) { return r.id === expCurrentReportId; });
    if (rIdx < 0) return;
    reports[rIdx].name      = name;
    reports[rIdx].updatedAt = new Date().toISOString();
    expSaveReports(reports);
    expRenderReportList();
    expShowToast('Report saved.');
}

// ── Submit Confirmation Strip (8) ─────────────────────────────────
function expSubmitReport() {
    expShowSubmitConfirm();
}

function expShowSubmitConfirm() {
    var strip = document.getElementById('exp-submit-confirm-strip');
    if (!strip) return;
    strip.style.display = 'flex';
    strip.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
}

function expHideSubmitConfirm() {
    var strip = document.getElementById('exp-submit-confirm-strip');
    if (strip) strip.style.display = 'none';
}

// ── Delete Report Confirmation (draft only) ────────────────────────
var expPendingDeleteId = null;

function expShowDeleteConfirm(reportId) {
    expPendingDeleteId = reportId;
    var report = expGetReports().find(function (r) { return r.id === reportId; });
    var name   = report ? (report.name || 'this report') : 'this report';
    var msg    = document.getElementById('exp-delete-confirm-msg');
    if (msg) msg.innerHTML = 'Delete <strong>' + expEsc(name) + '</strong> — this cannot be undone.';
    var strip  = document.getElementById('exp-delete-confirm-strip');
    if (strip) {
        strip.style.display = 'flex';
        strip.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
    }
}

function expHideDeleteConfirm() {
    expPendingDeleteId = null;
    var strip = document.getElementById('exp-delete-confirm-strip');
    if (strip) strip.style.display = 'none';
}

function expConfirmDeleteReport() {
    if (!expPendingDeleteId) return;
    var reports = expGetReports();
    var report  = reports.find(function (r) { return r.id === expPendingDeleteId; });
    // Safety guard: only allow deleting draft reports
    if (!report || report.status !== 'draft') { expHideDeleteConfirm(); return; }
    var name = report.name || 'Report';
    expSaveReports(reports.filter(function (r) { return r.id !== expPendingDeleteId; }));
    expHideDeleteConfirm();
    expRenderReportList();
    expShowToast('\u201c' + name + '\u201d deleted.');
}

function expConfirmSubmit() {
    expHideSubmitConfirm();
    var name = (document.getElementById('exp-report-name-input').value || '').trim();
    var reports = expGetReports();
    var rIdx    = reports.findIndex(function (r) { return r.id === expCurrentReportId; });
    if (rIdx < 0) return;
    reports[rIdx].name        = name || reports[rIdx].name;
    reports[rIdx].status      = 'submitted';
    reports[rIdx].submittedAt = new Date().toISOString();
    reports[rIdx].updatedAt   = new Date().toISOString();
    expSaveReports(reports);
    expOpenReport(expCurrentReportId);
    expShowToast('Report submitted for approval.');
}

// ── Format ISO date → "05-Apr-2026" ──────────────────────────────
function expFmtDate(isoStr) {
    if (!isoStr) return '—';
    var d  = new Date(isoStr);
    if (isNaN(d.getTime())) return '—';
    var mo = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    var dd = String(d.getDate()).padStart(2, '0');
    return dd + '-' + mo[d.getMonth()] + '-' + d.getFullYear();
}

// ── Render approval flow stepper ─────────────────────────────────
// Nodes: Submitted → Manager → HR → Finance
// Status mapping:
//   draft / rejected → "Submitted" pending, all others pending
//   submitted        → "Submitted" done, Manager active (pending), HR/Finance pending
//   approved         → all done (green)
function expRenderApprovalFlow(status) {
    var el = document.getElementById('exp-approval-flow');
    if (!el) return;

    var nodes = [
        { key: 'submitted', label: 'Submitted' },
        { key: 'manager',   label: 'Manager'   },
        { key: 'hr',        label: 'HR'         },
        { key: 'finance',   label: 'Finance'    }
    ];

    // Determine how many nodes are "done" and which is "active"
    // draft / rejected: 0 done, none active
    // submitted:        1 done ("Submitted"), index 1 active ("Manager")
    // approved:         4 done, none active
    var doneCount  = 0;
    var activeIdx  = -1;
    if (status === 'submitted') { doneCount = 1; activeIdx = 1; }
    if (status === 'approved')  { doneCount = 4; }

    var html = '<div class="exp-flow-steps">';
    nodes.forEach(function(node, i) {
        var done   = i < doneCount;
        var active = i === activeIdx;
        var cls    = done   ? 'exp-flow-step--done'
                   : active ? 'exp-flow-step--active'
                   :          'exp-flow-step--pending';
        var icon   = done   ? 'fa-circle-check'
                   : active ? 'fa-circle-dot'
                   :          'fa-circle';

        html += '<div class="exp-flow-step ' + cls + '">' +
                    '<i class="fa-solid ' + icon + '"></i>' +
                    '<span>' + node.label + '</span>' +
                '</div>';

        if (i < nodes.length - 1) {
            html += '<div class="exp-flow-connector' +
                    (i < doneCount - 1 ? ' exp-flow-connector--done' : '') +
                    '"></div>';
        }
    });
    html += '</div>';
    el.innerHTML = html;
}

// ── Default report name: "April 2026 Expenses" ───────────────────
function expDefaultReportName() {
    var d = new Date();
    var months = ['January','February','March','April','May','June',
                  'July','August','September','October','November','December'];
    return months[d.getMonth()] + ' ' + d.getFullYear() + ' Expenses';
}

// ── Modal: show ───────────────────────────────────────────────────
function expShowCreateModal() {
    var emp = expGetCurrentEmployee();
    if (!emp) {
        expShowToast('No employee profile found. Please set up your profile first.');
        return;
    }
    var modal    = document.getElementById('exp-create-modal');
    var nameInput = document.getElementById('exp-modal-name');
    var descInput = document.getElementById('exp-modal-desc');
    var errEl     = document.getElementById('exp-modal-name-err');
    nameInput.value  = expDefaultReportName();
    descInput.value  = '';
    errEl.style.display = 'none';
    nameInput.classList.remove('exp-modal-input--error');
    modal.style.display = 'flex';
    requestAnimationFrame(function () {
        modal.classList.add('exp-modal--open');
        nameInput.focus();
        nameInput.select();
    });
}

// ── Modal: hide ───────────────────────────────────────────────────
function expHideCreateModal() {
    var modal = document.getElementById('exp-create-modal');
    modal.classList.remove('exp-modal--open');
    modal.addEventListener('transitionend', function handler() {
        modal.style.display = 'none';
        modal.removeEventListener('transitionend', handler);
    });
}

// ── Modal: create ─────────────────────────────────────────────────
function expCreateNewReport() {
    var emp       = expGetCurrentEmployee();
    var nameInput = document.getElementById('exp-modal-name');
    var descInput = document.getElementById('exp-modal-desc');
    var errEl     = document.getElementById('exp-modal-name-err');
    var name      = (nameInput.value || '').trim();

    // Validation
    if (!name) {
        nameInput.classList.add('exp-modal-input--error');
        errEl.style.display = 'flex';
        nameInput.focus();
        return;
    }
    nameInput.classList.remove('exp-modal-input--error');
    errEl.style.display = 'none';

    var reports   = expGetReports();
    var newReport = {
        id:               'RPT' + Date.now(),
        employeeId:       emp.employeeId,
        name:             name,
        description:      (descInput.value || '').trim(),
        status:           'draft',
        baseCurrencyCode: emp.baseCurrencyCode || 'INR',
        createdAt:        new Date().toISOString(),
        updatedAt:        new Date().toISOString(),
        lineItems:        [],
    };
    reports.push(newReport);
    expSaveReports(reports);
    expHideCreateModal();
    expRenderReportList();
    expOpenReport(newReport.id);
    expShowToast('Report "' + name + '" created.');
}

// ── Inline rename in list ─────────────────────────────────────────
function expStartInlineRename(reportId) {
    var reports = expGetReports();
    var report  = reports.find(function (r) { return r.id === reportId; });
    if (!report || report.status !== 'draft') return;

    var nameCell = document.querySelector(
        '.exp-report-row[data-report-id="' + reportId + '"] .exp-report-name-text'
    );
    if (!nameCell) return;
    var currentName = report.name || '';
    var parent      = nameCell.parentElement;

    // Replace text + rename btn with an inline input
    parent.innerHTML =
        '<input class="exp-inline-rename-input" id="exp-inline-rename-' + reportId + '" ' +
               'type="text" value="' + expEsc(currentName) + '" maxlength="100" />' +
        '<button class="exp-inline-rename-save" data-rid="' + reportId + '" title="Save"><i class="fa-solid fa-check"></i></button>' +
        '<button class="exp-inline-rename-cancel" data-rid="' + reportId + '" title="Cancel"><i class="fa-solid fa-xmark"></i></button>';

    var input = document.getElementById('exp-inline-rename-' + reportId);
    input.focus();
    input.select();

    function doSave() {
        var newName = input.value.trim();
        if (!newName) { input.focus(); return; }
        var rpts = expGetReports();
        var idx  = rpts.findIndex(function (r) { return r.id === reportId; });
        if (idx >= 0) {
            rpts[idx].name      = newName;
            rpts[idx].updatedAt = new Date().toISOString();
            expSaveReports(rpts);
        }
        expRenderReportList();
        expShowToast('Report renamed.');
    }

    function doCancel() { expRenderReportList(); }

    input.addEventListener('keydown', function (e) {
        if (e.key === 'Enter')  { e.preventDefault(); doSave(); }
        if (e.key === 'Escape') { e.preventDefault(); doCancel(); }
    });
    parent.querySelector('.exp-inline-rename-save').addEventListener('click',   doSave);
    parent.querySelector('.exp-inline-rename-cancel').addEventListener('click', doCancel);
}

// ── Expandable Row Edit (6) ────────────────────────────────────────
var expActiveExpandId = null;

function expCloseExpandEdit() {
    if (expActiveExpandId) {
        var old = document.getElementById('exp-expand-edit-' + expActiveExpandId);
        if (old) old.parentNode.removeChild(old);
        expActiveExpandId = null;
    }
}

function expStartExpandEdit(itemId) {
    var report = expGetReports().find(function (r) { return r.id === expCurrentReportId; });
    if (!report) return;
    var item = (report.lineItems || []).find(function (li) { return String(li.id) === String(itemId); });
    if (!item) return;

    // Close any existing expand row and the add form
    expCloseExpandEdit();
    expHideItemForm();

    expActiveExpandId = itemId;

    // Find host row by data-item-id
    var hostRow = document.querySelector('#exp-items-tbody tr[data-item-id="' + itemId + '"]');
    if (!hostRow) return;

    // Build category options (active only; add current item's category even if inactive)
    var activeCats = plQueryScript('Expense_Category', { activeOnly: true });
    var allCats    = plValsScript().filter(function (v) { return v.picklistId === 'Expense_Category'; });
    var catOptions = '<option value="">-- Select --</option>';
    activeCats.forEach(function (ci) {
        var sel = (String(ci.id) === String(item.category_id)) ? ' selected' : '';
        catOptions += '<option value="' + ci.id + '"' + sel + '>' + expEsc(ci.value) + '</option>';
    });
    // If the stored category_id is inactive, append it so the edit form still shows it
    if (item.category_id && !activeCats.find(function (ci) { return String(ci.id) === String(item.category_id); })) {
        var inactiveCat = allCats.find(function (v) { return String(v.id) === String(item.category_id); });
        if (inactiveCat) {
            catOptions += '<option value="' + inactiveCat.id + '" selected>' + expEsc(inactiveCat.value) + ' (Inactive)</option>';
        }
    }

    // Build currencies options
    var currItems = plQueryScript('CURRENCY', {activeOnly: true});
    var currOptions = '<option value="">-- Select --</option>';
    currItems.forEach(function (ci) {
        var code = ci.meta && ci.meta.code ? ci.meta.code : ci.value;
        var sel = (code === item.currencyCode) ? ' selected' : '';
        currOptions += '<option value="' + code + '"' + sel + '>' + code + ' \u2013 ' + ci.value + '</option>';
    });
    if (!currItems.length) {
        var currencies = JSON.parse(localStorage.getItem('prowess-currencies') || '[]');
        currencies.filter(function(c){ return c.active !== false; }).forEach(function(c){
            var sel = (c.code === item.currencyCode) ? ' selected' : '';
            currOptions += '<option value="' + c.code + '"' + sel + '>' + c.code + ' \u2013 ' + c.name + '</option>';
        });
    }

    // Build projects options
    var projects = JSON.parse(localStorage.getItem('prowess-projects') || '[]');
    var projOptions = '<option value="">-- None --</option>';
    projects.filter(function(p){ return p.active !== false; }).forEach(function(p){
        var sel = (String(p.id) === String(item.projectId)) ? ' selected' : '';
        projOptions += '<option value="' + String(p.id) + '"' + sel + '>' + expEsc(p.name) + '</option>';
    });

    var expandRow = document.createElement('tr');
    expandRow.id        = 'exp-expand-edit-' + itemId;
    expandRow.className = 'exp-expand-edit-row';
    expandRow.innerHTML =
        '<td colspan="10">' +
            '<div class="exp-expand-form">' +
                '<div class="exp-expand-form-grid">' +
                    '<div class="form-group">' +
                        '<label>Category</label>' +
                        '<select class="exp-expand-cat">' + catOptions + '</select>' +
                    '</div>' +
                    '<div class="form-group">' +
                        '<label>Date</label>' +
                        '<input type="date" class="exp-expand-date" value="' + (item.date || '') + '" />' +
                    '</div>' +
                    '<div class="form-group">' +
                        '<label>Project</label>' +
                        '<select class="exp-expand-project">' + projOptions + '</select>' +
                    '</div>' +
                    '<div class="form-group">' +
                        '<label>Currency</label>' +
                        '<select class="exp-expand-currency">' + currOptions + '</select>' +
                    '</div>' +
                    '<div class="form-group">' +
                        '<label>Amount</label>' +
                        '<input type="number" class="exp-expand-amount" value="' + (item.amount || '') + '" min="0.01" step="any" />' +
                    '</div>' +
                    '<div class="form-group">' +
                        '<label>Exchange Rate <span class="exp-expand-rate-badge" style="display:none;">Auto-filled</span></label>' +
                        '<input type="number" class="exp-rate-input exp-expand-rate" readonly value="' + (item.exchangeRate || '') + '" />' +
                    '</div>' +
                    '<div class="form-group">' +
                        '<label>Converted (' + expEsc(report.baseCurrencyCode || '—') + ')</label>' +
                        '<input type="number" class="exp-rate-input exp-expand-converted" readonly value="' + (item.convertedAmount || '') + '" />' +
                    '</div>' +
                    '<div class="form-group exp-note-group">' +
                        '<label>Note</label>' +
                        '<input type="text" class="exp-expand-note" value="' + expEsc(item.note || '') + '" placeholder="Optional" />' +
                    '</div>' +
                '</div>' +
                '<div id="exp-expand-rate-error-' + itemId + '" class="exp-rate-error" style="display:none;"></div>' +
                '<div class="exp-expand-actions">' +
                    '<button class="exp-btn-save-item exp-expand-save-btn" data-item-id="' + itemId + '">' +
                        '<i class="fa-solid fa-floppy-disk"></i> Save' +
                    '</button>' +
                    '<button class="exp-btn-cancel-item exp-expand-cancel-btn" data-item-id="' + itemId + '">' +
                        'Cancel' +
                    '</button>' +
                '</div>' +
            '</div>' +
        '</td>';

    hostRow.insertAdjacentElement('afterend', expandRow);

    // Wire up live recalc inside expand row
    var catEl      = expandRow.querySelector('.exp-expand-cat');
    var dateEl     = expandRow.querySelector('.exp-expand-date');
    var currEl     = expandRow.querySelector('.exp-expand-currency');
    var amtEl      = expandRow.querySelector('.exp-expand-amount');
    var rateEl     = expandRow.querySelector('.exp-expand-rate');
    var convEl     = expandRow.querySelector('.exp-expand-converted');
    var rateBadge  = expandRow.querySelector('.exp-expand-rate-badge');
    var rateErrEl  = document.getElementById('exp-expand-rate-error-' + itemId);

    function expandAutoFillRate() {
        var fromCode = currEl.value;
        var toCode   = report.baseCurrencyCode;
        var dateStr  = dateEl.value;
        if (rateErrEl) { rateErrEl.textContent = ''; rateErrEl.style.display = 'none'; }
        if (!fromCode || !dateStr) { rateEl.value = ''; convEl.value = ''; if (rateBadge) rateBadge.style.display = 'none'; return; }
        if (fromCode === toCode) { rateEl.value = 1; if (rateBadge) rateBadge.style.display = 'none'; expandRecalc(); return; }
        var rate = expLookupRate(fromCode, toCode, dateStr);
        if (rate === null) {
            rateEl.value = ''; convEl.value = '';
            if (rateBadge) rateBadge.style.display = 'none';
            if (rateErrEl) { rateErrEl.textContent = 'No rate for ' + fromCode + ' → ' + toCode + ' on ' + dateStr; rateErrEl.style.display = 'block'; }
        } else {
            rateEl.value = rate;
            if (rateBadge) rateBadge.style.display = 'inline-flex';
            expandRecalc();
        }
    }

    function expandRecalc() {
        var amt  = parseFloat(amtEl.value);
        var rate = parseFloat(rateEl.value);
        convEl.value = (!isNaN(amt) && !isNaN(rate)) ? (amt * rate).toFixed(2) : '';
    }

    currEl.addEventListener('change', expandAutoFillRate);
    dateEl.addEventListener('change', expandAutoFillRate);
    amtEl.addEventListener('input', expandRecalc);

    expandRow.querySelector('.exp-expand-save-btn').addEventListener('click', function () {
        expSaveExpandEdit(itemId);
    });
    expandRow.querySelector('.exp-expand-cancel-btn').addEventListener('click', expCloseExpandEdit);

    expandRow.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
}

function expSaveExpandEdit(itemId) {
    var report = expGetReports().find(function (r) { return r.id === expCurrentReportId; });
    if (!report) return;
    var expandRow = document.getElementById('exp-expand-edit-' + itemId);
    if (!expandRow) return;

    var catSel       = expandRow.querySelector('.exp-expand-cat');
    var categoryId   = catSel.value;
    var categoryName = catSel.options[catSel.selectedIndex]
                        ? catSel.options[catSel.selectedIndex].textContent.replace(' (Inactive)', '').trim()
                        : '';
    var date         = expandRow.querySelector('.exp-expand-date').value;
    var projectId    = expandRow.querySelector('.exp-expand-project').value;
    var currencyCode = expandRow.querySelector('.exp-expand-currency').value;
    var amount       = parseFloat(expandRow.querySelector('.exp-expand-amount').value);
    var exchangeRate = parseFloat(expandRow.querySelector('.exp-expand-rate').value);
    var convertedAmount = parseFloat(expandRow.querySelector('.exp-expand-converted').value);
    var note         = expandRow.querySelector('.exp-expand-note').value.trim();
    var rateErrEl    = document.getElementById('exp-expand-rate-error-' + itemId);

    if (!categoryId) { if (rateErrEl) { rateErrEl.textContent = 'Category is required.'; rateErrEl.style.display = 'block'; } return; }
    if (!date)       { if (rateErrEl) { rateErrEl.textContent = 'Date is required.'; rateErrEl.style.display = 'block'; } return; }
    if (!currencyCode) { if (rateErrEl) { rateErrEl.textContent = 'Currency is required.'; rateErrEl.style.display = 'block'; } return; }
    if (isNaN(amount) || amount <= 0) { if (rateErrEl) { rateErrEl.textContent = 'Valid amount required.'; rateErrEl.style.display = 'block'; } return; }

    if (currencyCode === report.baseCurrencyCode) {
        exchangeRate = 1; convertedAmount = amount;
    } else if (isNaN(exchangeRate) || exchangeRate <= 0) {
        if (rateErrEl) { rateErrEl.textContent = 'No exchange rate available. Add one in Admin → Exchange Rates.'; rateErrEl.style.display = 'block'; }
        return;
    }

    var reports = expGetReports();
    var rIdx    = reports.findIndex(function (r) { return r.id === expCurrentReportId; });
    if (rIdx < 0) return;

    reports[rIdx].lineItems = (reports[rIdx].lineItems || []).map(function (li) {
        if (String(li.id) === String(itemId)) {
            return {
                id:            li.id,
                category_id:   categoryId,
                category_name: categoryName,
                date:          date,
                projectId:     projectId,
                amount:        amount,
                currencyCode:  currencyCode,
                exchangeRate:  exchangeRate,
                convertedAmount: convertedAmount,
                note:          note
            };
        }
        return li;
    });
    reports[rIdx].updatedAt = new Date().toISOString();
    expSaveReports(reports);
    expSaveDefaults(categoryId, projectId, currencyCode);

    expCloseExpandEdit();
    var updated = expGetReports().find(function (r) { return r.id === expCurrentReportId; });
    expRenderLineItems(updated);
    expRenderFooter(updated);
    expRenderReportList();
    expScrollToRow(itemId);
    expShowToast('Expense updated.');
}

// ── Modal event wiring ────────────────────────────────────────────
document.getElementById('exp-modal-create').addEventListener('click', expCreateNewReport);
document.getElementById('exp-modal-cancel').addEventListener('click', expHideCreateModal);
document.getElementById('exp-modal-close').addEventListener('click',  expHideCreateModal);

// Click outside card → close
document.getElementById('exp-create-modal').addEventListener('click', function (e) {
    if (e.target === this) expHideCreateModal();
});

// Keyboard: Enter (from name field) → create; Esc → close
document.getElementById('exp-modal-name').addEventListener('keydown', function (e) {
    if (e.key === 'Enter')  { e.preventDefault(); expCreateNewReport(); }
    if (e.key === 'Escape') { e.preventDefault(); expHideCreateModal(); }
});
document.getElementById('exp-modal-desc').addEventListener('keydown', function (e) {
    if (e.key === 'Escape') { e.preventDefault(); expHideCreateModal(); }
});

// Clear error state as user types
document.getElementById('exp-modal-name').addEventListener('input', function () {
    if (this.value.trim()) {
        this.classList.remove('exp-modal-input--error');
        document.getElementById('exp-modal-name-err').style.display = 'none';
    }
});

function expShowToast(msg) {
    var t = document.getElementById('export-toast');
    if (!t) return;
    var textEl = document.getElementById('export-toast-text');
    if (textEl) { textEl.textContent = msg; } else { t.textContent = msg; }
    t.classList.add('export-toast--show');
    clearTimeout(expShowToast._timer);
    expShowToast._timer = setTimeout(function () { t.classList.remove('export-toast--show'); }, 2800);
}

// ── Smart Defaults (2) ────────────────────────────────────────────
function expLoadDefaults() {
    try { return JSON.parse(localStorage.getItem('prowess-exp-defaults') || 'null') || {}; }
    catch (e) { return {}; }
}
function expSaveDefaults(categoryId, projectId, currencyCode) {
    var obj = {};
    if (categoryId)   obj.category_id  = categoryId;
    if (projectId)    obj.projectId    = projectId;
    if (currencyCode) obj.currencyCode = currencyCode;
    localStorage.setItem('prowess-exp-defaults', JSON.stringify(obj));
}

function expEsc(str) {
    return String(str || '').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
}

// ── Called when My Expense tab is activated ────────────────────────
function renderMyExpense() {
    if (expCurrentReportId) {
        var reports = expGetReports();
        var still   = reports.find(function (r) { return r.id === expCurrentReportId; });
        if (still) {
            expOpenReport(expCurrentReportId);
            return;
        }
        expCurrentReportId = null;
    }
    expRenderReportList();
    document.getElementById('exp-report-list-panel').style.display = 'block';
    document.getElementById('exp-report-detail').style.display     = 'none';
}

// ── Event wiring ───────────────────────────────────────────────────

document.getElementById('exp-btn-new-report').addEventListener('click', function () {
    expHideDeleteConfirm();
    expShowCreateModal();
});

document.getElementById('exp-report-tbody').addEventListener('click', function (e) {
    // Rename button
    var renameBtn = e.target.closest('.exp-rename-btn');
    if (renameBtn) {
        e.stopPropagation();
        expHideDeleteConfirm();
        expStartInlineRename(renameBtn.getAttribute('data-report-id'));
        return;
    }
    // Delete button — show confirmation strip (draft only)
    var deleteBtn = e.target.closest('.exp-delete-report-btn');
    if (deleteBtn) {
        e.stopPropagation();
        expShowDeleteConfirm(deleteBtn.getAttribute('data-report-id'));
        return;
    }
    // Row click — open report
    var row = e.target.closest('.exp-report-row');
    if (row) {
        expHideDeleteConfirm();
        expOpenReport(row.getAttribute('data-report-id'));
    }
});

// Delete confirmation strip button wiring
document.getElementById('exp-delete-yes-btn').addEventListener('click', expConfirmDeleteReport);
document.getElementById('exp-delete-cancel-btn').addEventListener('click', expHideDeleteConfirm);

document.getElementById('exp-btn-back').addEventListener('click', expCloseDetail);

document.getElementById('exp-btn-add-item').addEventListener('click', function () {
    expCloseExpandEdit();
    expHideItemForm();
    expShowItemForm(null);
});

document.getElementById('exp-btn-save-item').addEventListener('click', expSaveLineItem);
document.getElementById('exp-btn-cancel-item').addEventListener('click', expHideItemForm);

document.getElementById('exp-items-tbody').addEventListener('click', function (e) {
    var reports = expGetReports();
    var report  = reports.find(function (r) { return r.id === expCurrentReportId; });
    if (!report) return;

    var editBtn   = e.target.closest('.exp-item-edit-btn');
    var deleteBtn = e.target.closest('.exp-item-delete-btn');
    var dupBtn    = e.target.closest('.exp-item-dup-btn');

    // Edit → expandable row (6)
    if (editBtn) {
        var itemId = editBtn.getAttribute('data-item-id');
        expHideItemForm();
        expStartExpandEdit(itemId);
        return;
    }

    // Duplicate (5): pre-fill form with copied values, leave amount/date blank
    if (dupBtn) {
        var dupItemId = dupBtn.getAttribute('data-item-id');
        var srcItem   = (report.lineItems || []).find(function (li) { return String(li.id) === String(dupItemId); });
        if (!srcItem) return;
        expCloseExpandEdit();
        expHideItemForm();
        // Show the add form with copied values
        expShowItemForm(null);
        // Override with duplicated values (keep category/project/currency/note, clear amount/date)
        // Use category_id as the option value — source of truth
        document.getElementById('exp-item-category').value = srcItem.category_id ? String(srcItem.category_id) : '';
        document.getElementById('exp-item-project').value  = srcItem.projectId ? String(srcItem.projectId) : '';
        document.getElementById('exp-item-currency').value = srcItem.currencyCode || '';
        document.getElementById('exp-item-note').value     = srcItem.note || '';
        document.getElementById('exp-item-amount').value   = '';
        document.getElementById('exp-item-date').value     = '';
        document.getElementById('exp-item-rate').value     = '';
        document.getElementById('exp-item-converted').value = '';
        var badge = document.getElementById('exp-rate-autofill-badge');
        if (badge) badge.style.display = 'none';
        expClearRateError();
        document.getElementById('exp-item-amount').focus();
        return;
    }

    if (deleteBtn) {
        if (!confirm('Delete this expense line?')) return;
        expCloseExpandEdit();
        var itemId2  = deleteBtn.getAttribute('data-item-id');
        var rIdx     = reports.findIndex(function (r) { return r.id === expCurrentReportId; });
        reports[rIdx].lineItems = (reports[rIdx].lineItems || []).filter(function (li) { return String(li.id) !== String(itemId2); });
        reports[rIdx].updatedAt = new Date().toISOString();
        expSaveReports(reports);
        expOpenReport(expCurrentReportId);
    }
});

// Submit confirmation strip button wiring (8)
document.getElementById('exp-submit-yes-btn').addEventListener('click', expConfirmSubmit);
document.getElementById('exp-submit-cancel-btn').addEventListener('click', expHideSubmitConfirm);

// Auto-fill exchange rate when currency or date changes
document.getElementById('exp-item-currency').addEventListener('change', function () {
    expClearFieldError('exp-item-currency');
    expAutoFillRate();
});
document.getElementById('exp-item-date').addEventListener('change', function () {
    expClearFieldError('exp-item-date');
    expPopulateProjectDropdown('exp-item-project', this.value);
    expAutoFillRate();
});
document.getElementById('exp-item-amount').addEventListener('input', expRecalcConverted);

// Amount blur: silently round to 2 decimal places, clear error on valid value
document.getElementById('exp-item-amount').addEventListener('blur', function () {
    var val = parseFloat(this.value);
    if (!isNaN(val) && val > 0) {
        this.value = Math.round(val * 100) / 100;  // enforce max 2dp silently
        expRecalcConverted();
        expClearFieldError('exp-item-amount');
    }
});

// Clear field errors as user corrects each field
document.getElementById('exp-item-category').addEventListener('change', function () {
    expClearFieldError('exp-item-category');
});
document.getElementById('exp-item-project').addEventListener('change', function () {
    expClearFieldError('exp-item-project');
});
document.getElementById('exp-item-note').addEventListener('input', function () {
    expClearFieldError('exp-item-note');
});

// ── TAB NAVIGATION ─────────────────────────────

// ── TAB NAVIGATION ──────────────────────────────────────────────────
const tabItems = document.querySelectorAll('.tab-item');
const tabPanels = document.querySelectorAll('.tab-panel');


tabItems.forEach(function (item) {
    item.addEventListener('click', function () {

        // Remove active from all tab items and panels
        tabItems.forEach(t => t.classList.remove('active'));
        tabPanels.forEach(p => p.classList.remove('active'));

        // Activate clicked tab and its panel
        item.classList.add('active');
        const targetTab = item.getAttribute('data-tab');
        document.getElementById('tab-' + targetTab).classList.add('active');

        if (targetTab === 'my-expense') renderMyExpense();
        if (targetTab === 'my-profile') renderMyProfile();

        document.querySelector('.content').scrollTop = 0;
    });
});


// ── PROFILE: Load and display ──────────────────

function loadProfile() {
    const profile = JSON.parse(localStorage.getItem('prowess-profile')) || null;

    if (profile) {
        document.getElementById('profile-name').textContent = profile.name || 'Employee';
        document.getElementById('profile-designation').textContent = profile.designation || '—';
        document.getElementById('profile-mobile').innerHTML =
            `<i class="fa-solid fa-phone"></i> ${profile.mobile || '—'}`;

        // Look up business email from the matching employee record
        const empList = JSON.parse(localStorage.getItem('prowess-employees') || '[]');
        const emp = empList.find(function (e) {
            if (e.employeeId && profile.employeeId)
                return String(e.employeeId) === String(profile.employeeId);
            return e.name && profile.name &&
                   e.name.trim().toLowerCase() === profile.name.trim().toLowerCase();
        });
        const emailEl = document.getElementById('profile-email');
        if (emp && emp.businessEmail) {
            emailEl.innerHTML = `<i class="fa-solid fa-envelope"></i> ${emp.businessEmail}`;
            emailEl.style.display = '';
        } else {
            emailEl.style.display = 'none';
        }

        // Load saved photo if exists
        if (profile.photo) {
            document.getElementById('profile-photo').src = profile.photo;
        } else {
            // Generate avatar from name
            const initials = profile.name.replace(' ', '+');
            document.getElementById('profile-photo').src =
                `https://ui-avatars.com/api/?name=${initials}&background=2F77B5&color=fff&size=80`;
        }
    }
}

// ── PROFILE: Photo upload ───────────────────────

document.getElementById('photo-overlay').addEventListener('click', function () {
    document.getElementById('photo-upload').click();
});

document.getElementById('photo-upload').addEventListener('change', function (event) {
    const file = event.target.files[0];
    if (!file) return;

    // Convert image to Base64 and save to localStorage
    const reader = new FileReader();
    reader.onload = function (e) {
        const base64Photo = e.target.result;

        // Update profile photo in localStorage
        const profile = JSON.parse(localStorage.getItem('prowess-profile')) || {};
        profile.photo = base64Photo;
        localStorage.setItem('prowess-profile', JSON.stringify(profile));

        // Sync photo back to the matching employee record in prowess-employees
        const empList = JSON.parse(localStorage.getItem('prowess-employees') || '[]');
        const matched = empList.findIndex(function (emp) {
            return emp.employeeId && profile.employeeId
                ? emp.employeeId === profile.employeeId
                : emp.name && profile.name && emp.name.trim().toLowerCase() === profile.name.trim().toLowerCase();
        });
        if (matched !== -1) {
            empList[matched].photo = base64Photo;
            localStorage.setItem('prowess-employees', JSON.stringify(empList));
        }

        // Update displayed photo immediately
        document.getElementById('profile-photo').src = base64Photo;
    };
    reader.readAsDataURL(file);
});

// ── Initialize on page load ─────────────────────

loadProfile();

// Defer renderMyProfile until after first browser paint
requestAnimationFrame(function () {
    renderMyProfile();
});

// Recalculate scroll-container heights once fonts + images have settled
window.addEventListener('load', function () {
    mpSetScrollHeight();
});

// ══════════════════════════════════════════════

// ═══════════════════════════════════════════════════════════════════
// ── EMPLOYEE ORG CHART  (tab: org-chart) ───────────────────────────
// ═══════════════════════════════════════════════════════════════════

// ── Avatar colour palette & helpers ────────────────────────────────
const EOC_AVATAR_PALETTE = [
    '#3b5fc0','#0f9d8a','#c0392b','#7b4fa6','#e07b00',
    '#1a7a4a','#b03060','#2980b9','#6d4c00','#336b4a'
];
function eocGetAvatarColor(name) {
    var code = (name || 'A').toUpperCase().charCodeAt(0) - 65;
    return EOC_AVATAR_PALETTE[Math.abs(code) % EOC_AVATAR_PALETTE.length];
}
function eocGetStatus(emp) {
    var today   = new Date().toISOString().split('T')[0];
    var endDate = emp.endDate  || '9999-12-31';
    var hire    = emp.hireDate || '0000-01-01';
    if (hire > today)    return 'Upcoming';
    if (endDate < today) return 'Inactive';
    return 'Active';
}
function eocFmtDate(val) {
    if (!val) return '—';
    if (val === '9999-12-31') return 'Open-ended';
    return val;
}
function eocEscHtml(str) {
    return String(str || '')
        .replace(/&/g,'&amp;').replace(/</g,'&lt;')
        .replace(/>/g,'&gt;').replace(/"/g,'&quot;');
}

// ── State ──────────────────────────────────────────────────────────
var eocMap        = {};
var eocRoots      = [];
var eocCollapsed  = new Set();
var eocSelectedId = null;
var eocFocusId    = null;
var eocZoom       = 1;
var eocPanX       = 0;
var eocPanY       = 0;
var eocDragging   = false;
var eocDragStart  = { x: 0, y: 0, px: 0, py: 0 };

// Date filter — defaults to today (ISO yyyy-mm-dd)
var eocSelectedDate = new Date().toISOString().split('T')[0];

// ── Colour palette ─────────────────────────────────────────────────
const EOC_PALETTE = [
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
var eocDeptColorMap = {};

function eocBuildColorMap() {
    eocDeptColorMap = {};
    var idx   = 0;
    var depts = JSON.parse(localStorage.getItem('prowess-departments') || '[]');
    depts.forEach(function (d) {
        if (eocDeptColorMap[d.deptId] === undefined) {
            eocDeptColorMap[d.deptId] = idx % EOC_PALETTE.length;
            idx++;
        }
    });
}
function eocColor(deptId) {
    var slot = (eocDeptColorMap[deptId] !== undefined)
        ? eocDeptColorMap[deptId]
        : EOC_PALETTE.length - 1;
    return EOC_PALETTE[slot];
}

// ── Date-filter helpers ────────────────────────────────────────────

/**
 * Returns true if the employee was active on the given ISO date string.
 * Active means: hireDate <= date AND endDate >= date.
 */
function eocIsActiveOnDate(emp, dateStr) {
    var hire = emp.hireDate || '0000-01-01';
    var end  = emp.endDate  || '9999-12-31';
    return hire <= dateStr && end >= dateStr;
}

/**
 * Resolves the nearest active manager for an employee on a given date.
 * Traverses the full hierarchy (allEmpMap) upward from emp.managerId.
 * The resolved manager must be present in activeSet.
 * Returns the employeeId of the resolved manager, or null (→ root node).
 * Uses managerCache to avoid repeated traversal.
 */
function eocResolveManager(emp, allEmpMap, activeSet, managerCache) {
    var cacheKey = emp.employeeId;
    if (managerCache[cacheKey] !== undefined) return managerCache[cacheKey];

    var visited   = new Set([emp.employeeId]); // prevent circular reference
    var managerId = emp.managerId;

    while (managerId) {
        if (visited.has(managerId)) { managerCache[cacheKey] = null; return null; }
        visited.add(managerId);

        // Found a manager that is active and in the current filtered set
        if (activeSet.has(managerId)) { managerCache[cacheKey] = managerId; return managerId; }

        // Manager not active — climb to their manager using the full org map
        var mgr = allEmpMap[managerId];
        if (!mgr) break;
        managerId = mgr.managerId;
    }

    managerCache[cacheKey] = null;
    return null; // no active manager found → employee becomes a root node
}

// ── Tree builders ──────────────────────────────────────────────────
function eocBuildTree(empList) {
    eocMap   = {};
    eocRoots = [];
    empList.forEach(function (emp) {
        eocMap[emp.employeeId] = Object.assign({}, emp, { children: [] });
    });
    empList.forEach(function (emp) {
        if (emp.managerId && eocMap[emp.managerId]) {
            eocMap[emp.managerId].children.push(eocMap[emp.employeeId]);
        } else {
            eocRoots.push(eocMap[emp.employeeId]);
        }
    });
    function sortChildren(node) {
        node.children.sort(function (a, b) { return a.name.localeCompare(b.name); });
        node.children.forEach(sortChildren);
    }
    eocRoots.forEach(sortChildren);
}

function eocTeamSize(employeeId) {
    var node = eocMap[employeeId];
    if (!node) return 0;
    var count = node.children.length;
    node.children.forEach(function (c) { count += eocTeamSize(c.employeeId); });
    return count;
}

function eocReportingChain(employeeId) {
    var chain = [];
    var cur   = eocMap[employeeId];
    while (cur) {
        chain.unshift(cur.employeeId);
        cur = cur.managerId ? eocMap[cur.managerId] : null;
    }
    return chain;
}

function eocAllSubordinates(employeeId) {
    var result = [];
    var node   = eocMap[employeeId];
    if (!node) return result;
    node.children.forEach(function (c) {
        result.push(c.employeeId);
        result.push.apply(result, eocAllSubordinates(c.employeeId));
    });
    return result;
}

// ── Card renderer (recursive) ──────────────────────────────────────
function eocRenderNode(node, depth, profileId) {
    depth = depth || 0;
    var teamSize    = eocTeamSize(node.employeeId);
    var hasChildren = node.children.length > 0;
    var collapsed   = eocCollapsed.has(node.employeeId);
    var isYou       = (node.employeeId === profileId);
    var depts       = JSON.parse(localStorage.getItem('prowess-departments') || '[]');
    var deptName    = node.departmentId
        ? (depts.find(function(d){ return d.deptId === node.departmentId; })?.name || node.departmentId)
        : '—';
    var initial  = (node.name || '?').charAt(0).toUpperCase();
    var avatarBg = eocGetAvatarColor(node.name);
    var avatarHtml = node.photo
        ? '<div class="eoc-avatar eoc-avatar--photo" style="background:transparent;">' +
          '<img src="' + node.photo + '" alt="' + eocEscHtml(node.name) + '" /></div>'
        : '<div class="eoc-avatar" style="background:' + avatarBg + ';">' + initial + '</div>';

    var wrap = document.createElement('div');
    wrap.className    = 'eoc-node-wrap';
    wrap.dataset.empId = node.employeeId;

    var card = document.createElement('div');
    card.className    = 'eoc-card';
    card.dataset.empId = node.employeeId;
    card.title = node.name + ' — click for details, double-click to focus';

    card.innerHTML = avatarHtml +
        '<div class="eoc-card-body">' +
            '<div class="eoc-card-name">' + eocEscHtml(node.name) +
                (isYou ? ' <span class="eoc-you-badge">You</span>' : '') +
            '</div>' +
            '<div class="eoc-card-desg">' + eocEscHtml(node.designation || '—') + '</div>' +
            '<div class="eoc-card-dept">' + eocEscHtml(deptName) + '</div>' +
            '<div class="eoc-card-id">' + eocEscHtml(node.employeeId) + '</div>' +
        '</div>' +
        (hasChildren
            ? '<div class="eoc-team-badge" title="' + teamSize + ' total report' + (teamSize !== 1 ? 's' : '') + '">' +
              '<i class="fa-solid fa-users"></i> ' + teamSize + '</div>'
            : '');

    wrap.appendChild(card);

    if (hasChildren) {
        var toggle = document.createElement('button');
        toggle.className    = 'eoc-toggle-btn';
        toggle.dataset.empId = node.employeeId;
        toggle.title   = collapsed ? 'Expand' : 'Collapse';
        toggle.innerHTML = collapsed
            ? '<i class="fa-solid fa-plus"></i>'
            : '<i class="fa-solid fa-minus"></i>';
        wrap.appendChild(toggle);
    }

    if (hasChildren && !collapsed) {
        var childRow = document.createElement('div');
        childRow.className       = 'eoc-children-row';
        childRow.dataset.parentId = node.employeeId;
        node.children.forEach(function (child) {
            var cWrap = document.createElement('div');
            cWrap.className = 'eoc-child-wrap';
            cWrap.appendChild(eocRenderNode(child, depth + 1, profileId));
            childRow.appendChild(cWrap);
        });
        wrap.appendChild(childRow);
    }

    return wrap;
}

// ── SVG connector lines ────────────────────────────────────────────
function eocDrawLines() {
    var canvas = document.getElementById('oc-canvas');
    if (!canvas) return;
    var old = document.getElementById('eoc-svg');
    if (old) old.remove();

    var svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    svg.id = 'eoc-svg';
    svg.style.cssText = 'position:absolute;top:0;left:0;width:100%;height:100%;pointer-events:none;overflow:visible;z-index:0;';

    var canvasRect = canvas.getBoundingClientRect();

    document.querySelectorAll('.eoc-children-row[data-parent-id]').forEach(function (row) {
        var parentId   = row.dataset.parentId;
        var parentCard = canvas.querySelector('.eoc-card[data-emp-id="' + parentId + '"]');
        if (!parentCard) return;
        var childCards = Array.from(
            row.querySelectorAll(':scope > .eoc-child-wrap > .eoc-node-wrap > .eoc-card')
        );
        if (!childCards.length) return;

        var pr  = parentCard.getBoundingClientRect();
        var px  = pr.left + pr.width / 2 - canvasRect.left;
        var py  = pr.bottom               - canvasRect.top;
        var gap = 24;

        var pts = childCards.map(function (c) {
            var r = c.getBoundingClientRect();
            return { x: r.left + r.width / 2 - canvasRect.left, y: r.top - canvasRect.top };
        });

        var onChain = parentCard.classList.contains('eoc-card--chain') ||
                      parentCard.classList.contains('eoc-card--selected');
        var lineCol = onChain ? '#3B82F6' : '#C8D8EA';
        var lineW   = onChain ? '2.5'     : '1.5';

        function mkLine(x1, y1, x2, y2) {
            var el = document.createElementNS('http://www.w3.org/2000/svg', 'line');
            el.setAttribute('x1', x1); el.setAttribute('y1', y1);
            el.setAttribute('x2', x2); el.setAttribute('y2', y2);
            el.setAttribute('stroke', lineCol);
            el.setAttribute('stroke-width', lineW);
            el.setAttribute('stroke-linecap', 'round');
            svg.appendChild(el);
        }

        var barY = py + gap;
        if (pts.length === 1) {
            mkLine(px, py, pts[0].x, pts[0].y);
        } else {
            mkLine(px, py, px, barY);
            var minX = Math.min.apply(null, pts.map(function(p){ return p.x; }));
            var maxX = Math.max.apply(null, pts.map(function(p){ return p.x; }));
            mkLine(minX, barY, maxX, barY);
            pts.forEach(function (p) { mkLine(p.x, barY, p.x, p.y); });
        }
    });

    canvas.insertBefore(svg, canvas.firstChild);
}

// ── Highlight (focus / chain / sub / dimmed) ───────────────────────
function eocApplyHighlight() {
    var cards = document.querySelectorAll('.eoc-card');
    cards.forEach(function (c) {
        c.classList.remove('eoc-card--selected','eoc-card--chain','eoc-card--sub','eoc-card--dimmed');
    });
    if (!eocFocusId && !eocSelectedId) return;

    var focusId  = eocFocusId || eocSelectedId;
    var chain    = eocReportingChain(focusId);
    var subs     = eocAllSubordinates(focusId);

    cards.forEach(function (c) {
        var id = c.dataset.empId;
        if (id === focusId)               c.classList.add('eoc-card--selected');
        else if (chain.indexOf(id) !== -1) c.classList.add('eoc-card--chain');
        else if (subs.indexOf(id) !== -1)  c.classList.add('eoc-card--sub');
        else                               c.classList.add('eoc-card--dimmed');
    });

    eocDrawLines();
}

// ── Zoom / pan ─────────────────────────────────────────────────────
function eocApplyTransform() {
    var canvas = document.getElementById('oc-canvas');
    if (canvas) {
        canvas.style.transform       = 'translate(' + eocPanX + 'px,' + eocPanY + 'px) scale(' + eocZoom + ')';
        canvas.style.transformOrigin = '0 0';
    }
    var lbl = document.getElementById('oc-zoom-level');
    if (lbl) lbl.textContent = Math.round(eocZoom * 100) + '%';
}

function eocResetView() {
    setTimeout(function () {
        var viewport = document.getElementById('oc-viewport');
        var canvas   = document.getElementById('oc-canvas');
        if (!viewport || !canvas) return;
        var vw = viewport.clientWidth;
        var ch = canvas.scrollWidth;
        eocZoom = 1;
        eocPanX = Math.max(0, (vw - ch) / 2);
        eocPanY = 40;
        eocApplyTransform();
    }, 80);
}

/** Pan the viewport so the logged-in employee's card is centred on screen. */
function eocCenterOnMe() {
    setTimeout(function () {
        var viewport = document.getElementById('oc-viewport');
        var canvas   = document.getElementById('oc-canvas');
        if (!viewport || !canvas) { eocResetView(); return; }

        // Find the "You" badge and walk up to the card
        var youBadge = canvas.querySelector('.eoc-you-badge');
        if (!youBadge) { eocResetView(); return; }
        var card = youBadge.closest('.eoc-card');
        if (!card) { eocResetView(); return; }

        var vw = viewport.clientWidth;
        var vh = viewport.clientHeight;

        // At this point eocZoom=1 and pan=0, so getBoundingClientRect positions
        // are in canvas-space directly.
        var canvasRect = canvas.getBoundingClientRect();
        var cardRect   = card.getBoundingClientRect();

        var cardCX = cardRect.left - canvasRect.left + cardRect.width  / 2;
        var cardCY = cardRect.top  - canvasRect.top  + cardRect.height / 2;

        // Centre the card in the viewport
        eocPanX = vw / 2 - cardCX;
        eocPanY = vh / 2 - cardCY;

        eocApplyTransform();
    }, 150);
}

function eocSetupZoomPan() {
    var viewport = document.getElementById('oc-viewport');
    if (!viewport || viewport._eocReady) return;
    viewport._eocReady = true;

    viewport.addEventListener('wheel', function (e) {
        e.preventDefault();
        var factor  = e.deltaY > 0 ? 0.9 : 1.1;
        var newZoom = Math.max(0.25, Math.min(2.5, eocZoom * factor));
        var rect    = viewport.getBoundingClientRect();
        var mx = e.clientX - rect.left;
        var my = e.clientY - rect.top;
        eocPanX = mx - (mx - eocPanX) * (newZoom / eocZoom);
        eocPanY = my - (my - eocPanY) * (newZoom / eocZoom);
        eocZoom = newZoom;
        eocApplyTransform();
    }, { passive: false });

    viewport.addEventListener('mousedown', function (e) {
        if (e.target.closest('.eoc-card') || e.target.closest('.eoc-toggle-btn')) return;
        eocDragging  = true;
        eocDragStart = { x: e.clientX, y: e.clientY, px: eocPanX, py: eocPanY };
        viewport.style.cursor = 'grabbing';
        e.preventDefault();
    });
    document.addEventListener('mousemove', function (e) {
        if (!eocDragging) return;
        eocPanX = eocDragStart.px + (e.clientX - eocDragStart.x);
        eocPanY = eocDragStart.py + (e.clientY - eocDragStart.y);
        eocApplyTransform();
    });
    document.addEventListener('mouseup', function () {
        if (!eocDragging) return;
        eocDragging = false;
        var vp = document.getElementById('oc-viewport');
        if (vp) vp.style.cursor = 'grab';
    });
}

// ── Details panel ──────────────────────────────────────────────────
function eocShowDetails(empId) {
    var emp   = eocMap[empId];
    if (!emp) return;
    eocSelectedId = empId;

    var panel = document.getElementById('oc-details-panel');
    var body  = document.getElementById('oc-details-body');
    if (!panel || !body) return;

    var depts    = JSON.parse(localStorage.getItem('prowess-departments') || '[]');
    var deptName = emp.departmentId
        ? (depts.find(function(d){ return d.deptId === emp.departmentId; })?.name || emp.departmentId)
        : '—';
    var manager  = emp.managerId && eocMap[emp.managerId] ? eocMap[emp.managerId].name : '—';
    var _eocLocVals = plValsScript();
    var _eocLocObj  = emp.workLocationId
        ? _eocLocVals.find(function(v){ return v.picklistId === 'LOCATION' && String(v.id) === String(emp.workLocationId); })
        : null;
    var eocLocName  = _eocLocObj ? _eocLocObj.value : '—';
    var teamSz   = eocTeamSize(empId);
    var chain    = eocReportingChain(empId);
    var initial  = (emp.name || '?').charAt(0).toUpperCase();
    var avatarBg = eocGetAvatarColor(emp.name);

    var chainHtml = chain.map(function(id) {
        var n = eocMap[id];
        return n ? '<span class="eoc-chain-pill">' + eocEscHtml(n.name) + '</span>' : '';
    }).join('<i class="fa-solid fa-angle-right eoc-chain-arrow"></i>');

    function detRow(icon, label, value) {
        return '<div class="eoc-det-row">' +
            '<div class="eoc-det-icon"><i class="fa-solid fa-' + icon + '"></i></div>' +
            '<div><div class="eoc-det-label">' + label + '</div>' +
            '<div class="eoc-det-value">' + eocEscHtml(String(value)) + '</div></div>' +
            '</div>';
    }

    body.innerHTML =
        '<div class="eoc-det-hero">' +
            '<div class="eoc-det-avatar" style="background:' + avatarBg + ';">' + initial + '</div>' +
            '<div class="eoc-det-name">'  + eocEscHtml(emp.name)                + '</div>' +
            '<div class="eoc-det-desg">'  + eocEscHtml(mpResolveRef(emp.designation, 'prowess-designations') || '—') + '</div>' +
            '<div class="eoc-det-id">'    + eocEscHtml(emp.employeeId)          + '</div>' +
        '</div>' +
        '<div class="eoc-det-grid">' +
            detRow('sitemap',             'Department',  deptName) +
            detRow('user-tie',            'Manager',     manager) +
            detRow('users',               'Team Size',   teamSz + ' direct report' + (teamSz !== 1 ? 's' : '')) +
            detRow('briefcase',           'Role',        emp.role || 'Employee') +
            detRow('circle-half-stroke',  'Status',      eocGetStatus(emp)) +
            detRow('calendar-check',      'Hire Date',   eocFmtDate(emp.hireDate)) +
            detRow('location-dot',        'Location',    eocLocName) +
            detRow('envelope',            'Business Email', emp.businessEmail || '—') +
            detRow('phone',               'Mobile',      emp.mobile || '—') +
        '</div>' +
        (chain.length > 1
            ? '<div class="eoc-det-section"><div class="eoc-det-section-title"><i class="fa-solid fa-route"></i> Reporting Chain</div>' +
              '<div class="eoc-chain-row">' + chainHtml + '</div></div>'
            : '') +
        '<div class="eoc-det-actions">' +
            '<button class="oc-btn oc-btn-primary btn-focus-mode" onclick="eocFocusOn(\'' + empId + '\')"><i class="fa-solid fa-crosshairs"></i> Focus on this person</button>' +
        '</div>';

    panel.classList.add('eoc-details-panel--open');
    eocApplyHighlight();
}

// ── Focus mode ─────────────────────────────────────────────────────
function eocFocusOn(empId) {
    eocFocusId = empId;
    var emp    = eocMap[empId];
    if (!emp) return;

    var bar    = document.getElementById('oc-focus-bar');
    var nameEl = document.getElementById('oc-focus-name');
    if (bar)    bar.style.display  = 'flex';
    if (nameEl) nameEl.textContent = emp.name;

    eocReportingChain(empId).forEach(function (id) { eocCollapsed.delete(id); });
    eocAllSubordinates(empId).forEach(function (id) { eocCollapsed.delete(id); });

    eocRenderOrgChart();
    eocApplyHighlight();

    setTimeout(function () {
        var card = document.querySelector('.eoc-card[data-emp-id="' + empId + '"]');
        if (card) card.scrollIntoView({ behavior: 'smooth', block: 'center', inline: 'center' });
    }, 150);
}

function eocClearFocus() {
    eocFocusId    = null;
    eocSelectedId = null;
    var bar = document.getElementById('oc-focus-bar');
    if (bar) bar.style.display = 'none';
    var panel = document.getElementById('oc-details-panel');
    if (panel) panel.classList.remove('eoc-details-panel--open');
    eocApplyHighlight();
    eocDrawLines();
}

// ── Legend ─────────────────────────────────────────────────────────
function eocRenderLegend() {
    var depts = JSON.parse(localStorage.getItem('prowess-departments') || '[]');
    var el    = document.getElementById('oc-legend');
    if (!el) return;
    var html = '';
    depts.forEach(function (d) {
        var c = eocColor(d.deptId);
        html += '<span class="eoc-legend-item" style="border-color:' + c.border + ';background:' + c.bg + ';">' +
                '<span class="eoc-legend-dot" style="background:' + c.border + ';"></span>' +
                eocEscHtml(d.name) + '</span>';
    });
    el.innerHTML = html;
}

// ── Department filter dropdown ──────────────────────────────────────
function eocPopulateDeptFilter() {
    var sel   = document.getElementById('oc-dept-filter');
    if (!sel) return;
    var depts = JSON.parse(localStorage.getItem('prowess-departments') || '[]');
    var cur   = sel.value;
    sel.innerHTML = '<option value="">All Departments</option>';
    depts.forEach(function (d) {
        var o = document.createElement('option');
        o.value = d.deptId; o.textContent = d.name;
        sel.appendChild(o);
    });
    sel.value = cur;
}

// ── Main render ─────────────────────────────────────────────────────
function eocRenderOrgChart() {
    var root = document.getElementById('oc-tree-root');
    if (!root) return;

    // ── Load data ────────────────────────────────────────────────────
    var allEmployees = JSON.parse(localStorage.getItem('prowess-employees') || '[]');

    // Identify logged-in profile (for "You" badge)
    var profile   = JSON.parse(localStorage.getItem('prowess-profile') || '{}');
    var profileId = null;
    if (profile.name && allEmployees.length > 0) {
        var me = allEmployees.find(function(e) {
            return e.name && e.name.trim().toLowerCase() === profile.name.trim().toLowerCase();
        });
        if (me) profileId = me.employeeId;
    }

    // Full lookup map (used for manager traversal across the entire org)
    var allEmpMap = {};
    allEmployees.forEach(function(e) { allEmpMap[e.employeeId] = e; });

    // ── Update date picker and viewing label ─────────────────────────
    var datePicker = document.getElementById('oc-date-filter');
    if (datePicker && !datePicker.value) datePicker.value = eocSelectedDate;
    var viewingEl = document.getElementById('oc-date-viewing');
    if (viewingEl) {
        var today = new Date().toISOString().split('T')[0];
        var d     = new Date(eocSelectedDate + 'T00:00:00');
        var fmt   = d.toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' });
        viewingEl.textContent = 'Viewing organisation as of ' +
            (eocSelectedDate === today ? 'Today (' + fmt + ')' : fmt);
    }

    // ── STEP 1: Department filter ────────────────────────────────────
    // Include dept members + all their ancestors from the full org map
    var filterDept = (document.getElementById('oc-dept-filter')?.value || '');
    var step1List  = allEmployees;

    if (filterDept) {
        var inDept = new Set(
            allEmployees
                .filter(function(e) { return e.departmentId === filterDept; })
                .map(function(e) { return e.employeeId; })
        );
        // Walk up each member's chain and include ancestors
        inDept.forEach(function(id) {
            var cur = allEmpMap[id];
            var visited = new Set([id]);
            while (cur && cur.managerId) {
                if (visited.has(cur.managerId)) break; // circular guard
                visited.add(cur.managerId);
                inDept.add(cur.managerId);
                cur = allEmpMap[cur.managerId];
            }
        });
        step1List = allEmployees.filter(function(e) { return inDept.has(e.employeeId); });
    }

    // ── STEP 2: Date filter ──────────────────────────────────────────
    // Keep only employees who were active on the selected date
    var step2List = step1List.filter(function(emp) {
        return eocIsActiveOnDate(emp, eocSelectedDate);
    });

    // Active set — used for fast manager resolution lookup
    var activeSet = new Set(step2List.map(function(e) { return e.employeeId; }));

    // ── STEP 3: Resolve effective manager for each employee ──────────
    // If an employee's direct manager is not in the active set, traverse
    // upward through the full org until an active manager is found.
    // Results are cached to avoid repeated traversal (O(n) total).
    var managerCache = {};
    var resolvedList = step2List.map(function(emp) {
        var effectiveMgr = eocResolveManager(emp, allEmpMap, activeSet, managerCache);
        return Object.assign({}, emp, { managerId: effectiveMgr });
    });

    // ── STEP 4: Build and render the tree ───────────────────────────
    eocBuildTree(resolvedList);
    eocBuildColorMap();
    eocRenderLegend();
    eocPopulateDeptFilter();

    root.innerHTML = '';

    if (allEmployees.length === 0) {
        root.innerHTML = '<p style="padding:40px;color:#aaa;text-align:center;">No employee records found.<br>Ask your admin to add employees.</p>';
        return;
    }

    if (eocRoots.length === 0) {
        var d2 = new Date(eocSelectedDate + 'T00:00:00');
        var fmt2 = d2.toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' });
        root.innerHTML = '<p style="padding:40px;color:#aaa;text-align:center;">' +
            'No employees were active on <strong>' + fmt2 + '</strong>.<br>' +
            'Try selecting a different date.</p>';
        return;
    }

    var rootRow = document.createElement('div');
    rootRow.className = 'eoc-roots-row';
    eocRoots.forEach(function(node) {
        var wrap = document.createElement('div');
        wrap.className = 'eoc-root-wrap';
        wrap.appendChild(eocRenderNode(node, 0, profileId));
        rootRow.appendChild(wrap);
    });
    root.appendChild(rootRow);

    requestAnimationFrame(function() {
        eocDrawLines();
        eocApplyHighlight();
    });
}

// ── Event wiring ────────────────────────────────────────────────────
(function eocSetupEvents() {

    // Initialise date picker to today
    var datePicker = document.getElementById('oc-date-filter');
    if (datePicker) {
        datePicker.value = eocSelectedDate;
        datePicker.addEventListener('change', function () {
            eocSelectedDate = this.value || new Date().toISOString().split('T')[0];
            eocRenderOrgChart();
            setTimeout(eocResetView, 100);
        });
    }

    // Tab activation → render
    document.querySelectorAll('.tab-item[data-tab="org-chart"]').forEach(function (item) {
        item.addEventListener('click', function () {
            eocZoom = 1; eocPanX = 0; eocPanY = 0;
            eocFocusId    = null;
            eocSelectedId = null;
            // Ensure date picker reflects current state
            var dp = document.getElementById('oc-date-filter');
            if (dp) dp.value = eocSelectedDate;
            eocRenderOrgChart();
            eocSetupZoomPan();
            eocCenterOnMe(); // pan to the logged-in employee's card on open
        });
    });

    // Card: single-click → details; double-click → focus
    document.addEventListener('click', function (e) {
        var card = e.target.closest('.eoc-card');
        if (card) { eocShowDetails(card.dataset.empId); return; }

        var toggle = e.target.closest('.eoc-toggle-btn');
        if (toggle) {
            var id = toggle.dataset.empId;
            if (eocCollapsed.has(id)) eocCollapsed.delete(id);
            else eocCollapsed.add(id);
            eocRenderOrgChart();
            return;
        }

        var detClose = e.target.closest('#oc-details-close');
        if (detClose) {
            document.getElementById('oc-details-panel').classList.remove('eoc-details-panel--open');
            eocSelectedId = null;
            eocApplyHighlight();
            eocDrawLines();
        }
    });

    document.addEventListener('dblclick', function (e) {
        var card = e.target.closest('.eoc-card');
        if (card) eocFocusOn(card.dataset.empId);
    });

    // Expand / Collapse All
    document.getElementById('oc-expand-all')?.addEventListener('click', function () {
        eocCollapsed.clear();
        eocRenderOrgChart();
    });
    document.getElementById('oc-collapse-all')?.addEventListener('click', function () {
        Object.keys(eocMap).forEach(function (id) {
            if (eocMap[id].children.length > 0) eocCollapsed.add(id);
        });
        eocRenderOrgChart();
    });

    // Zoom buttons
    document.getElementById('oc-zoom-in')?.addEventListener('click', function () {
        eocZoom = Math.min(2.5, eocZoom * 1.2); eocApplyTransform();
    });
    document.getElementById('oc-zoom-out')?.addEventListener('click', function () {
        eocZoom = Math.max(0.25, eocZoom / 1.2); eocApplyTransform();
    });
    document.getElementById('oc-zoom-reset')?.addEventListener('click', function () {
        eocZoom = 1; eocPanX = 0; eocPanY = 0;
        eocApplyTransform();
        eocResetView();
    });

    // Search
    var searchEl = document.getElementById('oc-search');
    var clearEl  = document.getElementById('oc-search-clear');
    if (searchEl) {
        searchEl.addEventListener('input', function () {
            var q = this.value.trim().toLowerCase();
            if (clearEl) clearEl.style.display = q ? 'flex' : 'none';
            if (!q) { eocClearFocus(); return; }
            var empList = JSON.parse(localStorage.getItem('prowess-employees') || '[]');
            var match   = empList.find(function (emp) {
                return (emp.name || '').toLowerCase().includes(q) ||
                       (emp.employeeId || '').toLowerCase().includes(q);
            });
            if (match) eocFocusOn(match.employeeId);
        });
    }
    if (clearEl) {
        clearEl.addEventListener('click', function () {
            if (searchEl) searchEl.value = '';
            this.style.display = 'none';
            eocClearFocus();
        });
    }

    // Department filter
    document.getElementById('oc-dept-filter')?.addEventListener('change', function () {
        eocRenderOrgChart();
        setTimeout(eocResetView, 100);
    });

    // Focus bar — clear focus
    document.getElementById('oc-focus-clear')?.addEventListener('click', function () {
        if (searchEl) searchEl.value = '';
        if (clearEl)  clearEl.style.display = 'none';
        eocClearFocus();
        eocRenderOrgChart();
    });

    // Re-draw lines on window resize
    window.addEventListener('resize', function () {
        if (document.getElementById('tab-org-chart')?.classList.contains('active')) {
            eocDrawLines();
        }
    });

})();

// ═══════════════════════════════════════════════════════════════════
// ── MY PROFILE  (tab: my-profile) ──────────────────────────────────
// Read-only 7-tab view of the logged-in employee's own record.
// Matches prowess-profile → prowess-employees by name (or employeeId
// when available) and renders the full employee detail inline.
// ═══════════════════════════════════════════════════════════════════

var MP_SECTIONS = [
    { id: 'personal',       label: 'Personal',          icon: 'fa-circle-user',   fn: function(e,el){ mpTabPersonal(e,el);       } },
    { id: 'contact',        label: 'Contact',            icon: 'fa-phone',         fn: function(e,el){ mpTabContact(e,el);        } },
    { id: 'address',        label: 'Address',            icon: 'fa-location-dot',  fn: function(e,el){ mpTabAddress(e,el);        } },
    { id: 'passport',       label: 'Passport',           icon: 'fa-passport',      fn: function(e,el){ mpTabPassport(e,el);       } },
    { id: 'identification', label: 'Identification',     icon: 'fa-id-card-clip',  fn: function(e,el){ mpTabIdentification(e,el); } },
    { id: 'emergency',      label: 'Emergency Contact',  icon: 'fa-phone-volume',  fn: function(e,el){ mpTabEmergency(e,el);      } },
    { id: 'employment',     label: 'Employment',         icon: 'fa-briefcase',     fn: function(e,el){ mpTabEmployment(e,el);     } },
];

// ── Find the employee record that belongs to the current portal user ──

function mpGetCurrentEmployee() {
    var profile = JSON.parse(localStorage.getItem('prowess-profile') || 'null');
    if (!profile) return null;
    var empList = JSON.parse(localStorage.getItem('prowess-employees') || '[]');
    return empList.find(function (e) {
        if (e.employeeId && profile.employeeId) {
            return String(e.employeeId) === String(profile.employeeId);
        }
        return e.name && profile.name &&
               e.name.trim().toLowerCase() === profile.name.trim().toLowerCase();
    }) || null;
}

// ── Main render entry-point — one-pager with sticky scrollspy nav ─────

function renderMyProfile() {
    var wrapper = document.getElementById('mp-wrapper');
    var emp     = mpGetCurrentEmployee();

    if (!emp) {
        wrapper.innerHTML =
            '<div class="mp-not-found">' +
                '<i class="fa-solid fa-id-badge"></i>' +
                '<h3>Profile not linked</h3>' +
                '<p>Your portal account has not been linked to an employee record yet. ' +
                   'Please contact your administrator.</p>' +
            '</div>';
        mpSetScrollHeight();
        return;
    }

    // Build sticky nav + all sections in one page
    var navBtns = MP_SECTIONS.map(function (s, i) {
        return '<button class="mp-nav-btn' + (i === 0 ? ' mp-nav-active' : '') + '" ' +
               'data-target="mp-s-' + s.id + '">' +
               '<i class="fa-solid ' + s.icon + '"></i>' + s.label +
               '</button>';
    }).join('');

    var sectionsHtml = MP_SECTIONS.map(function (s) {
        return '<section id="mp-s-' + s.id + '" class="mp-section"></section>';
    }).join('');

    wrapper.innerHTML =
        '<div class="mp-page">' +
            '<nav class="mp-sticky-nav" id="mp-nav">' + navBtns + '</nav>' +
            '<div class="mp-sections">' + sectionsHtml + '</div>' +
        '</div>';

    // Render each section's content
    MP_SECTIONS.forEach(function (s) {
        var el = document.getElementById('mp-s-' + s.id);
        if (el) s.fn(emp, el);
    });

    // Set scroll-container height so it fills the remaining viewport
    mpSetScrollHeight();
    window.addEventListener('resize', mpSetScrollHeight);

    // Wire nav-button clicks → smooth scroll with sticky-nav offset
    var navEl       = document.getElementById('mp-nav');
    var scrollBox   = document.getElementById('mp-scroll-container');
    document.querySelectorAll('.mp-nav-btn').forEach(function (btn) {
        btn.addEventListener('click', function () {
            var target = document.getElementById(btn.getAttribute('data-target'));
            if (!target || !scrollBox) return;
            var navH   = navEl ? navEl.offsetHeight : 0;
            var offset = target.getBoundingClientRect().top
                         - scrollBox.getBoundingClientRect().top
                         + scrollBox.scrollTop
                         - navH - 8;
            scrollBox.scrollTo({ top: offset, behavior: 'smooth' });
        });
    });

    // Scrollspy — highlight nav button for the section currently in view
    mpInitScrollSpy();
}

// ── Dynamically size the scroll container to fill remaining viewport ──

function mpSetScrollHeight() {
    var container = document.getElementById('mp-scroll-container');
    if (!container) return;
    var rect    = container.getBoundingClientRect();
    var availH  = window.innerHeight - rect.top - 16;   // 16px breathing room
    container.style.height = Math.max(200, availH) + 'px';
}

// ── IntersectionObserver scrollspy ───────────────────────────────────

function mpInitScrollSpy() {
    var scrollBox = document.getElementById('mp-scroll-container');
    if (!scrollBox) return;

    var sections = document.querySelectorAll('.mp-section');
    var navBtns  = document.querySelectorAll('.mp-nav-btn');

    var observer = new IntersectionObserver(function (entries) {
        entries.forEach(function (entry) {
            if (entry.isIntersecting) {
                var id = entry.target.id;
                navBtns.forEach(function (btn) {
                    btn.classList.toggle('mp-nav-active',
                        btn.getAttribute('data-target') === id);
                });
            }
        });
    }, {
        root:       scrollBox,          // ← our self-contained scroll box
        rootMargin: '-10% 0px -55% 0px',
        threshold:  0
    });

    sections.forEach(function (s) { observer.observe(s); });
}

// ── Shared helpers ────────────────────────────────────────────────────

/**
 * Resolve a stored refId to its human-readable label.
 * Falls back gracefully to the refId itself if not found.
 */
function mpResolveRef(refId, storageKey) {
    if (!refId) return '—';
    // Try new generic storage first
    var picklistId = _PL_KEY_MAP[storageKey];
    if (picklistId) {
        var vals = plValsScript().filter(function(v) { return v.picklistId === picklistId; });
        if (vals.length) {
            var found = vals.find(function(v) {
                return v.refId === refId || String(v.id) === String(refId) || (v.meta && v.meta.code === refId);
            });
            return found ? found.value : refId;
        }
    }
    // Fallback to old storage (pre-migration)
    var items = JSON.parse(localStorage.getItem(storageKey) || '[]');
    var item  = items.find(function(i) { return i.refId === refId || String(i.id) === String(refId); });
    return item ? (item.value || item.name || refId) : refId;
}

function mpField(label, value) {
    var isEmpty = (value === null || value === undefined || value === '' || value === '—');
    var display = isEmpty
        ? '<span class="ev-field-value ev-empty">Not provided</span>'
        : '<span class="ev-field-value">' + mpEsc(value) + '</span>';
    return '<div class="ev-field"><div class="ev-field-label">' + label + '</div>' + display + '</div>';
}

function mpSectionTitle(icon, text) {
    return '<div class="ev-section-title"><i class="fa-solid ' + icon + '"></i>' + text + '</div>';
}

function mpFmtDate(val) {
    if (!val) return '—';
    if (val === '9999-12-31') return 'Open-ended';
    try {
        return new Date(val + 'T00:00:00').toLocaleDateString('en-IN', {
            day: '2-digit', month: 'short', year: 'numeric'
        });
    } catch (e) { return val; }
}

function mpDeptName(deptId) {
    if (!deptId) return '—';
    var depts = JSON.parse(localStorage.getItem('prowess-departments') || '[]');
    var d = depts.find(function (d) { return String(d.id) === String(deptId); });
    return d ? d.name : '—';
}

function mpManagerName(managerId) {
    if (!managerId) return '—';
    var empList = JSON.parse(localStorage.getItem('prowess-employees') || '[]');
    var m = empList.find(function (e) { return String(e.id) === String(managerId); });
    return m ? m.name : '—';
}

function mpEsc(str) {
    return String(str || '')
        .replace(/&/g, '&amp;').replace(/</g, '&lt;')
        .replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

// ── Tab 1 — Personal Information ──────────────────────────────────────

function mpTabPersonal(emp, el) {
    el.innerHTML =
        mpSectionTitle('fa-circle-user', 'Personal Information') +
        '<div class="ev-field-grid ev-grid-2">' +
            mpField('Full Name',      emp.name) +
            mpField('Employee ID',    emp.employeeId) +
            mpField('Nationality',    mpResolveRef(emp.nationality,   'prowess-nationalities')) +
            mpField('Marital Status', mpResolveRef(emp.maritalStatus, 'prowess-marital-statuses')) +
        '</div>';
}

// ── Tab 2 — Contact Information ───────────────────────────────────────

function mpTabContact(emp, el) {
    el.innerHTML =
        mpSectionTitle('fa-phone', 'Contact Information') +
        '<div class="ev-field-grid ev-grid-2">' +
            mpField('Mobile No.',     emp.mobile) +
            mpField('Business Email', emp.businessEmail) +
            mpField('Personal Email', emp.personalEmail) +
        '</div>';
}

// ── Tab 3 — Address Information ───────────────────────────────────────

function mpTabAddress(emp, el) {
    el.innerHTML =
        mpSectionTitle('fa-location-dot', 'Address Information') +
        '<div class="ev-field-grid ev-grid-2">' +
            mpField('Address Line 1',  emp.addrLine1) +
            mpField('Address Line 2',  emp.addrLine2) +
            mpField('Landmark',        emp.addrLandmark) +
            mpField('City',            emp.addrCity) +
            mpField('District',        emp.addrDistrict) +
            mpField('State',           emp.addrState) +
            mpField('PIN / ZIP Code',  emp.addrPin) +
            mpField('Country',         emp.addrCountry) +
        '</div>';
}

// ── Tab 4 — Passport Information ──────────────────────────────────────

function mpTabPassport(emp, el) {
    var hasPassport = emp.passportNumber || emp.passportCountry;
    if (!hasPassport) {
        el.innerHTML =
            mpSectionTitle('fa-passport', 'Passport Information') +
            '<div class="ev-empty-state">' +
            '<i class="fa-solid fa-passport"></i>' +
            '<p>No passport details on file.</p></div>';
        return;
    }

    // Expiry alert
    var alertHtml = '';
    if (emp.passportExpiryDate && emp.passportExpiryDate !== '9999-12-31') {
        var today   = new Date(); today.setHours(0, 0, 0, 0);
        var expiry  = new Date(emp.passportExpiryDate + 'T00:00:00');
        var diffMs  = expiry - today;
        var diffDays = Math.ceil(diffMs / (1000 * 60 * 60 * 24));
        if (diffDays < 0) {
            alertHtml = '<div class="ev-passport-alert expired">' +
                '<i class="fa-solid fa-triangle-exclamation"></i> Passport expired ' +
                Math.abs(diffDays) + ' day(s) ago.</div>';
        } else if (diffDays <= 90) {
            var cls = diffDays <= 30 ? 'critical' : 'warning';
            alertHtml = '<div class="ev-passport-alert ' + cls + '">' +
                '<i class="fa-solid fa-triangle-exclamation"></i> Passport expires in ' +
                diffDays + ' day(s).</div>';
        }
    }

    el.innerHTML =
        mpSectionTitle('fa-passport', 'Passport Information') +
        alertHtml +
        '<div class="ev-field-grid ev-grid-2">' +
            mpField('Issue Country',  emp.passportCountry) +
            mpField('Passport No.',   emp.passportNumber) +
            mpField('Issue Date',     mpFmtDate(emp.passportIssueDate)) +
            mpField('Expiry Date',    mpFmtDate(emp.passportExpiryDate)) +
        '</div>';
}

// ── Tab 5 — Identification Details ────────────────────────────────────

function mpTabIdentification(emp, el) {
    var ids    = emp.identifications || [];
    var idVals = plValsScript();

    if (ids.length === 0) {
        el.innerHTML =
            mpSectionTitle('fa-id-card-clip', 'Identification Details') +
            '<div class="ev-empty-state">' +
            '<i class="fa-solid fa-id-card-clip"></i>' +
            '<p>No identification records on file.</p></div>';
        return;
    }

    var rows = ids.map(function (rec) {
        var cName  = (idVals.find(function(v) { return v.picklistId === 'ID_COUNTRY' && String(v.id) === String(rec.countryId); }) || {}).value || '—';
        var tName  = (idVals.find(function(v) { return v.picklistId === 'ID_TYPE'    && String(v.id) === String(rec.idTypeId);  }) || {}).value || '—';
        var expiry = rec.expiryDate ? mpFmtDate(rec.expiryDate) : '—';
        var status = rec.isPrimary === 'primary'
            ? '<span class="ev-badge ev-badge-primary">⭐ Primary</span>'
            : '<span style="color:#8a9ab0;font-size:12px;">Secondary</span>';
        return '<tr>' +
            '<td>' + mpEsc(cName) + '</td>' +
            '<td>' + mpEsc(tName) + '</td>' +
            '<td class="ev-mono">' + mpEsc(rec.idNumber || '—') + '</td>' +
            '<td>' + expiry + '</td>' +
            '<td>' + status + '</td>' +
        '</tr>';
    }).join('');

    el.innerHTML =
        mpSectionTitle('fa-id-card-clip', 'Identification Details') +
        '<table class="ev-id-table">' +
            '<thead><tr>' +
                '<th>Country</th><th>ID Type</th>' +
                '<th>ID Number</th><th>Expiry</th><th>Status</th>' +
            '</tr></thead>' +
            '<tbody>' + rows + '</tbody>' +
        '</table>';
}

// ── Tab 6 — Emergency Contact Information ─────────────────────────────

function mpTabEmergency(emp, el) {
    if (!emp.ecName && !emp.ecPhone) {
        el.innerHTML =
            mpSectionTitle('fa-phone-volume', 'Emergency Contact Information') +
            '<div class="ev-empty-state">' +
            '<i class="fa-solid fa-phone-volume"></i>' +
            '<p>No emergency contact on record.</p></div>';
        return;
    }

    el.innerHTML =
        mpSectionTitle('fa-phone-volume', 'Emergency Contact Information') +
        '<div class="ev-field-grid ev-grid-2">' +
            mpField('Contact Name',    emp.ecName) +
            mpField('Relationship',    mpResolveRef(emp.ecRelationship, 'prowess-relationship-types')) +
            mpField('Phone Number',    emp.ecPhone) +
            mpField('Alternate Phone', emp.ecAltPhone) +
            mpField('Email',           emp.ecEmail) +
        '</div>';
}

// ── Tab 7 — Employment Information ────────────────────────────────────

function mpTabEmployment(emp, el) {
    var today   = new Date(); today.setHours(0, 0, 0, 0);
    var endDate = emp.endDate ? new Date(emp.endDate + 'T00:00:00') : null;
    var isActive = !endDate || emp.endDate === '9999-12-31' || endDate >= today;

    var statusBadge = isActive
        ? '<span class="ev-badge ev-badge-active"><i class="fa-solid fa-circle-dot"></i> Active</span>'
        : '<span class="ev-badge ev-badge-inactive"><i class="fa-solid fa-circle-dot"></i> Inactive</span>';

    var roleBadge =
        emp.role === 'admin'   ? '<span class="ev-badge" style="background:#f3e5f5;color:#7b1fa2;">Admin</span>'   :
        emp.role === 'manager' ? '<span class="ev-badge" style="background:#e3f2fd;color:#1565c0;">Manager</span>' :
                                 '<span class="ev-badge" style="background:#f0f4fa;color:#546e7a;">Employee</span>';

    // Resolve Country of Work and Location from new picklist storage
    var _mpAllVals  = plValsScript();
    var workCountry = emp.workCountryId
        ? _mpAllVals.find(function(v) { return v.picklistId === 'ID_COUNTRY' && String(v.id) === String(emp.workCountryId); })
        : null;
    var workCountryName = workCountry ? workCountry.value : '—';
    var workLoc = emp.workLocationId
        ? _mpAllVals.find(function(v) { return v.picklistId === 'LOCATION' && String(v.id) === String(emp.workLocationId); })
        : null;
    var workLocName = workLoc ? workLoc.value : '—';

    el.innerHTML =
        mpSectionTitle('fa-briefcase', 'Employment Information') +
        '<div class="ev-field-grid ev-grid-2">' +
            '<div class="ev-field"><div class="ev-field-label">Status</div>' + statusBadge + '</div>' +
            '<div class="ev-field"><div class="ev-field-label">Role</div>'   + roleBadge   + '</div>' +
            mpField('Designation',     mpResolveRef(emp.designation, 'prowess-designations')) +
            mpField('Department',      mpDeptName(emp.departmentId)) +
            mpField('Manager',         mpManagerName(emp.managerId)) +
            mpField('Hire Date',       mpFmtDate(emp.hireDate)) +
            mpField('End Date',        mpFmtDate(emp.endDate)) +
            mpField('Country of Work', workCountryName) +
            mpField('Location',        workLocName) +
        '</div>';
}
