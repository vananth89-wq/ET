-- =============================================================================
-- Migration : 20260420003_seed_reference_data.sql
-- Project   : Prowess Expense Tracker
-- Created   : 2026-04-20
-- Description: Seeds picklists, picklist_values, and currencies tables.
--              Idempotent: skips if data already exists.
-- =============================================================================

-- Add unique constraint on picklists.picklist_id (safe if already exists)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'picklists_picklist_id_key'
    AND   conrelid = 'picklists'::regclass
  ) THEN
    ALTER TABLE picklists ADD CONSTRAINT picklists_picklist_id_key UNIQUE (picklist_id);
  END IF;
END $$;

-- Add unique constraint on currencies.code (safe if already exists)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'currencies_code_key'
    AND   conrelid = 'currencies'::regclass
  ) THEN
    ALTER TABLE currencies ADD CONSTRAINT currencies_code_key UNIQUE (code);
  END IF;
END $$;


-- =============================================================================
-- PICKLISTS
-- =============================================================================

INSERT INTO picklists (picklist_id, name) VALUES
  ('DESIGNATION',       'Designation'),
  ('NATIONALITY',       'Nationality'),
  ('MARITAL_STATUS',    'Marital Status'),
  ('RELATIONSHIP_TYPE', 'Relationship Type'),
  ('ID_COUNTRY',        'ID Country'),
  ('ID_TYPE',           'ID Type'),
  ('LOCATION',          'Location'),
  ('CURRENCY',          'Currency'),
  ('Expense_Category',  'Expense Category')
ON CONFLICT (picklist_id) DO NOTHING;


-- =============================================================================
-- PICKLIST VALUES — only seed if table is empty
-- =============================================================================

DO $seed$
BEGIN

IF (SELECT COUNT(*) FROM picklist_values) > 0 THEN
  RAISE NOTICE 'picklist_values already seeded — skipping.';
  RETURN;
END IF;

-- ─── DESIGNATION ─────────────────────────────────────────────────────────────
INSERT INTO picklist_values (picklist_id, value, ref_id, active)
SELECT pl.id, v.value, v.ref_id, true
FROM picklists pl,
(VALUES
  ('D001','Analyst'),('D002','Associate'),('D003','Business Analyst'),
  ('D004','Chief Executive Officer'),('D005','Chief Financial Officer'),
  ('D006','Chief Operating Officer'),('D007','Chief Technology Officer'),
  ('D008','Consultant'),('D009','Data Engineer'),('D010','Data Scientist'),
  ('D011','DevOps Engineer'),('D012','Director'),('D013','Engineering Manager'),
  ('D014','Executive Assistant'),('D015','Finance Manager'),
  ('D016','Frontend Developer'),('D017','Full Stack Developer'),
  ('D018','HR Business Partner'),('D019','HR Manager'),
  ('D020','Infrastructure Engineer'),('D021','IT Manager'),
  ('D022','Junior Developer'),('D023','Lead Developer'),
  ('D024','Marketing Manager'),('D025','Mobile Developer'),
  ('D026','Operations Manager'),('D027','Principal Engineer'),
  ('D028','Product Manager'),('D029','Product Owner'),
  ('D030','Program Manager'),('D031','Project Manager'),
  ('D032','QA Engineer'),('D033','Sales Manager'),('D034','Scrum Master'),
  ('D035','Senior Analyst'),('D036','Senior Consultant'),
  ('D037','Senior Developer'),('D038','Senior Engineer'),
  ('D039','Senior Manager'),('D040','Software Architect'),
  ('D041','Software Engineer'),('D042','Solution Architect'),
  ('D043','Support Engineer'),('D044','Systems Administrator'),
  ('D045','Technical Lead'),('D046','Test Engineer'),
  ('D047','UI/UX Designer'),('D048','Vice President')
) AS v(ref_id, value)
WHERE pl.picklist_id = 'DESIGNATION';

-- ─── NATIONALITY ─────────────────────────────────────────────────────────────
INSERT INTO picklist_values (picklist_id, value, ref_id, active)
SELECT pl.id, v.value, v.ref_id, true
FROM picklists pl,
(VALUES
  ('N001','Afghan'),('N002','Albanian'),('N003','Algerian'),('N004','American'),
  ('N005','Angolan'),('N006','Argentine'),('N007','Armenian'),('N008','Australian'),
  ('N009','Austrian'),('N010','Azerbaijani'),('N011','Bahraini'),('N012','Bangladeshi'),
  ('N013','Belgian'),('N014','Bolivian'),('N015','Brazilian'),('N016','British'),
  ('N017','Bulgarian'),('N018','Cambodian'),('N019','Cameroonian'),('N020','Canadian'),
  ('N021','Chilean'),('N022','Chinese'),('N023','Colombian'),('N024','Congolese'),
  ('N025','Costa Rican'),('N026','Croatian'),('N027','Cuban'),('N028','Czech'),
  ('N029','Danish'),('N030','Dutch'),('N031','Ecuadorian'),('N032','Egyptian'),
  ('N033','Emirati'),('N034','Estonian'),('N035','Ethiopian'),('N036','Finnish'),
  ('N037','French'),('N038','Georgian'),('N039','German'),('N040','Ghanaian'),
  ('N041','Greek'),('N042','Guatemalan'),('N043','Hungarian'),('N044','Icelandic'),
  ('N045','Indian'),('N046','Indonesian'),('N047','Iranian'),('N048','Iraqi'),
  ('N049','Irish'),('N050','Israeli'),('N051','Italian'),('N052','Ivorian'),
  ('N053','Jamaican'),('N054','Japanese'),('N055','Jordanian'),('N056','Kazakhstani'),
  ('N057','Kenyan'),('N058','Korean'),('N059','Kuwaiti'),('N060','Latvian'),
  ('N061','Lebanese'),('N062','Libyan'),('N063','Lithuanian'),('N064','Malaysian'),
  ('N065','Maldivian'),('N066','Maltese'),('N067','Mauritian'),('N068','Mexican'),
  ('N069','Mongolian'),('N070','Moroccan'),('N071','Mozambican'),('N072','Namibian'),
  ('N073','Nepalese'),('N074','New Zealander'),('N075','Nigerian'),('N076','Norwegian'),
  ('N077','Omani'),('N078','Pakistani'),('N079','Palestinian'),('N080','Panamanian'),
  ('N081','Peruvian'),('N082','Philippine'),('N083','Polish'),('N084','Portuguese'),
  ('N085','Qatari'),('N086','Romanian'),('N087','Russian'),('N088','Rwandan'),
  ('N089','Saudi'),('N090','Senegalese'),('N091','Serbian'),('N092','Singaporean'),
  ('N093','Slovak'),('N094','Slovenian'),('N095','Somali'),('N096','South African'),
  ('N097','Spanish'),('N098','Sri Lankan'),('N099','Sudanese'),('N100','Swedish'),
  ('N101','Swiss'),('N102','Syrian'),('N103','Taiwanese'),('N104','Tanzanian'),
  ('N105','Thai'),('N106','Trinidadian'),('N107','Tunisian'),('N108','Turkish'),
  ('N109','Ugandan'),('N110','Ukrainian'),('N111','Uruguayan'),('N112','Venezuelan'),
  ('N113','Vietnamese'),('N114','Yemeni'),('N115','Zambian'),('N116','Zimbabwean')
) AS v(ref_id, value)
WHERE pl.picklist_id = 'NATIONALITY';

-- ─── MARITAL STATUS ──────────────────────────────────────────────────────────
INSERT INTO picklist_values (picklist_id, value, ref_id, active)
SELECT pl.id, v.value, v.ref_id, true
FROM picklists pl,
(VALUES
  ('M001','Single'),('M002','Married'),('M003','Divorced'),
  ('M004','Widowed'),('M005','Separated')
) AS v(ref_id, value)
WHERE pl.picklist_id = 'MARITAL_STATUS';

-- ─── RELATIONSHIP TYPE ───────────────────────────────────────────────────────
INSERT INTO picklist_values (picklist_id, value, ref_id, active)
SELECT pl.id, v.value, v.ref_id, true
FROM picklists pl,
(VALUES
  ('R001','Father'),('R002','Mother'),('R003','Spouse'),
  ('R004','Brother'),('R005','Sister'),('R006','Son'),
  ('R007','Daughter'),('R008','Guardian'),('R009','Friend'),
  ('R010','Colleague'),('R011','Other')
) AS v(ref_id, value)
WHERE pl.picklist_id = 'RELATIONSHIP_TYPE';

-- ─── CURRENCY ────────────────────────────────────────────────────────────────
INSERT INTO picklist_values (picklist_id, value, ref_id, active)
SELECT pl.id, v.value, v.ref_id, true
FROM picklists pl,
(VALUES
  ('C001','Indian Rupee'),('C002','US Dollar'),('C003','Euro'),
  ('C004','British Pound'),('C005','Saudi Riyal'),('C006','UAE Dirham'),
  ('C007','Singapore Dollar'),('C008','Australian Dollar'),('C009','Canadian Dollar'),
  ('C010','Japanese Yen'),('C011','Chinese Yuan'),('C012','Malaysian Ringgit'),
  ('C013','Qatari Riyal'),('C014','Kuwaiti Dinar'),('C015','Bahraini Dinar')
) AS v(ref_id, value)
WHERE pl.picklist_id = 'CURRENCY';

-- ─── EXPENSE CATEGORY ────────────────────────────────────────────────────────
INSERT INTO picklist_values (picklist_id, value, ref_id, active)
SELECT pl.id, v.value, v.ref_id, true
FROM picklists pl,
(VALUES
  ('X001','Cab'),('X002','Flight'),('X003','Hotel'),
  ('X004','Internet'),('X005','Meals'),('X006','Miscellaneous'),
  ('X007','Mobile'),('X008','Office Supplies'),('X009','Training'),('X010','Travel')
) AS v(ref_id, value)
WHERE pl.picklist_id = 'Expense_Category';

-- ─── ID_COUNTRY ──────────────────────────────────────────────────────────────
INSERT INTO picklist_values (picklist_id, value, ref_id, active)
SELECT pl.id, v.value, v.ref_id, true
FROM picklists pl,
(VALUES
  ('G001','India'),('G002','Saudi Arabia'),('G003','United Arab Emirates'),
  ('G004','Malaysia'),('G005','Singapore'),('G006','United States'),
  ('G007','United Kingdom'),('G008','Qatar'),('G009','Kuwait'),
  ('G010','Bahrain'),('G011','Oman'),('G012','Pakistan'),
  ('G013','Sri Lanka'),('G014','Bangladesh'),('G015','Nepal')
) AS v(ref_id, value)
WHERE pl.picklist_id = 'ID_COUNTRY';

-- ─── ID_TYPE (parent = ID_COUNTRY row) ───────────────────────────────────────
INSERT INTO picklist_values (picklist_id, value, ref_id, parent_value_id, active)
SELECT
  (SELECT id FROM picklists WHERE picklist_id = 'ID_TYPE'),
  v.value,
  v.ref_id,
  (SELECT pv.id FROM picklist_values pv
   JOIN   picklists pl ON pl.id = pv.picklist_id
   WHERE  pl.picklist_id = 'ID_COUNTRY' AND pv.ref_id = v.country_ref),
  true
FROM (VALUES
  ('T001','G001','Aadhaar'),
  ('T002','G001','PAN'),
  ('T003','G001','Voter ID'),
  ('T004','G001','Driving License'),
  ('T005','G002','Iqama'),
  ('T006','G002','Saudi National ID'),
  ('T007','G003','Emirates ID'),
  ('T008','G003','UAE Residence Visa'),
  ('T009','G004','MyKad'),
  ('T010','G004','MyPR'),
  ('T011','G004','Work Permit'),
  ('T012','G005','NRIC'),
  ('T013','G005','FIN'),
  ('T014','G005','Employment Pass'),
  ('T015','G006','Social Security'),
  ('T016','G006','Green Card'),
  ('T017','G006','Driver''s License'),
  ('T018','G007','National Insurance'),
  ('T019','G007','BRP'),
  ('T020','G008','Qatar ID'),
  ('T021','G008','Qatar Residence Permit'),
  ('T022','G009','Civil ID'),
  ('T023','G010','CPR'),
  ('T024','G011','Oman Resident Card'),
  ('T025','G012','CNIC'),
  ('T026','G012','NICOP'),
  ('T027','G013','NIC'),
  ('T028','G014','NID'),
  ('T029','G015','Citizenship Certificate')
) AS v(ref_id, country_ref, value);

-- ─── LOCATION (parent = ID_COUNTRY row) ──────────────────────────────────────
INSERT INTO picklist_values (picklist_id, value, ref_id, parent_value_id, active)
SELECT
  (SELECT id FROM picklists WHERE picklist_id = 'LOCATION'),
  v.value,
  v.ref_id,
  (SELECT pv.id FROM picklist_values pv
   JOIN   picklists pl ON pl.id = pv.picklist_id
   WHERE  pl.picklist_id = 'ID_COUNTRY' AND pv.ref_id = v.country_ref),
  true
FROM (VALUES
  ('L001','G001','Chennai'),
  ('L002','G001','Bangalore'),
  ('L003','G001','Hyderabad'),
  ('L004','G001','Osmanabad'),
  ('L005','G001','Mumbai'),
  ('L006','G001','Delhi'),
  ('L007','G002','Riyadh'),
  ('L008','G002','Jeddah'),
  ('L009','G002','Jubail'),
  ('L010','G002','Dammam'),
  ('L011','G003','Dubai'),
  ('L012','G003','Abu Dhabi'),
  ('L013','G003','Sharjah'),
  ('L014','G004','Kuala Lumpur'),
  ('L015','G004','Johor Bahru'),
  ('L016','G005','Singapore'),
  ('L017','G006','New York'),
  ('L018','G006','Houston'),
  ('L019','G007','London'),
  ('L020','G008','Doha'),
  ('L021','G009','Kuwait City'),
  ('L022','G010','Manama'),
  ('L023','G011','Muscat'),
  ('L024','G012','Karachi'),
  ('L025','G012','Lahore'),
  ('L026','G013','Colombo'),
  ('L027','G014','Dhaka'),
  ('L028','G015','Kathmandu')
) AS v(ref_id, country_ref, value);

END $seed$;


-- =============================================================================
-- CURRENCIES TABLE — seed if empty
-- =============================================================================

INSERT INTO currencies (code, name, symbol, active)
VALUES
  ('INR', 'Indian Rupee',       '₹',   true),
  ('USD', 'US Dollar',          '$',   true),
  ('EUR', 'Euro',               '€',   true),
  ('GBP', 'British Pound',      '£',   true),
  ('SAR', 'Saudi Riyal',        '﷼',   true),
  ('AED', 'UAE Dirham',         'د.إ', true),
  ('SGD', 'Singapore Dollar',   'S$',  true),
  ('AUD', 'Australian Dollar',  'A$',  true),
  ('CAD', 'Canadian Dollar',    'C$',  true),
  ('JPY', 'Japanese Yen',       '¥',   true),
  ('CNY', 'Chinese Yuan',       '¥',   true),
  ('MYR', 'Malaysian Ringgit',  'RM',  true),
  ('QAR', 'Qatari Riyal',       '﷼',   true),
  ('KWD', 'Kuwaiti Dinar',      'KD',  true),
  ('BHD', 'Bahraini Dinar',     'BD',  true)
ON CONFLICT (code) DO NOTHING;


-- =============================================================================
-- END OF MIGRATION 20260420003_seed_reference_data.sql
-- =============================================================================
