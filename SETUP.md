# Paper Dimensions Command Center · Supabase login setup

About 20 minutes, start to finish.

## 1. Create the Supabase project (5 min)
1. supabase.com → New project. Name it `paper-dimensions`. Pick the region closest to River Falls / PD (US Central or East).
2. Save the database password somewhere safe (password manager, not email).
3. Owner: create it under an org PD can own later. If Driven hosts it, use a Driven org and add Barry or Pete as a member.

## 2. Build the database (2 min)
1. Supabase → SQL Editor → New query.
2. Paste all of `01_schema.sql` → Run. You should see "Success. No rows returned."
3. Then paste `03_crm.sql` → Run. That adds accounts, contacts, deals, quotes and activities.
   Then `04_inventory_quickbooks.sql` → Run, then `05_quoting.sql` → Run (price book, priced quotes, quote requests).
   (04) That adds the inventory ledger, finished rolls and the QuickBooks sync tables.
4. Table Editor should now show: profiles, machines, production_events, training_progress and the rest.

## 3. Turn on sign-in (3 min)
1. Authentication → Sign In / Providers → Email: ON. Turn OFF "Allow new users to sign up" (only people you invite get in).
2. Authentication → URL Configuration → Site URL: the address where the app lives (step 5). Add the same address under Redirect URLs.

## 4. Connect the app (2 min)
1. Supabase → Project Settings → API. Copy the Project URL and the `anon` public key.
2. Open `index.html`, find `SUPABASE CONFIG` near the top of the script, paste both values:
   ```
   const SUPABASE_URL='https://xxxx.supabase.co';
   const SUPABASE_ANON_KEY='eyJ...';
   ```
   The anon key is safe in the page. Row level security decides what each login can see and change.
   Never put the `service_role` key in the page.

## 5. Put it online (5 min)
GitHub Pages, same as your other hubs:
1. New repo `pd-command-center` → upload `index.html` → Settings → Pages → Deploy from branch `main`.
2. The address is `https://<github-user>.github.io/pd-command-center/`. Use it in step 3.2.

## 6. Add people (3 min)
1. Authentication → Users → Invite user. Enter Barry's email. He sets a password from the email.
2. After Barry signs in once, run `02_make_first_admin.sql` (with his email) in the SQL Editor. He's now admin.
3. Barry invites everyone else the same way. They show up in the app's **Users** tab as Operator. He sets their role there.
4. Floor Chromebooks: one login per machine (like `s2@paperdimensions.com`), role Operator, default machine set. The Chromebook stays signed in.

## Roles and what they see
| Role | Opens to | Tabs |
|---|---|---|
| Admin | Dashboard | Everything, plus Users |
| Manager | Dashboard | Everything except Users |
| Office | Dashboard | Intake, Optimizer, Jackets, Production, Inventory, Pull, Ship, Supplies, CRM, Maintenance, Safety, QR, Training |
| Operator | Floor screen | Floor, Production schedule (view only, own machine highlighted), Job Jackets, Scan, Maintenance (report), Safety, Training |
| Material handler | Pull Sheet | Pull, Scan, Inventory, Ship & Receive, QR, Safety, Training |
| Shipping & receiving | Ship & Receive | Ship & Receive, Scan, Pull, Inventory, QR, Safety, Training |
| Maintenance | Maintenance | Maintenance, Safety, Dashboard, QR, Training |

The database enforces the same rules. Hiding a tab is for convenience; the security is in the policies.

## What's live after this step (phase 1)
- Email sign-in, sign-in links, password reset, roles, turning people off.
- Users tab: admin sets roles and default machines.
- Floor screen: every tap writes to `production_events`. Dashboard updates instantly on every other screen through Supabase realtime.
- Offline: taps queue on the Chromebook and sync when Wi-Fi is back. Each tap has a unique ID, so retries never double-count.
- Settings: machine names, widths, rated speed and plant targets save to the database.
- Training: each person's lessons and quiz scores save to their login. Team progress is real.

## Phase 2 (tables are already built)
Inventory and scanning, PO intake, optimizer orders, job jackets, pull sheet, shipping and receiving, maintenance, supplies and paper targets, and the CRM. These screens still run on demo data until wired.

## QuickBooks Online (phase 2)
- Needs QuickBooks Online **Plus or Advanced** (inventory tracking).
- One QuickBooks inventory item per paper grade PD buys, one per finished grade sold from PD stock, and a "Slitting" service item for toll jobs.
- Connect once: an admin clicks Connect on the QuickBooks tab and signs in to Intuit. Tokens are stored where only the sync function can read them.
- A Supabase Edge Function runs every few minutes: pushes ledger rows marked `pending` (inventory adjustments, invoices) and pulls customers, item costs, open bills and invoice payment status.
- Customer-owned paper, moves and pulls never go to QuickBooks. The database marks them `skipped` automatically.

## Customer portal
- Run `06_customer_portal.sql` in two steps: PART 1 alone, then PART 2.
- Customers use the same web address. Invite them like staff (Authentication → Invite user), then in the Users tab set role **Customer** and pick their account.
- A customer login can only ever see its own account: finished rolls, their paper in your racks, their orders, their releases and documents. The database enforces it, so even a hand-typed request can't reach another customer's data or anything internal.
- Releases confirm themselves when the rolls are on hand and the time slot has room. Anything else lands in Ship & Receive → Customer releases as "Needs review" and raises a CRM task.

## Production log, order log and BOLs
- Run `07_production_log_bol.sql`.
- Every finished roll is its own row: roll number, master it came from, length, diameter, weight, splices, QC, machine and operator. A roll on QC hold can't be staged or shipped. The database blocks it.
- Every step of an order writes to the order log, so anyone can see where an order is and who touched it.
- BOLs are stored with carrier, PRO, trailer and seal numbers, and a photo of the signed copy.
- Set the plant address in Settings → Company. It prints on every BOL.
