// ── STEP 1: Grab all the elements we need ──────

const form = document.getElementById('expense-form');
const categoryInput = document.getElementById('category');
const dateInput = document.getElementById('date');
const projectInput = document.getElementById('project');
const amountInput = document.getElementById('amount');
const noteInput = document.getElementById('note');
const expenseBody = document.getElementById('expense-body');
const monthFilter = document.getElementById('month-filter');
const projectFilter = document.getElementById('project-filter');

// ── STEP 2: Load data from localStorage ────────

let expenses = JSON.parse(localStorage.getItem('prowess-expenses')) || [];
let projects = JSON.parse(localStorage.getItem('prowess-projects')) || [];
let editingId = null; // tracks which expense is being edited

// ── STEP 3: Handle form submission ─────────────

form.addEventListener('submit', function (event) {
    event.preventDefault();

    if (editingId !== null) {
        // ── EDIT MODE: update existing expense ──
        expenses = expenses.map(function (e) {
            if (e.id === editingId) {
                return {
                    ...e,
                    category: categoryInput.value,
                    date: dateInput.value,
                    project: projectInput.value,
                    amount: parseFloat(amountInput.value),
                    note: noteInput.value.trim() || '—'
                };
            }
            return e;
        });

        // Reset edit mode
        editingId = null;
        document.querySelector('.btn-add').textContent = '+ Add Expense';

    } else {
        // ── ADD MODE: create new expense ────────
        const newExpense = {
            id: Date.now(),
            category: categoryInput.value,
            date: dateInput.value,
            project: projectInput.value,
            amount: parseFloat(amountInput.value),
            note: noteInput.value.trim() || '—'
        };
        expenses.push(newExpense);
    }

    // Save, reset and re-render (runs for both add and edit)
    localStorage.setItem('prowess-expenses', JSON.stringify(expenses));
    form.reset();
    projectInput.innerHTML = '<option value="">-- Select Date First --</option>';
    renderTable();
    renderDashboard();
    renderInsights();
    populateMonthFilter();
    populateProjectFilter();
});

// ── STEP 4: Populate project dropdown by date ──
// When employee picks a date, only show projects
// that are active on that date

dateInput.addEventListener('change', function () {
    const selectedDate = dateInput.value;
    populateProjectDropdown(selectedDate);
});

function populateProjectDropdown(selectedDate) {
    projectInput.innerHTML = '<option value="">-- Select Project --</option>';

    if (!selectedDate) {
        projectInput.innerHTML = '<option value="">-- Select Date First --</option>';
        return;
    }

    // Filter projects active on the selected date
    const activeProjects = projects.filter(function (p) {
        return selectedDate >= p.startDate && selectedDate <= p.endDate;
    });

    if (activeProjects.length === 0) {
        projectInput.innerHTML = '<option value="">-- No Active Projects --</option>';
        return;
    }

    activeProjects.forEach(function (p) {
        const option = document.createElement('option');
        option.value = p.name;
        option.textContent = p.name;
        projectInput.appendChild(option);
    });
}

// ── STEP 5: Render the expenses table ──────────

function renderTable() {

    // Clear existing rows first
    expenseBody.innerHTML = '';

    const filtered = getFilteredExpenses();

    // If no expenses yet, show a friendly message
    if (filtered.length === 0) {
        expenseBody.innerHTML = '<tr><td colspan="7" class="no-data">No expenses added yet.</td></tr>';
        return;
    }

    // Loop through each expense and create a table row
    filtered.forEach(function (expense, index) {
        const row = document.createElement('tr');

        row.innerHTML = `
            <td>${index + 1}</td>
            <td>${expense.category}</td>
            <td>${expense.date}</td>
            <td><span class="project-badge">${expense.project || '—'}</span></td>
            <td>₹${expense.amount.toLocaleString('en-IN')}</td>
            <td>${expense.note}</td>
            <td>
                <button class="btn-edit" data-id="${expense.id}">
                    <i class="fa-solid fa-pen-to-square" data-id="${expense.id}"></i>
                </button>
                <button class="btn-delete" data-id="${expense.id}">
                    <i class="fa-solid fa-trash" data-id="${expense.id}"></i>
                </button>
            </td>
        `;

        expenseBody.appendChild(row);
    });
}

// ── STEP 6: Render the dashboard ───────────────

function renderDashboard() {

    const filtered = getFilteredExpenses();

    // Calculate grand total
    const total = filtered.reduce((sum, e) => sum + e.amount, 0);
    document.getElementById('total-amount').textContent = '₹' + total.toLocaleString('en-IN');

    // Categories to calculate
    const categories = ['Cab', 'Mobile', 'Flight', 'Internet', 'Miscellaneous'];

    // For each category, filter and sum its expenses
    categories.forEach(function (cat) {
        const catTotal = filtered
            .filter(e => e.category === cat)
            .reduce((sum, e) => sum + e.amount, 0);

        document.getElementById('cat-' + cat).textContent = '₹' + catTotal.toLocaleString('en-IN');
    });
}

// ── SMART INSIGHTS ──────────────────────────────

// Chart instances — stored so we can destroy and
// redraw them when data changes (Chart.js requirement)
let donutChart = null;
let barChart = null;

function renderInsights() {
    const filtered = getFilteredExpenses();
    const insightCards = document.getElementById('insight-cards');

    // ── BLOCK 1: Smart Text Insights ─────────────

    if (filtered.length === 0) {
        insightCards.innerHTML = `
            <div class="insight-card">
                <span class="insight-icon">💡</span>
                <div class="insight-text">
                    <strong>No Data Yet</strong>
                    Add your first expense to see smart insights.
                </div>
            </div>`;
        renderDonutChart([]);
        renderBarChart([]);
        return;
    }

    const insights = [];

    // Insight 1: Highest spending category
    const categories = ['Cab', 'Mobile', 'Flight', 'Internet', 'Miscellaneous'];
    const categoryTotals = categories.map(cat => ({
        name: cat,
        total: filtered
            .filter(e => e.category === cat)
            .reduce((sum, e) => sum + e.amount, 0)
    }));
    const topCategory = categoryTotals.reduce((a, b) => a.total > b.total ? a : b);

    if (topCategory.total > 0) {
        insights.push({
            icon: '📊',
            type: 'highlight',
            title: 'Top Spending Category',
            text: `Your highest expense is <strong>${topCategory.name}</strong> at ₹${topCategory.total.toLocaleString('en-IN')}`
        });
    }

    // Insight 2: Month-over-month comparison
    const months = [...new Set(expenses.map(e => e.date.substring(0, 7)))].sort();
    if (months.length >= 2) {
        const lastMonth = months[months.length - 1];
        const prevMonth = months[months.length - 2];
        const lastTotal = expenses
            .filter(e => e.date.startsWith(lastMonth))
            .reduce((sum, e) => sum + e.amount, 0);
        const prevTotal = expenses
            .filter(e => e.date.startsWith(prevMonth))
            .reduce((sum, e) => sum + e.amount, 0);
        const diff = lastTotal - prevTotal;
        const pct = prevTotal > 0 ? Math.abs(Math.round((diff / prevTotal) * 100)) : 0;

        if (diff > 0) {
            insights.push({
                icon: '📈',
                type: 'warning',
                title: 'Month-over-Month',
                text: `Spending is up <strong>₹${Math.abs(diff).toLocaleString('en-IN')} (${pct}%)</strong> compared to last month`
            });
        } else {
            insights.push({
                icon: '📉',
                type: 'highlight',
                title: 'Month-over-Month',
                text: `Great! Spending is down <strong>₹${Math.abs(diff).toLocaleString('en-IN')} (${pct}%)</strong> compared to last month`
            });
        }
    }

    // Insight 3: Average expense + total count
    const avg = filtered.reduce((sum, e) => sum + e.amount, 0) / filtered.length;
    insights.push({
        icon: '🧾',
        type: '',
        title: 'Expense Summary',
        text: `<strong>${filtered.length} expenses</strong> submitted · Average amount ₹${Math.round(avg).toLocaleString('en-IN')}`
    });

    // Render insight cards
    insightCards.innerHTML = insights.map(i => `
        <div class="insight-card ${i.type}">
            <span class="insight-icon">${i.icon}</span>
            <div class="insight-text">
                <strong>${i.title}</strong>
                ${i.text}
            </div>
        </div>
    `).join('');

    // ── BLOCK 2: Donut Chart ──────────────────────
    renderDonutChart(categoryTotals);

    // ── BLOCK 3: Bar Chart ────────────────────────
    renderBarChart(months);
}

// ── Donut Chart: Category Breakdown ────────────

function renderDonutChart(categoryTotals) {

    // Destroy previous chart if exists
    if (donutChart) donutChart.destroy();

    const canvas = document.getElementById('donut-chart');
    const data = categoryTotals.filter(c => c.total > 0);

    if (data.length === 0) {
        canvas.getContext('2d').clearRect(0, 0, canvas.width, canvas.height);
        return;
    }

    donutChart = new Chart(canvas, {
        type: 'doughnut',
        data: {
            labels: data.map(c => c.name),
            datasets: [{
                data: data.map(c => c.total),
                backgroundColor: ['#2F77B5', '#61CE70', '#18345B', '#f57f17', '#e53935'],
                borderWidth: 2,
                borderColor: '#ffffff'
            }]
        },
        options: {
            responsive: true,
            maintainAspectRatio: false,
            plugins: {
                legend: {
                    position: 'bottom',
                    labels: {
                        font: { family: 'Poppins', size: 12 },
                        padding: 16
                    }
                },
                tooltip: {
                    callbacks: {
                        label: ctx => ` ₹${ctx.raw.toLocaleString('en-IN')}`
                    }
                }
            }
        }
    });
}

// ── Bar Chart: Monthly Trend ────────────────────

function renderBarChart(months) {

    // Destroy previous chart if exists
    if (barChart) barChart.destroy();

    const canvas = document.getElementById('bar-chart');

    if (months.length === 0) {
        canvas.getContext('2d').clearRect(0, 0, canvas.width, canvas.height);
        return;
    }

    const monthTotals = months.map(month => ({
        label: new Date(month + '-01').toLocaleString('default', { month: 'short', year: '2-digit' }),
        total: expenses
            .filter(e => e.date.startsWith(month))
            .reduce((sum, e) => sum + e.amount, 0)
    }));

    barChart = new Chart(canvas, {
        type: 'bar',
        data: {
            labels: monthTotals.map(m => m.label),
            datasets: [{
                label: 'Total Expenses (₹)',
                data: monthTotals.map(m => m.total),
                backgroundColor: '#2F77B5',
                borderRadius: 6,
                borderSkipped: false
            }]
        },
        options: {
            responsive: true,
            maintainAspectRatio: false,
            plugins: {
                legend: { display: false },
                tooltip: {
                    callbacks: {
                        label: ctx => ` ₹${ctx.raw.toLocaleString('en-IN')}`
                    }
                }
            },
            scales: {
                y: {
                    beginAtZero: true,
                    ticks: {
                        font: { family: 'Poppins', size: 11 },
                        callback: val => '₹' + val.toLocaleString('en-IN')
                    },
                    grid: { color: '#f0f0f0' }
                },
                x: {
                    ticks: { font: { family: 'Poppins', size: 11 } },
                    grid: { display: false }
                }
            }
        }
    });
}

// ── STEP 7: Populate month filter dropdown ──────

function populateMonthFilter() {

    // Get unique months from expenses
    const months = [...new Set(expenses.map(e => e.date.substring(0, 7)))].sort();

    // Remember current selection
    const current = monthFilter.value;

    // Reset dropdown keeping "All" option
    monthFilter.innerHTML = '<option value="all">All Months</option>';

    // Add one option per unique month
    months.forEach(function (month) {
        const [year, m] = month.split('-');
        const label = new Date(year, m - 1).toLocaleString('default', { month: 'long', year: 'numeric' });
        const option = document.createElement('option');
        option.value = month;
        option.textContent = label;
        monthFilter.appendChild(option);
    });

    // Restore previous selection
    monthFilter.value = months.includes(current) ? current : 'all';
}

// ── STEP 8: Populate project filter dropdown ────

function populateProjectFilter() {

    // Get unique projects used in expenses
    const usedProjects = [...new Set(expenses.map(e => e.project).filter(Boolean))].sort();

    // Remember current selection
    const current = projectFilter.value;

    // Reset dropdown keeping "All" option
    projectFilter.innerHTML = '<option value="all">All Projects</option>';

    usedProjects.forEach(function (name) {
        const option = document.createElement('option');
        option.value = name;
        option.textContent = name;
        projectFilter.appendChild(option);
    });

    // Restore previous selection
    projectFilter.value = usedProjects.includes(current) ? current : 'all';
}

// ── STEP 9: Get filtered expenses (month + project)

function getFilteredExpenses() {
    let filtered = expenses;

    // Filter by month
    const selectedMonth = monthFilter.value;
    if (selectedMonth !== 'all') {
        filtered = filtered.filter(e => e.date.startsWith(selectedMonth));
    }

    // Filter by project
    const selectedProject = projectFilter.value;
    if (selectedProject !== 'all') {
        filtered = filtered.filter(e => e.project === selectedProject);
    }

    return filtered;
}

// ── STEP 10: Handle delete button click ────────

expenseBody.addEventListener('click', function (event) {
    const deleteBtn = event.target.closest('.btn-delete');
    if (deleteBtn) {
        const confirmed = confirm('Are you sure you want to delete this expense?');
        if (!confirmed) return;

        const id = Number(deleteBtn.getAttribute('data-id'));

        // Remove the expense with that id from the array
        expenses = expenses.filter(e => e.id !== id);

        // Save updated array to localStorage
        localStorage.setItem('prowess-expenses', JSON.stringify(expenses));

        // Re-render table, dashboard and filters
        renderTable();
        renderDashboard();
        renderInsights();
        populateMonthFilter();
        populateProjectFilter();
    }
});

// ── STEP 11: Handle edit button click ──────────

expenseBody.addEventListener('click', function (event) {
    const editBtn = event.target.closest('.btn-edit');
    if (editBtn) {

        // Get the id of the expense to edit
        const id = Number(editBtn.getAttribute('data-id'));

        // Find that expense in the array
        const expense = expenses.find(e => e.id === id);

        // Fill the form with its values
        categoryInput.value = expense.category;
        dateInput.value = expense.date;
        amountInput.value = expense.amount;
        noteInput.value = expense.note === '—' ? '' : expense.note;

        // Populate project dropdown for that date then set value
        populateProjectDropdown(expense.date);
        projectInput.value = expense.project;

        // Remember which expense we're editing
        editingId = id;

        // Change button text to show we're in edit mode
        document.querySelector('.btn-add').textContent = '✔ Update Expense';

        // Switch to Add Expense tab and scroll to top
        switchToAddTab();
        document.querySelector('.content').scrollTop = 0;
    }
});

// ── STEP 12: Re-render when filters change ─────

monthFilter.addEventListener('change', function () {
    renderTable();
    renderDashboard();
    renderInsights();
});

projectFilter.addEventListener('change', function () {
    renderTable();
    renderDashboard();
    renderInsights();
});

// ── TAB NAVIGATION ─────────────────────────────

const tabItems = document.querySelectorAll('.tab-item');
const tabPanels = document.querySelectorAll('.tab-panel');

tabItems.forEach(function (item) {
    item.addEventListener('click', function () {

        // Remove active from all tabs and panels
        tabItems.forEach(t => t.classList.remove('active'));
        tabPanels.forEach(p => p.classList.remove('active'));

        // Activate clicked tab
        item.classList.add('active');
        const targetTab = item.getAttribute('data-tab');
        document.getElementById('tab-' + targetTab).classList.add('active');

        // Redraw charts when Insights tab is opened
        // (charts don't render correctly when panel is hidden)
        if (targetTab === 'insights') {
            renderInsights();
        }

        // Render My Profile when that tab is opened
        if (targetTab === 'my-profile') {
            renderMyProfile();
        }

        // Scroll to top of content on tab switch
        document.querySelector('.content').scrollTop = 0;
    });
});

// When edit is clicked, switch to Add Expense tab
function switchToAddTab() {
    tabItems.forEach(t => t.classList.remove('active'));
    tabPanels.forEach(p => p.classList.remove('active'));
    document.querySelector('[data-tab="add-expense"]').classList.add('active');
    document.getElementById('tab-add-expense').classList.add('active');
}

// ── PROFILE: Load and display ──────────────────

function loadProfile() {
    const profile = JSON.parse(localStorage.getItem('prowess-profile')) || null;

    if (profile) {
        document.getElementById('profile-name').textContent = profile.name || 'Employee';
        document.getElementById('profile-designation').textContent = profile.designation || '—';
        document.getElementById('profile-mobile').innerHTML =
            `<i class="fa-solid fa-phone"></i> ${profile.mobile || '—'}`;

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

// ── STEP 13: Initialize on page load ───────────

loadProfile();
renderTable();
renderDashboard();
renderInsights();
populateMonthFilter();
populateProjectFilter();

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
            '<div class="eoc-det-desg">'  + eocEscHtml(emp.designation || '—') + '</div>' +
            '<div class="eoc-det-id">'    + eocEscHtml(emp.employeeId)          + '</div>' +
        '</div>' +
        '<div class="eoc-det-grid">' +
            detRow('sitemap',             'Department',  deptName) +
            detRow('user-tie',            'Manager',     manager) +
            detRow('users',               'Team Size',   teamSz + ' direct report' + (teamSz !== 1 ? 's' : '')) +
            detRow('briefcase',           'Role',        emp.role || 'Employee') +
            detRow('circle-half-stroke',  'Status',      eocGetStatus(emp)) +
            detRow('calendar-check',      'Hire Date',   eocFmtDate(emp.hireDate)) +
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

var MP_TABS = [
    { id: 'personal',       label: 'Personal',          icon: 'fa-circle-user'    },
    { id: 'contact',        label: 'Contact',            icon: 'fa-phone'          },
    { id: 'address',        label: 'Address',            icon: 'fa-location-dot'   },
    { id: 'passport',       label: 'Passport',           icon: 'fa-passport'       },
    { id: 'identification', label: 'Identification',     icon: 'fa-id-card-clip'   },
    { id: 'emergency',      label: 'Emergency Contact',  icon: 'fa-phone-volume'   },
    { id: 'employment',     label: 'Employment',         icon: 'fa-briefcase'      },
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

// ── Main render entry-point (called when tab is activated) ────────────

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
        return;
    }

    wrapper.innerHTML =
        '<div class="mp-tabs-wrap">' +
            '<div class="ev-tabs" id="mp-tab-nav"></div>' +
            '<div class="ev-content" id="mp-tab-content"></div>' +
        '</div>';

    // Build tab nav
    mpRenderTabNav();
    mpSwitchTab('personal');
}

// ── Render the horizontal sub-tab nav buttons ─────────────────────────

function mpRenderTabNav() {
    var nav = document.getElementById('mp-tab-nav');
    if (!nav) return;
    nav.innerHTML = '';
    MP_TABS.forEach(function (tab) {
        var btn = document.createElement('button');
        btn.className   = 'ev-tab';
        btn.dataset.tab = tab.id;
        btn.innerHTML   = '<i class="fa-solid ' + tab.icon + '"></i>' + tab.label;
        btn.addEventListener('click', function () { mpSwitchTab(tab.id); });
        nav.appendChild(btn);
    });
}

// ── Activate a sub-tab, highlight button, render content ─────────────

function mpSwitchTab(tabId) {
    // Highlight button
    var nav = document.getElementById('mp-tab-nav');
    if (nav) {
        nav.querySelectorAll('.ev-tab').forEach(function (btn) {
            btn.classList.toggle('ev-tab-active', btn.dataset.tab === tabId);
        });
    }
    // Render content
    var content = document.getElementById('mp-tab-content');
    if (!content) return;
    var emp = mpGetCurrentEmployee();
    if (!emp) return;

    var renderMap = {
        personal:       mpTabPersonal,
        contact:        mpTabContact,
        address:        mpTabAddress,
        passport:       mpTabPassport,
        identification: mpTabIdentification,
        emergency:      mpTabEmergency,
        employment:     mpTabEmployment,
    };
    if (renderMap[tabId]) renderMap[tabId](emp, content);
}

// ── Shared helpers ────────────────────────────────────────────────────

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
            mpField('Nationality',    emp.nationality) +
            mpField('Marital Status', emp.maritalStatus) +
        '</div>';
}

// ── Tab 2 — Contact Information ───────────────────────────────────────

function mpTabContact(emp, el) {
    var phoneDisplay = emp.countryCode && emp.phone
        ? emp.countryCode + ' ' + emp.phone
        : (emp.phone || null);

    el.innerHTML =
        mpSectionTitle('fa-phone', 'Contact Information') +
        '<div class="ev-field-grid ev-grid-2">' +
            mpField('Mobile No.',      emp.mobile) +
            mpField('Phone No.',       phoneDisplay) +
            mpField('Business Email',  emp.businessEmail) +
            mpField('Personal Email',  emp.personalEmail) +
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
    var ids       = emp.identifications || [];
    var countries = JSON.parse(localStorage.getItem('prowess-id-countries') || '[]');
    var types     = JSON.parse(localStorage.getItem('prowess-id-types')     || '[]');

    if (ids.length === 0) {
        el.innerHTML =
            mpSectionTitle('fa-id-card-clip', 'Identification Details') +
            '<div class="ev-empty-state">' +
            '<i class="fa-solid fa-id-card-clip"></i>' +
            '<p>No identification records on file.</p></div>';
        return;
    }

    var rows = ids.map(function (rec) {
        var cName  = (countries.find(function (c) { return String(c.id) === String(rec.countryId); }) || {}).name || '—';
        var tName  = (types.find(function (t)     { return String(t.id) === String(rec.idTypeId);  }) || {}).name || '—';
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
            mpField('Relationship',    emp.ecRelationship) +
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

    el.innerHTML =
        mpSectionTitle('fa-briefcase', 'Employment Information') +
        '<div class="ev-field-grid ev-grid-2">' +
            '<div class="ev-field"><div class="ev-field-label">Status</div>' + statusBadge + '</div>' +
            '<div class="ev-field"><div class="ev-field-label">Role</div>'   + roleBadge   + '</div>' +
            mpField('Designation', emp.designation) +
            mpField('Department',  mpDeptName(emp.departmentId)) +
            mpField('Manager',     mpManagerName(emp.managerId)) +
            mpField('Hire Date',   mpFmtDate(emp.hireDate)) +
            mpField('End Date',    mpFmtDate(emp.endDate)) +
        '</div>';
}
