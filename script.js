// ── STEP 1: Grab all the elements we need ──────

const form = document.getElementById('expense-form');
const categoryInput = document.getElementById('category');
const dateInput = document.getElementById('date');
const amountInput = document.getElementById('amount');
const noteInput = document.getElementById('note');
const expenseBody = document.getElementById('expense-body');

// ── STEP 2: Load expenses from localStorage ────

// If expenses exist in browser storage, load them.
// If not, start with an empty array.
let expenses = JSON.parse(localStorage.getItem('prowess-expenses')) || [];

// ── STEP 3: Handle form submission ─────────────

form.addEventListener('submit', function (event) {

    // Prevent page from refreshing on form submit
    event.preventDefault();

    // Build an expense object from the form values
    const newExpense = {
        id: Date.now(),
        category: categoryInput.value,
        date: dateInput.value,
        amount: parseFloat(amountInput.value),
        note: noteInput.value.trim() || '—'
    };

    // Add it to our expenses array
    expenses.push(newExpense);

    // Save updated array to localStorage
    localStorage.setItem('prowess-expenses', JSON.stringify(expenses));

    // Reset the form fields
    form.reset();

    // Re-render the table and dashboard
    renderTable();
    renderDashboard();

});

// ── STEP 4: Render the expenses table ──────────

function renderTable() {

    // Clear existing rows first
    expenseBody.innerHTML = '';

    // If no expenses yet, show a friendly message
    if (expenses.length === 0) {
        expenseBody.innerHTML = '<tr><td colspan="5" class="no-data">No expenses added yet.</td></tr>';
        return;
    }

    // Loop through each expense and create a table row
    expenses.forEach(function (expense, index) {
        const row = document.createElement('tr');

        row.innerHTML = `
      <td>${index + 1}</td>
      <td>${expense.category}</td>
      <td>${expense.date}</td>
      <td>₹${expense.amount.toLocaleString('en-IN')}</td>
      <td>${expense.note}</td>
      <td>
         <button class="btn-delete" data-id="${expense.id}">
            <i class="fa-solid fa-trash" data-id="${expense.id}"></i>
        </button>
      </td>
    `;

        expenseBody.appendChild(row);
    });
}

// ── STEP 5: Render the dashboard ───────────────

function renderDashboard() {

    // Calculate grand total
    const total = expenses.reduce((sum, e) => sum + e.amount, 0);
    document.getElementById('total-amount').textContent = '₹' + total.toLocaleString('en-IN');

    // Categories to calculate
    const categories = ['Cab', 'Mobile', 'Flight', 'Internet', 'Miscellaneous'];

    // For each category, filter and sum its expenses
    categories.forEach(function (cat) {
        const catTotal = expenses
            .filter(e => e.category === cat)
            .reduce((sum, e) => sum + e.amount, 0);

        document.getElementById('cat-' + cat).textContent = '₹' + catTotal.toLocaleString('en-IN');
    });
}

// ── STEP 6: Initialize on page load ────────────

renderTable();
renderDashboard();

// ── STEP 7: Handle delete button click ─────────

expenseBody.addEventListener('click', function(event) {
  const deleteBtn = event.target.closest('.btn-delete');
  if (deleteBtn) {
    const confirmed = confirm('Are you sure you want to delete this expense?');
    if (!confirmed) return;
    const id = Number(deleteBtn.getAttribute('data-id'));

        // Remove the expense with that id from the array
        expenses = expenses.filter(e => e.id !== id);

        // Save updated array to localStorage
        localStorage.setItem('prowess-expenses', JSON.stringify(expenses));

        // Re-render table and dashboard
        renderTable();
        renderDashboard();
    }
});