# Customer portal

This is the guide for the customer portal in this repository. It sits next to [`06_customer_portal.sql`](06_customer_portal.sql) and expands the short “Customer portal” section in [`SETUP.md`](SETUP.md).

It describes two things that are actually in this export:

- The customer screens in `index.html` (demo data, role picker).
- The database rules in `06_customer_portal.sql` (and the customer bill-of-lading read added in `07_production_log_bol.sql`).

Where the screen and the SQL differ, both are spelled out. Nothing here is a finished plant system.

Open the demo at [https://richolson7.github.io/paper-dimensions-preview-/](https://richolson7.github.io/paper-dimensions-preview-/). On the welcome screen, choose **Customer portal · Lakeshore Tube**. That signs in as Dana Krueger at Lakeshore Tube, on sample data. The header changes to **Paper Dimensions · Customer Portal**.

## What a customer can see

A customer login only gets four tabs: **My inventory**, **My orders**, **Releases**, and **Documents**. Every other tab is hidden.

### My inventory

- Finished rolls for their parts: part number, description, on hand, released and not picked up, available, in production (with the job number), weeks of cover, and their minimum.
- A **Release** button when rolls are available, and **Order more** when available stock is under the minimum.
- A minimum field. The screen says setting a minimum emails the customer and flags the Paper Dimensions team when stock drops below it.
- **Your paper in our warehouse**: master roll number, grade, width, footage, date received, and days here.

The sample parts are Lakeshore’s `LT-25-300`, `LT-25-200`, and `LT-30-200`. Northfield and Ridgeway parts are in the file and do not show for the Lakeshore demo login.

### My orders

Open orders for that company: Paper Dimensions job number, the customer’s PO, product, quantity, requested ship date, projected done date from the schedule, and a status (in production, need paper, or shipped). The screen says the customer is emailed if a date moves.

### Releases

- A request form: part, number of rolls, an optional customer release number, and a dock time slot. Each slot shows the date, pickup or truck window, and how many rolls of room are left. A full slot cannot be picked. The screen says requests close 24 hours before the slot.
- The customer’s own releases, with status.
- A **Cancel** button on a release whose status is **Confirmed**.
- Standing releases for that company: same pull, same time, with an on/off switch.

### Documents

For releases marked **Shipped**, the screen offers **Packing list**, **BOL**, and **Invoice**. In this mockup each button prints a short page with the release id, the company, the roll count, the part, and their release number. The printed line reads **Paper Dimensions** to that company. It does not load a stored file.

### What the SQL is built to store

Once `06_customer_portal.sql` has run, a customer database login is allowed to read:

- Their own finished rolls, through orders whose customer name matches their account name.
- Their own master rolls (paper in the racks), matched by account id.
- Their own production orders, matched by that same account name.
- Their own items (`customer_items`): part number, description, grade, width, core, minimum rolls, and rolls per week. They can update those rows (the minimums). They cannot create items.
- Dock release windows (the slots are shared; every customer login can read them).
- Their own releases, and they can insert a new one only as status **Requested**, with themselves as the requester.
- Their own standing releases, and they can update those rows (the on/off switch).
- Their own single row in `accounts`.

`07_production_log_bol.sql` adds a read of their own bills of lading, matched to their releases or to shipments of their orders. The Documents tab does not query that table yet.

## What a customer cannot see

- Any other customer’s rolls, paper, orders, items, releases, standing releases, account, or bills of lading. Each customer policy checks `my_account()` or the account name from `my_account_name()`.
- Staff tools. `06_customer_portal.sql` replaces `my_role()` so it returns null when the role is `customer`. Every existing staff policy that calls `my_role()` or `has_role()` with a staff role then fails for them. That covers the dashboard, PO intake, optimizer, job jackets, production, order log, production log, plant inventory, pull sheet, ship and receive, scan, floor, maintenance, safety, CRM, paper and supplies, labels, QuickBooks, training, settings, and users.
- Costs and margins. The customer tabs do not show dollars or margin. Price book, quote prices, and paper-target costs stay on staff policies (`admin`, `manager`, `office`). A customer login does not satisfy those policies.

Hiding a tab is only the screen. The isolation that holds after Supabase is connected is row level security.

## How to turn the portal on

Run this only after the earlier scripts, in the Supabase SQL Editor. `06_customer_portal.sql` says to run it after scripts 01 through 05. Those scripts are all in this repository:

1. `01_schema.sql` — profiles, machines, `production_orders`, `master_rolls`, and the first `my_role()` / `has_role()`.
2. `03_crm.sql` — `accounts` (and contacts, deals, quotes, activities).
3. `04_inventory_quickbooks.sql` — inventory ledger, `finished_rolls`, and the QuickBooks sync tables.
4. `05_quoting.sql` — price book, priced quotes, and quote requests.

`SETUP.md` names the Supabase project `paper-dimensions` and walks through that same order.

Then:

1. Run **PART 1** by itself and wait until it succeeds. PART 1 is only this line:

   `alter type public.app_role add value if not exists 'customer';`

   Postgres has to commit the new enum value before the rest of the script can use it.

2. Run **PART 2** (everything after that line in the same file). PART 2 adds `profiles.account_id`, customer items, release windows, releases, standing releases, the customer policies, and the auto-confirm trigger.

PART 2 references `public.accounts` and `public.finished_rolls`. `03_crm.sql` creates `accounts`. `04_inventory_quickbooks.sql` creates `finished_rolls`. With 01 through 05 already applied, PART 2 can run from the files in this repo.

Orders and finished rolls are matched by the account **name** (`production_orders.customer` equals `my_account_name()`). Paper, items, releases, and standing releases are matched by account **id**. The account name in `accounts` has to match the customer text already stored on the orders, or the customer will not see those orders or the finished rolls on them.

`release_windows.cutoff_hours` defaults to 24. The auto-confirm trigger does not reject a request for falling inside that cutoff. The “24 hours before” line is the label on the demo screen.

## How to invite a customer

Customers use the same web address as staff. There is no separate portal site in this export.

1. In Supabase: **Authentication → Users → Invite user**. Enter their email. They set a password from that email. New sign-ups stay off, the same as for staff (`SETUP.md` step 3).
2. After they exist, an admin opens the app’s **Users** tab and sets **Role** to **Customer**. The role list in `index.html` includes Customer. New people arrive as Operator until someone changes that. Barry (or Pete) is the first admin: after that person signs in once, run `02_make_first_admin.sql` with their email in place of `barry@REPLACE-WITH-PD-DOMAIN.com`.
3. Tie the login to their company with `profiles.account_id` (added in PART 2) set to that company’s row in `accounts`. `my_account()` reads this column and returns it only when the profile is active and the role is `customer`.

`SETUP.md` says to pick their account in the Users tab. The Users screen in this export has name, email, role, default machine, and active/off. It does not include an account dropdown, and a live sign-in does not copy `account_id` onto the session. Set `account_id` in the Supabase table editor (or with SQL) when the column exists. Until the page is wired to the portal tables, those four tabs still read the sample lists in `index.html`, not that customer’s rows.

## Release flow

Database rule, from the `confirm_release()` trigger in PART 2. It runs before the new row is saved:

1. The customer inserts a release with status **Requested**.
2. On hand is the count of `finished_rolls` for that item whose status is `made` or `staged`. Rolls still in production are not counted.
3. Already booked is the sum of rolls on other releases for that item in **Confirmed** or **Staged**.
4. Slot used is the sum of rolls already **Confirmed** or **Staged** in the chosen window. Capacity is `release_windows.capacity_rolls`.
5. If the request fits both the leftover on-hand rolls and the leftover slot, the status becomes **Confirmed**. Otherwise it becomes **Needs review**.

Staff handle the queue on **Ship & Receive → Customer releases** (the third pill on that screen). The demo shows:

- **Needs review** → **Confirm**
- **Confirmed** → **Stage**
- **Staged** → **Picked up · ship**

The demo also adds a CRM task for each **Needs review** release: “Portal release … can’t be covered. Call them.” That task is sample-screen behavior in `index.html`. `06_customer_portal.sql` does not insert a CRM row. It only sets the release status. `SETUP.md` describes that CRM task as part of the portal; the SQL file stops at the status.

The demo request button is looser than the SQL. On the sample screen, a request can confirm from in-production rolls (`available` plus rolls still on the job) when the slot has room. The SQL trigger does not do that. It confirms only from finished rolls in `made` or `staged`.

### Cancel rules

A customer may change their own release only from **Requested** or **Confirmed** to **Cancelled**. The policy blocks any other new status. They cannot cancel **Needs review**, **Staged**, or **Shipped**.

The trigger rewrites **Requested** to **Confirmed** or **Needs review** before the insert finishes, so a customer-created row does not stay **Requested**. On the demo screen the **Cancel** button is shown only for **Confirmed**.

Staff update access for releases is `admin`, `manager`, `office`, and `shipping`.

Release statuses allowed by the table are: Requested, Confirmed, Needs review, Staged, Shipped, Cancelled.

## Standing releases

`standing_releases` is a saved pull: account, item, roll count, a rule string, and an on/off flag. The SQL comments use rules like `weekly:tue:pickup` and `biweekly:fri:delivery`.

The customer can see their own rows and turn them on or off. Creating or editing the rule is for `admin`, `manager`, and `office`.

The demo card says: “Same pull, same time, every time. We stage it without you asking.” The Lakeshore sample is 32 rolls of `LT-25-300` every Tuesday morning (on) and 16 rolls of `LT-25-200` every other Friday afternoon (off). No script in this repo reads the rule and creates a release on a schedule. The toggle in the demo only flips the sample row in the browser.

## Security

- `my_account()` returns `profiles.account_id` for the signed-in user when that profile is active and the role is `customer`. Every customer policy uses that id, or the account name looked up from it.
- `my_account_name()` is the `accounts.name` for that id. Orders and finished rolls use the name. The name match is exact.
- `my_role()` returns the profile role only when the user is active and the role is not `customer`. For a customer it returns null. Customers are not staff. `has_role(...)` is false for them on staff checks, because it requires the stored role to be one of the roles passed in, and those calls pass staff roles.
- Policies are row level security on `customer_items`, `release_windows`, `releases`, `standing_releases`, plus extra select policies on `production_orders`, `finished_rolls`, `master_rolls`, and `accounts`. Bills of lading get a customer select policy in `07_production_log_bol.sql`.
- `06_customer_portal.sql` adds `releases` and `customer_items` to the Supabase realtime publication.

A hand-typed API request still has to pass these policies. The anon key in the page, once you paste it, does not bypass them. Never put the `service_role` key in the page (`SETUP.md`).

## Honest status

This is a prototype and a demo.

- `index.html` ships with `SUPABASE_URL` and `SUPABASE_ANON_KEY` blank. With those blank, the page stays on the role picker and sample data. There is no database.
- No live keys, passwords, or service-role secrets are in this repository. Leave it that way.
- GitHub Pages serves the files in this repo from `main`, root path `/`, at [https://richolson7.github.io/paper-dimensions-preview-/](https://richolson7.github.io/paper-dimensions-preview-/). That is the static mockup. Publishing it does not create a Supabase project, invite a customer, or connect the plant.
- The customer screens are not wired to Supabase. Live sign-in loads the profile role and default machine. It does not load `account_id`, items, releases, or rolls into those four tabs.
- The portal SQL can be applied from this repo after `01_schema.sql`, `03_crm.sql`, `04_inventory_quickbooks.sql`, and `05_quoting.sql`. `accounts` and `finished_rolls` come from `03_crm.sql` and `04_inventory_quickbooks.sql`.

When Supabase is actually connected and the page is pointed at it, staff sign-in replaces the role picker. The customer tabs stay sample data until someone wires them to the tables in `06_customer_portal.sql`.
