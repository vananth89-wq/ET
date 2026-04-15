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
        if (tab === 'reference-data') { renderDesignations(); renderNationalities(); renderMaritalStatuses(); }
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
        o.value = d.value; o.textContent = d.value;
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

    employeeBody.innerHTML = '';

    if (employees.length === 0) {
        employeeBody.innerHTML = '<tr><td colspan="9" class="no-data">No employees added yet.</td></tr>';
        return;
    }

    if (list.length === 0) {
        employeeBody.innerHTML = '<tr><td colspan="9" class="no-data">No employees match the current filters.</td></tr>';
        return;
    }

    list.forEach(function (emp, index) {
        const roleBadge   = getRoleBadge(emp.role || 'Employee');
        const statusBadge = getEmpStatusBadge(getEmpStatus(emp));
        const deptName    = emp.departmentId
            ? (departments.find(d => d.deptId === emp.departmentId)?.name || emp.departmentId)
            : '—';
        const managerName = emp.managerId
            ? (employees.find(e => e.employeeId === emp.managerId)?.name || emp.managerId)
            : '—';
        const row = document.createElement('tr');
        row.innerHTML = `
            <td>${index + 1}</td>
            <td><strong>${emp.employeeId}</strong></td>
            <td>${emp.name}</td>
            <td>${emp.designation || '—'}</td>
            <td>${deptName}</td>
            <td>${managerName}</td>
            <td>${roleBadge}</td>
            <td>${statusBadge}</td>
            <td>
                <button class="btn-edit" data-id="${emp.id}">
                    <i class="fa-solid fa-pen-to-square" data-id="${emp.id}"></i>
                </button>
                <button class="btn-delete" data-id="${emp.id}">
                    <i class="fa-solid fa-trash" data-id="${emp.id}"></i>
                </button>
            </td>
        `;
        employeeBody.appendChild(row);
    });
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

    const name          = document.getElementById('emp-name').value.trim();
    const employeeId    = document.getElementById('emp-id').value.trim().toUpperCase();
    const designation   = document.getElementById('emp-designation').value.trim();
    const countryCode   = document.getElementById('emp-country-code').value;
    const phoneRaw      = document.getElementById('emp-phone').value.trim();
    const departmentId  = document.getElementById('emp-department').value;
    const managerId     = document.getElementById('emp-manager-id').value;
    const hireDate      = document.getElementById('emp-hire-date').value;
    const endDate       = document.getElementById('emp-end-date').value || '9999-12-31';
    const nationality   = document.getElementById('emp-nationality').value.trim();
    const maritalStatus = document.getElementById('emp-marital-status').value;

    const businessEmail = document.getElementById('emp-business-email').value.trim().toLowerCase();
    const personalEmail = document.getElementById('emp-personal-email').value.trim().toLowerCase();

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
                         businessEmail, personalEmail };
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
            businessEmail, personalEmail, photo: null
        };
        employees.push(newEmployee);

        // Update manager's role
        if (managerId) updateManagerRole(managerId);

        // Set first employee as active profile
        if (employees.length === 1) {
            localStorage.setItem('prowess-profile', JSON.stringify(newEmployee));
        }

        profileForm.reset();
        // Re-apply end date default after reset
        document.getElementById('emp-end-date').value = '9999-12-31';
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
        document.getElementById('emp-business-email').value  = emp.businessEmail || '';
        document.getElementById('emp-personal-email').value  = emp.personalEmail || '';
        document.getElementById('emp-phone-error').style.display         = 'none';
        document.getElementById('emp-business-email-error').style.display = 'none';
        document.getElementById('emp-personal-email-error').style.display = 'none';

        // Populate all dropdowns first, then restore saved values
        editingEmpId = id;
        populateEmployeeFormDropdowns();
        document.getElementById('emp-designation').value     = emp.designation || '';
        document.getElementById('emp-nationality').value     = emp.nationality || '';
        document.getElementById('emp-marital-status').value  = emp.maritalStatus || '';
        document.getElementById('emp-department').value      = emp.departmentId || '';
        document.getElementById('emp-manager-id').value      = emp.managerId || '';

        empSubmitBtn.innerHTML = '<i class="fa-solid fa-floppy-disk"></i> Update Employee';
        empCancelBtn.style.display = 'inline-flex';
        document.getElementById('emp-form-title').textContent = 'Edit Employee — ' + emp.name;
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

function resetEmpForm() {
    profileForm.reset();
    editingEmpId = null;
    // Re-apply defaults that reset() clears
    document.getElementById('emp-end-date').value = '9999-12-31';
    document.getElementById('emp-country-code').value = '+91';
    document.getElementById('emp-phone-error').style.display          = 'none';
    document.getElementById('emp-business-email-error').style.display = 'none';
    document.getElementById('emp-personal-email-error').style.display = 'none';
    document.getElementById('emp-form-title').textContent = 'New Employee';
    empSubmitBtn.innerHTML = '<i class="fa-solid fa-plus"></i> Add Employee';
    empCancelBtn.style.display = 'none';
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
    deptBody.innerHTML = '';

    if (departments.length === 0) {
        deptBody.innerHTML = '<tr><td colspan="9" class="no-data">No departments added yet.</td></tr>';
        return;
    }

    // Sort: Active → Upcoming → Expired
    const sorted = [...departments].sort((a, b) => {
        const order = { Active: 0, Upcoming: 1, Expired: 2 };
        return order[getDeptStatus(a)] - order[getDeptStatus(b)];
    });

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

    sorted.forEach(function (dept, index) {
        const headName   = dept.headId
            ? (employees.find(e => e.employeeId === dept.headId)?.name || dept.headId)
            : '—';
        const parentName = dept.parentDeptId
            ? (departments.find(d => d.deptId === dept.parentDeptId)?.name || dept.parentDeptId)
            : '—';

        const row = document.createElement('tr');
        row.innerHTML = `
            <td>${index + 1}</td>
            <td><strong>${dept.deptId}</strong></td>
            <td>${dept.name}</td>
            <td>${headName}</td>
            <td>${parentName}</td>
            <td>${fmtDate(dept.startDate)}</td>
            <td>${fmtDate(dept.endDate)}</td>
            <td>${statusBadge(dept)}</td>
            <td>
                <button class="btn-edit" data-id="${dept.id}">
                    <i class="fa-solid fa-pen-to-square" data-id="${dept.id}"></i>
                </button>
                <button class="btn-delete" data-id="${dept.id}">
                    <i class="fa-solid fa-trash" data-id="${dept.id}"></i>
                </button>
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
    const container = document.getElementById('org-chart');
    if (!container) return;

    // Only show departments active on the selected view date
    const activeDepts = departments.filter(d => isDeptActive(d));

    if (activeDepts.length === 0) {
        const msg = departments.length === 0
            ? 'Add departments to see the org chart.'
            : `No active departments on ${formatViewDate()}.`;
        container.innerHTML = `<p class="no-data" style="padding:20px 0;">${msg}</p>`;
        return;
    }

    // Root = active depts whose parent is either absent or not active on this date
    const activeDeptIds = new Set(activeDepts.map(d => d.deptId));
    const roots = activeDepts.filter(d => !d.parentDeptId || !activeDeptIds.has(d.parentDeptId));

    container.innerHTML = `
        <div class="org-tree-wrap">
            <ul class="org-tree">
                ${roots.map(d => buildTreeNode(d, activeDepts)).join('')}
            </ul>
        </div>
    `;
}

function formatViewDate() {
    return new Date(deptViewDate + 'T00:00:00').toLocaleDateString('en-GB', { day:'2-digit', month:'short', year:'numeric' });
}

function buildTreeNode(dept, activeDepts) {
    const empCount = employees.filter(e => e.departmentId === dept.deptId).length;
    const headName = dept.headId
        ? (employees.find(e => e.employeeId === dept.headId)?.name || dept.headId)
        : 'No Head';

    // Only recurse into children that are also active on the selected date
    const children = activeDepts.filter(d => d.parentDeptId === dept.deptId);

    return `
        <li>
            <div class="org-node">
                <div class="org-node-header">
                    <span class="org-dept-id">${dept.deptId}</span>
                    <span class="org-dept-name">${dept.name}</span>
                </div>
                <div class="org-node-body">
                    <span class="org-head">
                        <i class="fa-solid fa-user-tie"></i> ${headName}
                    </span>
                    <span class="org-emp-count">
                        <i class="fa-solid fa-users"></i> ${empCount} emp
                    </span>
                </div>
            </div>
            ${children.length > 0
                ? `<ul>${children.map(c => buildTreeNode(c, activeDepts)).join('')}</ul>`
                : ''
            }
        </li>
    `;
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

function initReferenceData() {
    if (!localStorage.getItem('prowess-designations')) {
        const seeded = DEFAULT_DESIGNATIONS.map((v, i) => ({ id: i + 1, value: v }));
        localStorage.setItem('prowess-designations', JSON.stringify(seeded));
    }
    if (!localStorage.getItem('prowess-nationalities')) {
        const seeded = DEFAULT_NATIONALITIES.map((v, i) => ({ id: i + 1, value: v }));
        localStorage.setItem('prowess-nationalities', JSON.stringify(seeded));
    }
    if (!localStorage.getItem('prowess-marital-statuses')) {
        const seeded = DEFAULT_MARITAL_STATUSES.map((v, i) => ({ id: i + 1, value: v }));
        localStorage.setItem('prowess-marital-statuses', JSON.stringify(seeded));
    }
}

// ── Populate dropdowns in employee form ──────────

function populateDesignationDropdown() {
    const items = JSON.parse(localStorage.getItem('prowess-designations')) || [];
    const sel   = document.getElementById('emp-designation');
    const cur   = sel.value;
    sel.innerHTML = '<option value="">-- Select Designation --</option>';
    items.sort((a, b) => a.value.localeCompare(b.value)).forEach(function (item) {
        const opt = document.createElement('option');
        opt.value = item.value;
        opt.textContent = item.value;
        sel.appendChild(opt);
    });
    sel.value = cur;
}

function populateNationalityDropdown() {
    const items = JSON.parse(localStorage.getItem('prowess-nationalities')) || [];
    const sel   = document.getElementById('emp-nationality');
    const cur   = sel.value;
    sel.innerHTML = '<option value="">-- Select Nationality --</option>';
    items.sort((a, b) => a.value.localeCompare(b.value)).forEach(function (item) {
        const opt = document.createElement('option');
        opt.value = item.value;
        opt.textContent = item.value;
        sel.appendChild(opt);
    });
    sel.value = cur;
}

function populateMaritalStatusDropdown() {
    const items = JSON.parse(localStorage.getItem('prowess-marital-statuses')) || [];
    const sel   = document.getElementById('emp-marital-status');
    const cur   = sel.value;
    sel.innerHTML = '<option value="">-- Select --</option>';
    items.forEach(function (item) {
        const opt = document.createElement('option');
        opt.value = item.value;
        opt.textContent = item.value;
        sel.appendChild(opt);
    });
    sel.value = cur;
}

// ── Render reference lists ────────────────────────

function renderDesignations() {
    const items = JSON.parse(localStorage.getItem('prowess-designations')) || [];
    const list  = document.getElementById('designation-list');
    list.innerHTML = '';
    if (items.length === 0) {
        list.innerHTML = '<li class="ref-empty">No designations added yet.</li>';
        return;
    }
    [...items].sort((a, b) => a.value.localeCompare(b.value)).forEach(function (item) {
        const li = document.createElement('li');
        li.className = 'ref-value-item';
        li.innerHTML = `
            <span class="ref-value-text">${item.value}</span>
            <span class="ref-value-actions">
                <button class="ref-btn-edit" data-type="designation" data-id="${item.id}" title="Edit">
                    <i class="fa-solid fa-pen-to-square"></i>
                </button>
                <button class="ref-btn-delete" data-type="designation" data-id="${item.id}" title="Delete">
                    <i class="fa-solid fa-trash"></i>
                </button>
            </span>`;
        list.appendChild(li);
    });
}

function renderNationalities() {
    const items = JSON.parse(localStorage.getItem('prowess-nationalities')) || [];
    const list  = document.getElementById('nationality-list');
    list.innerHTML = '';
    if (items.length === 0) {
        list.innerHTML = '<li class="ref-empty">No nationalities added yet.</li>';
        return;
    }
    [...items].sort((a, b) => a.value.localeCompare(b.value)).forEach(function (item) {
        const li = document.createElement('li');
        li.className = 'ref-value-item';
        li.innerHTML = `
            <span class="ref-value-text">${item.value}</span>
            <span class="ref-value-actions">
                <button class="ref-btn-edit" data-type="nationality" data-id="${item.id}" title="Edit">
                    <i class="fa-solid fa-pen-to-square"></i>
                </button>
                <button class="ref-btn-delete" data-type="nationality" data-id="${item.id}" title="Delete">
                    <i class="fa-solid fa-trash"></i>
                </button>
            </span>`;
        list.appendChild(li);
    });
}

function renderMaritalStatuses() {
    const items = JSON.parse(localStorage.getItem('prowess-marital-statuses')) || [];
    const list  = document.getElementById('marital-list');
    list.innerHTML = '';
    if (items.length === 0) {
        list.innerHTML = '<li class="ref-empty">No marital statuses added yet.</li>';
        return;
    }
    items.forEach(function (item) {
        const li = document.createElement('li');
        li.className = 'ref-value-item';
        li.innerHTML = `
            <span class="ref-value-text">${item.value}</span>
            <span class="ref-value-actions">
                <button class="ref-btn-edit" data-type="marital" data-id="${item.id}" title="Edit">
                    <i class="fa-solid fa-pen-to-square"></i>
                </button>
                <button class="ref-btn-delete" data-type="marital" data-id="${item.id}" title="Delete">
                    <i class="fa-solid fa-trash"></i>
                </button>
            </span>`;
        list.appendChild(li);
    });
}

// ── Designation CRUD ─────────────────────────────

const designationForm      = document.getElementById('designation-form');
const designationInput     = document.getElementById('designation-input');
const designationSubmitBtn = document.getElementById('designation-submit-btn');
const designationCancelBtn = document.getElementById('designation-cancel-btn');

designationForm.addEventListener('submit', function (e) {
    e.preventDefault();
    const value = designationInput.value.trim();
    if (!value) return;

    const items  = JSON.parse(localStorage.getItem('prowess-designations')) || [];
    const editId = Number(document.getElementById('designation-edit-id').value);

    if (editId) {
        const updated = items.map(i => i.id === editId ? { ...i, value } : i);
        localStorage.setItem('prowess-designations', JSON.stringify(updated));
    } else {
        const exists = items.some(i => i.value.toLowerCase() === value.toLowerCase());
        if (exists) { alert('This designation already exists.'); return; }
        const newId = items.length ? Math.max(...items.map(i => i.id)) + 1 : 1;
        items.push({ id: newId, value });
        localStorage.setItem('prowess-designations', JSON.stringify(items));
    }

    resetDesignationForm();
    renderDesignations();
    populateDesignationDropdown();
});

document.getElementById('designation-list').addEventListener('click', function (e) {
    const editBtn   = e.target.closest('.ref-btn-edit[data-type="designation"]');
    const deleteBtn = e.target.closest('.ref-btn-delete[data-type="designation"]');

    if (editBtn) {
        const id    = Number(editBtn.getAttribute('data-id'));
        const items = JSON.parse(localStorage.getItem('prowess-designations')) || [];
        const item  = items.find(i => i.id === id);
        if (!item) return;
        designationInput.value = item.value;
        document.getElementById('designation-edit-id').value = id;
        designationSubmitBtn.innerHTML = '<i class="fa-solid fa-floppy-disk"></i> Update';
        designationCancelBtn.style.display = 'inline-block';
        designationInput.focus();
    }

    if (deleteBtn) {
        if (!confirm('Delete this designation?')) return;
        const id      = Number(deleteBtn.getAttribute('data-id'));
        const items   = JSON.parse(localStorage.getItem('prowess-designations')) || [];
        const updated = items.filter(i => i.id !== id);
        localStorage.setItem('prowess-designations', JSON.stringify(updated));
        renderDesignations();
        populateDesignationDropdown();
    }
});

designationCancelBtn.addEventListener('click', resetDesignationForm);

function resetDesignationForm() {
    designationForm.reset();
    document.getElementById('designation-edit-id').value = '';
    designationSubmitBtn.innerHTML = '<i class="fa-solid fa-plus"></i> Add';
    designationCancelBtn.style.display = 'none';
}

// ── Nationality CRUD ──────────────────────────────

const nationalityForm      = document.getElementById('nationality-form');
const nationalityInput     = document.getElementById('nationality-input');
const nationalitySubmitBtn = document.getElementById('nationality-submit-btn');
const nationalityCancelBtn = document.getElementById('nationality-cancel-btn');

nationalityForm.addEventListener('submit', function (e) {
    e.preventDefault();
    const value = nationalityInput.value.trim();
    if (!value) return;

    const items  = JSON.parse(localStorage.getItem('prowess-nationalities')) || [];
    const editId = Number(document.getElementById('nationality-edit-id').value);

    if (editId) {
        const updated = items.map(i => i.id === editId ? { ...i, value } : i);
        localStorage.setItem('prowess-nationalities', JSON.stringify(updated));
    } else {
        const exists = items.some(i => i.value.toLowerCase() === value.toLowerCase());
        if (exists) { alert('This nationality already exists.'); return; }
        const newId = items.length ? Math.max(...items.map(i => i.id)) + 1 : 1;
        items.push({ id: newId, value });
        localStorage.setItem('prowess-nationalities', JSON.stringify(items));
    }

    resetNationalityForm();
    renderNationalities();
    populateNationalityDropdown();
});

document.getElementById('nationality-list').addEventListener('click', function (e) {
    const editBtn   = e.target.closest('.ref-btn-edit[data-type="nationality"]');
    const deleteBtn = e.target.closest('.ref-btn-delete[data-type="nationality"]');

    if (editBtn) {
        const id    = Number(editBtn.getAttribute('data-id'));
        const items = JSON.parse(localStorage.getItem('prowess-nationalities')) || [];
        const item  = items.find(i => i.id === id);
        if (!item) return;
        nationalityInput.value = item.value;
        document.getElementById('nationality-edit-id').value = id;
        nationalitySubmitBtn.innerHTML = '<i class="fa-solid fa-floppy-disk"></i> Update';
        nationalityCancelBtn.style.display = 'inline-block';
        nationalityInput.focus();
    }

    if (deleteBtn) {
        if (!confirm('Delete this nationality?')) return;
        const id      = Number(deleteBtn.getAttribute('data-id'));
        const items   = JSON.parse(localStorage.getItem('prowess-nationalities')) || [];
        const updated = items.filter(i => i.id !== id);
        localStorage.setItem('prowess-nationalities', JSON.stringify(updated));
        renderNationalities();
        populateNationalityDropdown();
    }
});

nationalityCancelBtn.addEventListener('click', resetNationalityForm);

function resetNationalityForm() {
    nationalityForm.reset();
    document.getElementById('nationality-edit-id').value = '';
    nationalitySubmitBtn.innerHTML = '<i class="fa-solid fa-plus"></i> Add';
    nationalityCancelBtn.style.display = 'none';
}

// ── Marital Status CRUD ───────────────────────────

const maritalForm      = document.getElementById('marital-form');
const maritalInput     = document.getElementById('marital-input');
const maritalSubmitBtn = document.getElementById('marital-submit-btn');
const maritalCancelBtn = document.getElementById('marital-cancel-btn');

maritalForm.addEventListener('submit', function (e) {
    e.preventDefault();
    const value = maritalInput.value.trim();
    if (!value) return;

    const items  = JSON.parse(localStorage.getItem('prowess-marital-statuses')) || [];
    const editId = Number(document.getElementById('marital-edit-id').value);

    if (editId) {
        const updated = items.map(i => i.id === editId ? { ...i, value } : i);
        localStorage.setItem('prowess-marital-statuses', JSON.stringify(updated));
    } else {
        const exists = items.some(i => i.value.toLowerCase() === value.toLowerCase());
        if (exists) { alert('This marital status already exists.'); return; }
        const newId = items.length ? Math.max(...items.map(i => i.id)) + 1 : 1;
        items.push({ id: newId, value });
        localStorage.setItem('prowess-marital-statuses', JSON.stringify(items));
    }

    resetMaritalForm();
    renderMaritalStatuses();
    populateMaritalStatusDropdown();
});

document.getElementById('marital-list').addEventListener('click', function (e) {
    const editBtn   = e.target.closest('.ref-btn-edit[data-type="marital"]');
    const deleteBtn = e.target.closest('.ref-btn-delete[data-type="marital"]');

    if (editBtn) {
        const id    = Number(editBtn.getAttribute('data-id'));
        const items = JSON.parse(localStorage.getItem('prowess-marital-statuses')) || [];
        const item  = items.find(i => i.id === id);
        if (!item) return;
        maritalInput.value = item.value;
        document.getElementById('marital-edit-id').value = id;
        maritalSubmitBtn.innerHTML = '<i class="fa-solid fa-floppy-disk"></i> Update';
        maritalCancelBtn.style.display = 'inline-block';
        maritalInput.focus();
    }

    if (deleteBtn) {
        if (!confirm('Delete this marital status?')) return;
        const id      = Number(deleteBtn.getAttribute('data-id'));
        const items   = JSON.parse(localStorage.getItem('prowess-marital-statuses')) || [];
        const updated = items.filter(i => i.id !== id);
        localStorage.setItem('prowess-marital-statuses', JSON.stringify(updated));
        renderMaritalStatuses();
        populateMaritalStatusDropdown();
    }
});

maritalCancelBtn.addEventListener('click', resetMaritalForm);

function resetMaritalForm() {
    maritalForm.reset();
    document.getElementById('marital-edit-id').value = '';
    maritalSubmitBtn.innerHTML = '<i class="fa-solid fa-plus"></i> Add';
    maritalCancelBtn.style.display = 'none';
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
        return {
            '#':                i + 1,
            'Employee ID':      emp.employeeId,
            'Full Name':        emp.name,
            'Designation':      emp.designation     || '',
            'Department':       deptName,
            'Manager':          managerName,
            'Mobile':           emp.mobile          || '',
            'Business Email':   emp.businessEmail   || '',
            'Personal Email':   emp.personalEmail   || '',
            'Nationality':      emp.nationality     || '',
            'Marital Status':   emp.maritalStatus   || '',
            'Hire Date':        formatDateDisplay(emp.hireDate),
            'End Date':         formatDateDisplay(emp.endDate),
            'Role':             emp.role            || 'Employee',
            'Status':           getEmpStatus(emp)
        };
    });

    const ws = XLSX.utils.json_to_sheet(rows);

    // Column widths
    ws['!cols'] = [
        {wch:4},{wch:12},{wch:22},{wch:22},{wch:20},{wch:20},
        {wch:18},{wch:28},{wch:28},{wch:14},{wch:14},{wch:12},{wch:12},{wch:12},{wch:10}
    ];

    const wb = XLSX.utils.book_new();
    XLSX.utils.book_append_sheet(wb, ws, 'Employees');

    const today = new Date().toISOString().split('T')[0];
    XLSX.writeFile(wb, `Prowess_Employees_${today}.xlsx`);
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
    XLSX.writeFile(wb, `Prowess_Departments_${today}.xlsx`);
}

// ── Wire export buttons ──────────────────────────

document.getElementById('btn-export-employees').addEventListener('click', exportEmployees);
document.getElementById('btn-export-departments').addEventListener('click', exportDepartments);

// ── INITIALIZE ──────────────────────────────────

initReferenceData();
populateEmployeeFormDropdowns();
populateDeptFormDropdowns();
renderEmployees();
renderDepartments();
renderOrgChart();
renderProjects();
renderWfRoles();
