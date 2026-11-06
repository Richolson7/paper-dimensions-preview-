# Paper Dimensions Command Center

Prototype and demo of the Paper Dimensions Command Center mockup. This repository is code hosting only. It is not production-ready.

`index.html` leaves `SUPABASE_URL` and `SUPABASE_ANON_KEY` blank, so the page stays in demo mode: role picker and sample data, with no database. Sample companies, people, `555` phone numbers, and `.example` addresses are mock data.

## Open the preview

Open `index.html` in a browser, or use the GitHub Pages site:

https://richolson7.github.io/paper-dimensions-preview-/

GitHub Pages is enabled from branch `main`, root `/`. That address serves this folder, including `index.html`. The keys in `index.html` are still blank, so the site stays in demo mode. Publishing these files does not create a Supabase project or invite users.

On the welcome screen the title is **Paper Dimensions Command Center · Mockup**. Choose a role to walk the sample plant. **Customer portal · Lakeshore Tube** signs in as Dana Krueger on sample data, and the header changes to **Paper Dimensions · Customer Portal**. The admin demo role is Barry.

## Files

- `index.html` — single-page mockup, including the barcode/QR label generator and lookup scanning
- `01_schema.sql` — base schema
- `02_make_first_admin.sql` — admin promotion after Barry or Pete has signed in once; the email is the placeholder `barry@REPLACE-WITH-PD-DOMAIN.com`
- `03_crm.sql` — accounts, contacts, deals, quotes, and activities
- `04_inventory_quickbooks.sql` — inventory ledger, finished rolls, and QuickBooks sync tables
- `05_quoting.sql` — price book, priced quotes, and quote requests
- `06_customer_portal.sql` — customer portal
- `07_production_log_bol.sql` — production log, order log, and bills of lading
- `SETUP.md` — setup notes shipped with the export (Paper Dimensions, Supabase project name `paper-dimensions`, Barry and Pete)
- `CUSTOMER-PORTAL.md` — customer portal guide for the screens in `index.html` and the rules in `06_customer_portal.sql`

## Database setup

`SETUP.md` plus the numbered SQL files are the database setup. Run them in the Supabase SQL Editor in this order:

1. `01_schema.sql`
2. `03_crm.sql`
3. `04_inventory_quickbooks.sql`
4. `05_quoting.sql`
5. `02_make_first_admin.sql` after the first person (Barry or Pete) has signed in once, with their email in place of the placeholder
6. `06_customer_portal.sql` in two steps: PART 1 alone, then PART 2
7. `07_production_log_bol.sql`

Name the Supabase project `paper-dimensions`. `03_crm.sql` creates `accounts`. `04_inventory_quickbooks.sql` creates `finished_rolls`. Both files are in this repository, so the database steps in `SETUP.md` can be run from these files. The customer portal guide is [`CUSTOMER-PORTAL.md`](CUSTOMER-PORTAL.md).
