-- Run AFTER the first person (Barry or Pete) has signed in once.
-- Swap in their email. This makes them admin so they can set everyone else's role in the app.
update public.profiles set role = 'admin' where email = 'barry@REPLACE-WITH-PD-DOMAIN.com';
