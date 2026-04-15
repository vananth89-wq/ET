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

// ── Emergency contact country dropdown ─────────────────────────────
function populateEcCountryDropdown()       { populateCountrySelect('ec-addr-country'); }

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
            renderDesignations(); renderNationalities(); renderMaritalStatuses();
            renderIdCountries();  renderIdTypes();
            populateIdCountrySelects();
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
    populatePassportCountryDropdown();
    populateAddressCountryDropdown();
    populateEcCountryDropdown();
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
            <td class="emp-td-desg">${emp.designation || '—'}</td>
            <td>${deptName}</td>
            <td class="emp-td-mgr">${managerName !== '—' ? `<span class="emp-manager-tag">${managerName}</span>` : '<span class="emp-dash">—</span>'}</td>
            <td>${roleBadge}</td>
            <td>${statusBadge}</td>
            <td>
                <div class="emp-action-btns">
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
    const hireDate      = document.getElementById('emp-hire-date').value;
    const endDate       = document.getElementById('emp-end-date').value || '9999-12-31';
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
    const ecSameAddr     = document.getElementById('ec-same-address').checked;
    const ecAddrLine1    = document.getElementById('ec-addr-line1').value.trim();
    const ecAddrLine2    = document.getElementById('ec-addr-line2').value.trim();
    const ecAddrCity     = document.getElementById('ec-addr-city').value.trim();
    const ecAddrState    = document.getElementById('ec-addr-state').value.trim();
    const ecAddrCountry  = document.getElementById('ec-addr-country').value;

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
                         // Address
                         addrLine1, addrLine2, addrLandmark, addrCity,
                         addrDistrict, addrState, addrPin, addrCountry,
                         // Emergency contact
                         ecName, ecRelationship, ecPhone, ecAltPhone, ecEmail,
                         ecSameAddr, ecAddrLine1, ecAddrLine2,
                         ecAddrCity, ecAddrState, ecAddrCountry };
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
            // Address
            addrLine1, addrLine2, addrLandmark, addrCity,
            addrDistrict, addrState, addrPin, addrCountry,
            // Emergency contact
            ecName, ecRelationship, ecPhone, ecAltPhone, ecEmail,
            ecSameAddr, ecAddrLine1, ecAddrLine2,
            ecAddrCity, ecAddrState, ecAddrCountry
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
        document.getElementById('ec-addr-line1').value   = emp.ecAddrLine1    || '';
        document.getElementById('ec-addr-line2').value   = emp.ecAddrLine2    || '';
        document.getElementById('ec-addr-city').value    = emp.ecAddrCity     || '';
        document.getElementById('ec-addr-state').value   = emp.ecAddrState    || '';
        document.getElementById('ec-addr-country').value = emp.ecAddrCountry  || '';
        // Restore same-address checkbox and lock fields if it was checked
        const sameAddrCb = document.getElementById('ec-same-address');
        sameAddrCb.checked = !!emp.ecSameAddr;
        ecToggleSameAddress(!!emp.ecSameAddr);

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

// ── Emergency Contact — same-address logic ──────

function ecToggleSameAddress(checked) {
    const fields = document.querySelectorAll('#ec-address-fields input, #ec-address-fields select');
    if (checked) {
        // Copy current employee address values → EC address fields
        var mapping = [
            ['emp-addr-line1',  'ec-addr-line1'],
            ['emp-addr-line2',  'ec-addr-line2'],
            ['emp-addr-city',   'ec-addr-city'],
            ['emp-addr-state',  'ec-addr-state'],
            ['emp-addr-country','ec-addr-country']
        ];
        mapping.forEach(function(pair) {
            var src = document.getElementById(pair[0]);
            var dst = document.getElementById(pair[1]);
            if (src && dst) dst.value = src.value;
        });
        // Lock EC address fields
        fields.forEach(function(f) { f.disabled = true; });
    } else {
        // Unlock EC address fields
        fields.forEach(function(f) { f.disabled = false; });
    }
}

// Checkbox toggle
document.getElementById('ec-same-address').addEventListener('change', function() {
    ecToggleSameAddress(this.checked);
});

// Live sync: when checkbox is checked, mirror employee address changes to EC fields in real time
var ecAddrSyncFields = [
    ['emp-addr-line1',  'ec-addr-line1'],
    ['emp-addr-line2',  'ec-addr-line2'],
    ['emp-addr-city',   'ec-addr-city'],
    ['emp-addr-state',  'ec-addr-state'],
    ['emp-addr-country','ec-addr-country']
];
ecAddrSyncFields.forEach(function(pair) {
    var srcEl = document.getElementById(pair[0]);
    var dstId = pair[1];
    if (!srcEl) return;
    var evts = srcEl.tagName === 'SELECT' ? ['change'] : ['input', 'change'];
    evts.forEach(function(evt) {
        srcEl.addEventListener(evt, function() {
            if (document.getElementById('ec-same-address').checked) {
                var dst = document.getElementById(dstId);
                if (dst) dst.value = srcEl.value;
            }
        });
    });
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
    ['ec-name','ec-relationship','ec-phone','ec-alt-phone','ec-email',
     'ec-addr-line1','ec-addr-line2','ec-addr-city','ec-addr-state','ec-addr-country']
        .forEach(function(id) {
            var el = document.getElementById(id);
            if (el) el.value = '';
        });
    document.getElementById('ec-same-address').checked = false;
    ecToggleSameAddress(false);
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
        // Resolve primary ID (explicit primary flag, or fall back to first record)
        const idCountries = JSON.parse(localStorage.getItem('prowess-id-countries')) || [];
        const idTypes     = JSON.parse(localStorage.getItem('prowess-id-types'))     || [];
        const primaryId   = getPrimaryId(emp.identifications);
        const primCountry = primaryId ? (idCountries.find(c => String(c.id) === String(primaryId.countryId))?.name || '') : '';
        const primType    = primaryId ? (idTypes.find(t => String(t.id) === String(primaryId.idTypeId))?.name || '')     : '';

        return {
            '#':                   i + 1,
            'Employee ID':         emp.employeeId,
            'Full Name':           emp.name,
            'Designation':         emp.designation     || '',
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
            'Nationality':         emp.nationality        || '',
            'Marital Status':      emp.maritalStatus      || '',
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

/** Seed ID reference data if not already present */
function initIdReferenceData() {
    if (!localStorage.getItem('prowess-id-countries')) {
        localStorage.setItem('prowess-id-countries', JSON.stringify(DEFAULT_ID_COUNTRIES));
    }
    if (!localStorage.getItem('prowess-id-types')) {
        localStorage.setItem('prowess-id-types', JSON.stringify(DEFAULT_ID_TYPES));
    }
}

// ── Populate all country selects used in the ID feature ──────

function populateIdCountrySelects() {
    const countries = JSON.parse(localStorage.getItem('prowess-id-countries')) || [];
    const sorted    = [...countries].sort((a, b) => a.name.localeCompare(b.name));

    // Employee form – Add ID country dropdown
    const empSel  = document.getElementById('emp-id-country');
    const empCur  = empSel ? empSel.value : '';
    if (empSel) {
        empSel.innerHTML = '<option value="">-- Select Country --</option>';
        sorted.forEach(function (c) {
            const o = document.createElement('option');
            o.value = c.id; o.textContent = c.name;
            empSel.appendChild(o);
        });
        empSel.value = empCur;
    }

    // Reference Data tab – ID Types form country select
    const refSel = document.getElementById('id-type-country-select');
    const refCur = refSel ? refSel.value : '';
    if (refSel) {
        refSel.innerHTML = '<option value="">-- Country --</option>';
        sorted.forEach(function (c) {
            const o = document.createElement('option');
            o.value = c.id; o.textContent = c.name;
            refSel.appendChild(o);
        });
        refSel.value = refCur;
    }
}

/** Filter ID Types dropdown by selected country */
function populateIdTypeSelect(countryId) {
    const types  = JSON.parse(localStorage.getItem('prowess-id-types')) || [];
    const sel    = document.getElementById('emp-id-type');
    if (!sel) return;
    if (!countryId) {
        sel.innerHTML = '<option value="">-- Select Country first --</option>';
        sel.disabled  = true;
        return;
    }
    const filtered = types
        .filter(t => String(t.countryId) === String(countryId))
        .sort((a, b) => a.name.localeCompare(b.name));
    sel.innerHTML = '<option value="">-- Select ID Type --</option>';
    filtered.forEach(function (t) {
        const o = document.createElement('option');
        o.value = t.id; o.textContent = t.name;
        sel.appendChild(o);
    });
    sel.disabled = (filtered.length === 0);
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

// ── Render ID Countries list (Reference Data tab) ─────────────

function renderIdCountries() {
    const countries = JSON.parse(localStorage.getItem('prowess-id-countries')) || [];
    const list      = document.getElementById('id-country-list');
    if (!list) return;
    if (countries.length === 0) {
        list.innerHTML = '<li class="ref-value-empty">No countries added.</li>';
        return;
    }
    list.innerHTML = [...countries]
        .sort((a, b) => a.name.localeCompare(b.name))
        .map(c => `
            <li class="ref-value-item" data-type="id-country" data-id="${c.id}">
                <span class="ref-value-text">${c.name}</span>
                <span class="ref-value-actions">
                    <button class="ref-btn-edit"   data-type="id-country" data-id="${c.id}">Edit</button>
                    <button class="ref-btn-delete" data-type="id-country" data-id="${c.id}">Delete</button>
                </span>
            </li>`)
        .join('');
}

// ── Render ID Types list (Reference Data tab) ─────────────────

function renderIdTypes() {
    const types     = JSON.parse(localStorage.getItem('prowess-id-types'))     || [];
    const countries = JSON.parse(localStorage.getItem('prowess-id-countries')) || [];
    const list      = document.getElementById('id-type-list');
    if (!list) return;
    if (types.length === 0) {
        list.innerHTML = '<li class="ref-value-empty">No ID types added.</li>';
        return;
    }
    list.innerHTML = [...types]
        .sort((a, b) => {
            const ca = countries.find(c => c.id === a.countryId)?.name || '';
            const cb = countries.find(c => c.id === b.countryId)?.name || '';
            return ca.localeCompare(cb) || a.name.localeCompare(b.name);
        })
        .map(t => {
            const countryName = countries.find(c => c.id === t.countryId)?.name || 'Unknown';
            return `
                <li class="ref-value-item" data-type="id-type" data-id="${t.id}">
                    <span class="ref-value-text">
                        <span class="id-type-country-tag">${countryName}</span>
                        ${t.name}
                    </span>
                    <span class="ref-value-actions">
                        <button class="ref-btn-edit"   data-type="id-type" data-id="${t.id}">Edit</button>
                        <button class="ref-btn-delete" data-type="id-type" data-id="${t.id}">Delete</button>
                    </span>
                </li>`;
        })
        .join('');
}

// ── ID Countries CRUD ─────────────────────────────────────────

document.getElementById('id-country-form').addEventListener('submit', function (e) {
    e.preventDefault();
    const editId  = document.getElementById('id-country-edit-id').value;
    const name    = document.getElementById('id-country-input').value.trim();
    const countries = JSON.parse(localStorage.getItem('prowess-id-countries')) || [];

    if (editId) {
        // Edit existing
        const updated = countries.map(c => c.id === Number(editId) ? { ...c, name } : c);
        localStorage.setItem('prowess-id-countries', JSON.stringify(updated));
        document.getElementById('id-country-edit-id').value = '';
        document.getElementById('id-country-submit-btn').innerHTML = '<i class="fa-solid fa-plus"></i> Add';
        document.getElementById('id-country-cancel-btn').style.display = 'none';
    } else {
        // Add new
        const duplicate = countries.find(c => c.name.toLowerCase() === name.toLowerCase());
        if (duplicate) { alert(`"${name}" already exists.`); return; }
        countries.push({ id: Date.now(), name });
        localStorage.setItem('prowess-id-countries', JSON.stringify(countries));
    }
    document.getElementById('id-country-input').value = '';
    renderIdCountries();
    populateIdCountrySelects();
});

document.getElementById('id-country-cancel-btn').addEventListener('click', function () {
    document.getElementById('id-country-edit-id').value = '';
    document.getElementById('id-country-input').value   = '';
    document.getElementById('id-country-submit-btn').innerHTML = '<i class="fa-solid fa-plus"></i> Add';
    this.style.display = 'none';
});

document.getElementById('id-country-list').addEventListener('click', function (e) {
    const btn  = e.target.closest('[data-type="id-country"]');
    if (!btn)  return;
    const id   = Number(btn.getAttribute('data-id'));
    const countries = JSON.parse(localStorage.getItem('prowess-id-countries')) || [];
    const item = countries.find(c => c.id === id);
    if (!item) return;

    if (btn.classList.contains('ref-btn-edit')) {
        document.getElementById('id-country-edit-id').value = id;
        document.getElementById('id-country-input').value   = item.name;
        document.getElementById('id-country-submit-btn').innerHTML = '<i class="fa-solid fa-floppy-disk"></i> Update';
        document.getElementById('id-country-cancel-btn').style.display = 'inline-flex';
    }
    if (btn.classList.contains('ref-btn-delete')) {
        if (!confirm(`Delete country "${item.name}"? All linked ID Types will also be deleted.`)) return;
        const updated = countries.filter(c => c.id !== id);
        localStorage.setItem('prowess-id-countries', JSON.stringify(updated));
        // Cascade delete ID types for this country
        const types   = JSON.parse(localStorage.getItem('prowess-id-types')) || [];
        localStorage.setItem('prowess-id-types', JSON.stringify(types.filter(t => t.countryId !== id)));
        renderIdCountries();
        renderIdTypes();
        populateIdCountrySelects();
    }
});

// ── ID Types CRUD ─────────────────────────────────────────────

document.getElementById('id-type-form').addEventListener('submit', function (e) {
    e.preventDefault();
    const editId    = document.getElementById('id-type-edit-id').value;
    const countryId = Number(document.getElementById('id-type-country-select').value);
    const name      = document.getElementById('id-type-input').value.trim();
    if (!countryId) { alert('Please select a country.'); return; }
    const types = JSON.parse(localStorage.getItem('prowess-id-types')) || [];

    if (editId) {
        const updated = types.map(t => t.id === Number(editId) ? { ...t, countryId, name } : t);
        localStorage.setItem('prowess-id-types', JSON.stringify(updated));
        document.getElementById('id-type-edit-id').value = '';
        document.getElementById('id-type-submit-btn').innerHTML = '<i class="fa-solid fa-plus"></i> Add';
        document.getElementById('id-type-cancel-btn').style.display = 'none';
    } else {
        const dup = types.find(t => t.countryId === countryId && t.name.toLowerCase() === name.toLowerCase());
        if (dup) { alert(`"${name}" already exists for this country.`); return; }
        types.push({ id: Date.now(), countryId, name });
        localStorage.setItem('prowess-id-types', JSON.stringify(types));
    }
    document.getElementById('id-type-input').value = '';
    document.getElementById('id-type-country-select').value = '';
    renderIdTypes();
});

document.getElementById('id-type-cancel-btn').addEventListener('click', function () {
    document.getElementById('id-type-edit-id').value = '';
    document.getElementById('id-type-input').value   = '';
    document.getElementById('id-type-country-select').value = '';
    document.getElementById('id-type-submit-btn').innerHTML = '<i class="fa-solid fa-plus"></i> Add';
    this.style.display = 'none';
});

document.getElementById('id-type-list').addEventListener('click', function (e) {
    const btn = e.target.closest('[data-type="id-type"]');
    if (!btn) return;
    const id  = Number(btn.getAttribute('data-id'));
    const types     = JSON.parse(localStorage.getItem('prowess-id-types'))     || [];
    const countries = JSON.parse(localStorage.getItem('prowess-id-countries')) || [];
    const item      = types.find(t => t.id === id);
    if (!item) return;

    if (btn.classList.contains('ref-btn-edit')) {
        document.getElementById('id-type-edit-id').value = id;
        populateIdCountrySelects(); // ensure options present
        document.getElementById('id-type-country-select').value = item.countryId;
        document.getElementById('id-type-input').value = item.name;
        document.getElementById('id-type-submit-btn').innerHTML = '<i class="fa-solid fa-floppy-disk"></i> Update';
        document.getElementById('id-type-cancel-btn').style.display = 'inline-flex';
    }
    if (btn.classList.contains('ref-btn-delete')) {
        const countryName = countries.find(c => c.id === item.countryId)?.name || '';
        if (!confirm(`Delete ID type "${item.name}" (${countryName})?`)) return;
        localStorage.setItem('prowess-id-types', JSON.stringify(types.filter(t => t.id !== id)));
        renderIdTypes();
    }
});

// Also render ID Countries/Types when the reference-data tab is activated
// (patched into the existing tab-switch listener above via the init block)

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
    const countries = JSON.parse(localStorage.getItem('prowess-id-countries')) || [];
    const types     = JSON.parse(localStorage.getItem('prowess-id-types'))     || [];
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
        const countryName  = countries.find(c => String(c.id) === String(rec.countryId))?.name || '—';
        const typeName     = types.find(t => String(t.id) === String(rec.idTypeId))?.name      || '—';
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
    const countries   = JSON.parse(localStorage.getItem('prowess-id-countries')) || [];
    const types       = JSON.parse(localStorage.getItem('prowess-id-types'))     || [];
    const countryName = countries.find(c => String(c.id) === String(record.countryId))?.name || '—';
    const typeName    = types.find(t => String(t.id) === String(record.idTypeId))?.name       || '—';

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

    const countries = JSON.parse(localStorage.getItem('prowess-id-countries')) || [];
    const types     = JSON.parse(localStorage.getItem('prowess-id-types'))     || [];

    function buildRows(items) {
        return items.map(function ({ emp, record, status }) {
            const countryName = countries.find(c => String(c.id) === String(record.countryId))?.name || '—';
            const typeName    = types.find(t => String(t.id) === String(record.idTypeId))?.name       || '—';
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

initReferenceData();
initIdReferenceData();
populateEmployeeFormDropdowns();
populateIdCountrySelects();
populateDeptFormDropdowns();
renderEmployees();
renderDepartments();
renderOrgChart();
renderProjects();
renderWfRoles();
renderIdCountries();
renderIdTypes();

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
            popRow('id-badge',  'Designation', emp.designation || '—') +
            popRow('sitemap',   'Department',  deptName) +
            popRow('envelope',  'Email',       emp.businessEmail || '—') +
            popRow('phone',     'Mobile No',   emp.mobile || '—') +
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
