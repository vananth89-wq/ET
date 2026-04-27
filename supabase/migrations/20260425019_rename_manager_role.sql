-- Rename Manager role to Manager Self Service
UPDATE roles
SET name = 'Manager Self Service'
WHERE code = 'manager';

-- Verify
SELECT code, name, role_type, sort_order FROM roles WHERE code = 'manager';
