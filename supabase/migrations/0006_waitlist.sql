-- Waitlist capture for the public landing page.
--
-- This was originally numbered 0003 while the product-contract work was still on another
-- branch. The merge made that guess false: product contracts now own 0003, chat owns 0004,
-- and production lifecycle owns 0005. Migration identity is durable deployment state rather
-- than cosmetic file ordering, so the waitlist must follow them as 0006; two files claiming
-- 0003 cannot both be represented honestly in Supabase's migration history.
-- The hosted database already records this as 0006, so renaming is also what preserves deployed
-- history instead of asking operators to perform a dangerous migration-history repair.
--
-- NOT YET APPLIED. Until someone runs `supabase db push`, the landing page's waitlist route
-- returns a 503 and the form says so, rather than reporting a success it did not achieve.

create table waitlist (
    id         uuid primary key default gen_random_uuid(),
    email      text not null,
    created_at timestamptz not null default now()
);

-- Case-insensitive uniqueness. Without the lower(), Alex@x.com and alex@x.com are two
-- people, and the first mail-out tells one of them twice.
create unique index waitlist_email_key on waitlist (lower(email));

alter table waitlist enable row level security;

-- Insert-only, and deliberately granted to `anon`.
--
-- The landing page posts with the public anon key, which is extractable by anyone who opens
-- devtools. That is safe here for exactly one reason: there is no select policy, so the key
-- can add a row and can never read one back. The list of who signed up is not readable by
-- the internet, only by the service role.
--
-- The cost of this shape is that anyone can insert junk. That is the right trade for a
-- waitlist -- the alternative is a server-side secret, and the failure mode of a leaked
-- write-only key is spam, while the failure mode of a leaked read key is publishing every
-- address that trusted us with one.
create policy "anyone may join the waitlist" on waitlist for insert
    to anon, authenticated
    with check (true);
