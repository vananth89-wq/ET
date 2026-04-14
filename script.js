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

        // Scroll up to the form smoothly
        document.querySelector('.form-section').scrollIntoView({ behavior: 'smooth' });
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

// ── STEP 13: Initialize on page load ───────────

renderTable();
renderDashboard();
renderInsights();
populateMonthFilter();
populateProjectFilter();
