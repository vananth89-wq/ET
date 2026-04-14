// ── ADMIN: Tab Navigation ───────────────────────

const tabItems = document.querySelectorAll('.tab-item');
const tabPanels = document.querySelectorAll('.tab-panel');

tabItems.forEach(function (item) {
    item.addEventListener('click', function () {
        tabItems.forEach(t => t.classList.remove('active'));
        tabPanels.forEach(p => p.classList.remove('active'));
        item.classList.add('active');
        document.getElementById('tab-' + item.getAttribute('data-tab')).classList.add('active');
    });
});

// ── ADMIN: Employee Management ──────────────────

const profileForm   = document.getElementById('profile-form');
const empName       = document.getElementById('emp-name');
const empId         = document.getElementById('emp-id');
const empDesig      = document.getElementById('emp-designation');
const empMobile     = document.getElementById('emp-mobile');
const empSubmitBtn  = document.getElementById('emp-submit-btn');
const empCancelBtn  = document.getElementById('emp-cancel-btn');
const employeeBody  = document.getElementById('employee-body');

let employees  = JSON.parse(localStorage.getItem('prowess-employees')) || [];
let editingEmpId = null; // tracks which employee is being edited

// ── Render employees table ──────────────────────

function renderEmployees() {
    employeeBody.innerHTML = '';

    if (employees.length === 0) {
        employeeBody.innerHTML = '<tr><td colspan="6" class="no-data">No employees added yet.</td></tr>';
        return;
    }

    employees.forEach(function (emp, index) {
        const row = document.createElement('tr');
        row.innerHTML = `
            <td>${index + 1}</td>
            <td><strong>${emp.employeeId}</strong></td>
            <td>${emp.name}</td>
            <td>${emp.designation}</td>
            <td>${emp.mobile}</td>
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

// ── Handle add / update employee ────────────────

profileForm.addEventListener('submit', function (event) {
    event.preventDefault();

    const name        = empName.value.trim();
    const employeeId  = empId.value.trim().toUpperCase();
    const designation = empDesig.value.trim();
    const mobile      = empMobile.value.trim();

    if (editingEmpId !== null) {
        // ── EDIT MODE ──
        employees = employees.map(function (emp) {
            if (emp.id === editingEmpId) {
                return { ...emp, name, employeeId, designation, mobile };
            }
            return emp;
        });

        // Also update localStorage profile if this is the current profile
        const currentProfile = JSON.parse(localStorage.getItem('prowess-profile')) || {};
        if (currentProfile.id === editingEmpId) {
            localStorage.setItem('prowess-profile', JSON.stringify({
                ...currentProfile, name, employeeId, designation, mobile
            }));
        }

        resetForm();

    } else {
        // ── ADD MODE ──
        // Check for duplicate Employee ID
        const duplicate = employees.find(e =>
            e.employeeId.toLowerCase() === employeeId.toLowerCase()
        );
        if (duplicate) {
            alert('An employee with this ID already exists.');
            return;
        }

        const newEmployee = {
            id: Date.now(),
            name,
            employeeId,
            designation,
            mobile,
            photo: null
        };

        employees.push(newEmployee);

        // Set first employee as the active profile automatically
        if (employees.length === 1) {
            localStorage.setItem('prowess-profile', JSON.stringify(newEmployee));
        }
    }

    localStorage.setItem('prowess-employees', JSON.stringify(employees));
    renderEmployees();
});

// ── Handle edit and delete clicks ──────────────

employeeBody.addEventListener('click', function (event) {

    // ── EDIT ──
    const editBtn = event.target.closest('.btn-edit');
    if (editBtn) {
        const id = Number(editBtn.getAttribute('data-id'));
        const emp = employees.find(e => e.id === id);

        // Fill form with employee data
        empName.value  = emp.name;
        empId.value    = emp.employeeId;
        empDesig.value = emp.designation;
        empMobile.value = emp.mobile;

        // Switch to edit mode
        editingEmpId = id;
        empSubmitBtn.innerHTML = '<i class="fa-solid fa-floppy-disk"></i> Update Employee';
        empCancelBtn.style.display = 'inline-block';

        // Scroll to form
        profileForm.scrollIntoView({ behavior: 'smooth' });
        return;
    }

    // ── DELETE ──
    const deleteBtn = event.target.closest('.btn-delete');
    if (deleteBtn) {
        if (!confirm('Are you sure you want to delete this employee?')) return;

        const id = Number(deleteBtn.getAttribute('data-id'));
        employees = employees.filter(e => e.id !== id);
        localStorage.setItem('prowess-employees', JSON.stringify(employees));

        // If deleted employee was the active profile, clear it
        const currentProfile = JSON.parse(localStorage.getItem('prowess-profile')) || {};
        if (currentProfile.id === id) {
            // Set next available employee as profile, or clear
            if (employees.length > 0) {
                localStorage.setItem('prowess-profile', JSON.stringify(employees[0]));
            } else {
                localStorage.removeItem('prowess-profile');
            }
        }

        renderEmployees();
    }
});

// ── Cancel edit ─────────────────────────────────

empCancelBtn.addEventListener('click', resetForm);

function resetForm() {
    profileForm.reset();
    editingEmpId = null;
    empSubmitBtn.innerHTML = '<i class="fa-solid fa-plus"></i> Add Employee';
    empCancelBtn.style.display = 'none';
}

// ── ADMIN: Project Management ───────────────────

const projectForm     = document.getElementById('project-form');
const projectBody     = document.getElementById('project-body');
const projSubmitBtn   = document.getElementById('proj-submit-btn');
const projCancelBtn   = document.getElementById('proj-cancel-btn');
let projects          = JSON.parse(localStorage.getItem('prowess-projects')) || [];
let editingProjectId  = null;

projectForm.addEventListener('submit', function (event) {
    event.preventDefault();

    const name      = document.getElementById('project-name').value.trim().toUpperCase();
    const startDate = document.getElementById('start-date').value;
    const endDate   = document.getElementById('end-date').value;

    if (endDate < startDate) {
        alert('End date cannot be before start date.');
        return;
    }

    if (editingProjectId !== null) {
        // ── EDIT MODE: update existing project ──
        projects = projects.map(function (p) {
            if (p.id === editingProjectId) {
                return { ...p, name, startDate, endDate };
            }
            return p;
        });
        resetProjectForm();

    } else {
        // ── ADD MODE: create new project ────────
        const duplicate = projects.find(p => p.name === name);
        if (duplicate) {
            alert('A project with this name already exists.');
            return;
        }
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
        let status = '';
        if (today < project.startDate) {
            status = '<span class="badge badge-upcoming">Upcoming</span>';
        } else if (today > project.endDate) {
            status = '<span class="badge badge-closed">Closed</span>';
        } else {
            status = '<span class="badge badge-active">Active</span>';
        }

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

    // ── EDIT ──
    const editBtn = event.target.closest('.btn-edit');
    if (editBtn) {
        const id = Number(editBtn.getAttribute('data-id'));
        const project = projects.find(p => p.id === id);

        // Fill form with project data
        document.getElementById('project-name').value = project.name;
        document.getElementById('start-date').value   = project.startDate;
        document.getElementById('end-date').value     = project.endDate;

        // Switch to edit mode
        editingProjectId = id;
        projSubmitBtn.innerHTML = '<i class="fa-solid fa-floppy-disk"></i> Update Project';
        projCancelBtn.style.display = 'inline-block';

        projectForm.scrollIntoView({ behavior: 'smooth' });
        return;
    }

    // ── DELETE ──
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

// ── Initialize ──────────────────────────────────

renderEmployees();
renderProjects();
