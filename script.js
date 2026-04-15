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
var eocMap       = {};
var eocRoots     = [];
var eocCollapsed = new Set();
var eocSelectedId = null;
var eocFocusId    = null;
var eocZoom       = 1;
var eocPanX       = 0;
var eocPanY       = 0;
var eocDragging   = false;
var eocDragStart  = { x: 0, y: 0, px: 0, py: 0 };

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

    var wrap = document.createElement('div');
    wrap.className    = 'eoc-node-wrap';
    wrap.dataset.empId = node.employeeId;

    var card = document.createElement('div');
    card.className    = 'eoc-card';
    card.dataset.empId = node.employeeId;
    card.title = node.name + ' — click for details, double-click to focus';

    card.innerHTML =
        '<div class="eoc-avatar" style="background:' + avatarBg + ';">' + initial + '</div>' +
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

    // Load employees from localStorage (shared with admin)
    var eocEmployees = JSON.parse(localStorage.getItem('prowess-employees') || '[]');

    // Identify logged-in profile
    var profile   = JSON.parse(localStorage.getItem('prowess-profile') || '{}');
    var profileId = null;
    if (profile.name && eocEmployees.length > 0) {
        var me = eocEmployees.find(function(e) {
            return e.name && e.name.trim().toLowerCase() === profile.name.trim().toLowerCase();
        });
        if (me) profileId = me.employeeId;
    }

    var filterDept = (document.getElementById('oc-dept-filter')?.value || '');
    var empList    = eocEmployees;

    if (filterDept) {
        // Build unfiltered tree first to get ancestor chains
        eocBuildTree(eocEmployees);
        var inDept = new Set(
            eocEmployees
                .filter(function(e){ return e.departmentId === filterDept; })
                .map(function(e){ return e.employeeId; })
        );
        inDept.forEach(function(id) {
            eocReportingChain(id).forEach(function(aid) { inDept.add(aid); });
        });
        empList = eocEmployees.filter(function(e){ return inDept.has(e.employeeId); });
    }

    eocBuildTree(empList);
    eocBuildColorMap();
    eocRenderLegend();
    eocPopulateDeptFilter();

    root.innerHTML = '';

    if (eocRoots.length === 0) {
        root.innerHTML = '<p style="padding:40px;color:#aaa;text-align:center;">No employee records found.<br>Ask your admin to add employees.</p>';
        return;
    }

    var rootRow = document.createElement('div');
    rootRow.className = 'eoc-roots-row';

    eocRoots.forEach(function (node) {
        var wrap = document.createElement('div');
        wrap.className = 'eoc-root-wrap';
        wrap.appendChild(eocRenderNode(node, 0, profileId));
        rootRow.appendChild(wrap);
    });

    root.appendChild(rootRow);

    requestAnimationFrame(function () {
        eocDrawLines();
        eocApplyHighlight();
    });
}

// ── Event wiring ────────────────────────────────────────────────────
(function eocSetupEvents() {

    // Tab activation → render
    document.querySelectorAll('.tab-item[data-tab="org-chart"]').forEach(function (item) {
        item.addEventListener('click', function () {
            eocZoom = 1; eocPanX = 0; eocPanY = 0;
            eocFocusId    = null;
            eocSelectedId = null;
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
