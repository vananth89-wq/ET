// ── ADMIN: Project Management ───────────────────

// Grab elements
const projectForm = document.getElementById('project-form');
const projectNameInput = document.getElementById('project-name');
const startDateInput = document.getElementById('start-date');
const endDateInput = document.getElementById('end-date');
const projectBody = document.getElementById('project-body');

// Load projects from localStorage
let projects = JSON.parse(localStorage.getItem('prowess-projects')) || [];

// ── Handle add project form ─────────────────────

projectForm.addEventListener('submit', function (event) {
    event.preventDefault();

    // Validate end date is after start date
    if (endDateInput.value < startDateInput.value) {
        alert('End date cannot be before start date.');
        return;
    }

    // Check for duplicate project name
    const duplicate = projects.find(p => p.name.toLowerCase() === projectNameInput.value.trim().toLowerCase());
    if (duplicate) {
        alert('A project with this name already exists.');
        return;
    }

    const newProject = {
        id: Date.now(),
        name: projectNameInput.value.trim().toUpperCase(),
        startDate: startDateInput.value,
        endDate: endDateInput.value
    };

    projects.push(newProject);
    localStorage.setItem('prowess-projects', JSON.stringify(projects));

    projectForm.reset();
    renderProjects();
});

// ── Render projects table ───────────────────────

function renderProjects() {
    projectBody.innerHTML = '';

    if (projects.length === 0) {
        projectBody.innerHTML = '<tr><td colspan="6" class="no-data">No projects added yet.</td></tr>';
        return;
    }

    const today = new Date().toISOString().split('T')[0];

    projects.forEach(function (project, index) {

        // Determine project status based on today's date
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
                <button class="btn-delete" data-id="${project.id}">
                    <i class="fa-solid fa-trash" data-id="${project.id}"></i>
                </button>
            </td>
        `;

        projectBody.appendChild(row);
    });
}

// ── Handle delete project ───────────────────────

projectBody.addEventListener('click', function (event) {
    const deleteBtn = event.target.closest('.btn-delete');
    if (deleteBtn) {
        const confirmed = confirm('Are you sure you want to delete this project?');
        if (!confirmed) return;

        const id = Number(deleteBtn.getAttribute('data-id'));
        projects = projects.filter(p => p.id !== id);
        localStorage.setItem('prowess-projects', JSON.stringify(projects));
        renderProjects();
    }
});

// ── Initialize on page load ─────────────────────

renderProjects();
