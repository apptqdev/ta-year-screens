-- TV links: lets each TV show its screen from a link with its own key, with no sign-in, so it can never be signed out.
-- Run once in the Tutor Slides Supabase project's SQL editor (safe to re-run). Like the rest of the screens setup it only
-- touches the "screens" schema and the screens' own "screen-media" image policies; no Tutor Slides table is changed.
-- (The same lines are in schema-tutor-slides.sql, so re-running that file later keeps them.)

-- ---------- TV links (no sign-in on the TVs) ----------
-- Each TV opens its own link, screens.tqacademy.co.uk/?key=…#y7-left, and never signs in, so nothing can sign it out.
-- The key (sent by the page as the x-screen-key header) only lets it READ what the screens show: the screens' own
-- content, the Tutor Slides feeds through screens.shared_doc() and the screen images. It cannot edit anything.
-- Admins create and switch off links on the site's "TV links" page (#displays). A switched-off link stops within minutes.
create table if not exists screens.display_keys (
  id         uuid primary key default gen_random_uuid(),
  key        text not null unique default replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''),
  screen     text not null check (screen ~ '^y(7|8|9|10|11)(-(left|right))?$'),
  label      text not null default '',
  disabled   boolean not null default false,
  created_at timestamptz not null default now(),
  last_seen  timestamptz
);
alter table screens.display_keys enable row level security;
grant select, insert, update, delete on screens.display_keys to authenticated;
drop policy if exists "display keys admin" on screens.display_keys;
create policy "display keys admin" on screens.display_keys for all to authenticated
  using (screens.screen_role() = 'admin') with check (screens.screen_role() = 'admin');

-- Does this request carry a TV link key that is switched on?
create or replace function screens.display_key_ok() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from screens.display_keys k
                  where not k.disabled
                    and k.key = coalesce(nullif(current_setting('request.headers', true), '')::json ->> 'x-screen-key', ''));
$$;
-- A TV checks in every two minutes: true while its link works, and the TV links page shows when it was last seen.
create or replace function screens.display_ping() returns boolean
language plpgsql volatile security definer set search_path = '' as $$
begin
  update screens.display_keys set last_seen = now()
   where not disabled and key = coalesce(nullif(current_setting('request.headers', true), '')::json ->> 'x-screen-key', '');
  return found;
end $$;
revoke all on function screens.display_key_ok() from public;
revoke all on function screens.display_ping() from public;
grant execute on function screens.display_key_ok() to anon, authenticated;
grant execute on function screens.display_ping() to anon, authenticated;

grant usage on schema screens to anon;
grant select on screens.screen_docs to anon;
drop policy if exists "docs read by tv link" on screens.screen_docs;
create policy "docs read by tv link" on screens.screen_docs for select to anon using ((select screens.display_key_ok()));
drop policy if exists "screen media read by tv link" on storage.objects;
create policy "screen media read by tv link" on storage.objects for select to anon
  using (bucket_id = 'screen-media' and (select screens.display_key_ok()));


-- screens.shared_doc() (house points, birthdays, homework) now also answers a working TV link. Same as before otherwise.
create or replace function screens.shared_doc(doc_path text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  kind text := split_part(doc_path, '/', 1);
  arg  text := split_part(doc_path, '/', 2);
  yr   int;
  today date := (now() at time zone 'Europe/London')::date;
  out  jsonb;
begin
  if screens.screen_role() is null and not screens.display_key_ok() then return null; end if; -- signed in, or a TV link

  if kind = 'housepoints' then
    if arg !~ '^y(7|8|9|10|11)$' then return null; end if;
    yr := substr(arg, 2)::int;
    select jsonb_build_object('source', 'tutor-slides', 'updatedAt', max(hp.updated_at),
             'points', coalesce(jsonb_object_agg(hp.house, hp.total), '{}'::jsonb))
      into out
      from (select h.house, sum(h.points) as total, max(h.updated_at) as updated_at
              from public.house_points h join public.students s on s.upn = h.upn
             where s.year_group::text = yr::text and h.house is not null
             group by h.house) hp;
    return case when out -> 'points' = '{}'::jsonb then null else out end;

  elsif kind = 'birthdays' then
    if arg !~ '^y(7|8|9|10|11)$' then return null; end if;
    yr := substr(arg, 2)::int;
    with days as (select (today + k) as d from generate_series(-3, 7) k),
    hits as (
      select s.forename, s.surname, s.form, d.d
        from public.students s join days d
          on extract(month from s.dob) = extract(month from d.d)
         and (extract(day from s.dob) = extract(day from d.d)
              -- 29 February birthdays show on 28 February in other years
              or (extract(month from s.dob) = 2 and extract(day from s.dob) = 29 and extract(day from d.d) = 28
                  and extract(day from (date_trunc('year', d.d) + interval '1 month 28 days')) <> 29))
       where s.year_group::text = yr::text and s.dob is not null
    ),
    named as (
      select trim(split_part(trim(forename), ' ', 1)) || coalesce(' ' || upper(left(trim(surname), 1)), '') as name,
             coalesce(form, '') as grp, d from hits
    )
    select jsonb_build_object('source', 'arbor', 'from', 'tutor-slides',
             'people', coalesce(string_agg(concat_ws(', ', name, nullif(grp, ''), to_char(d, 'DD/MM')), e'\n' order by d, name), ''),
             'list', coalesce(jsonb_agg(jsonb_build_object('name', name, 'group', grp, 'date', to_char(d, 'YYYY-MM-DD')) order by d, name), '[]'::jsonb))
      into out from named;
    return out;

  elsif kind = 'homework' then
    if screens.hw_subject(arg) is null then return null; end if;
    with raw as (
      select h.upn, h.form, h.value, h.updated_at, s.year_group::text as y,
             -- tutor group letter(s) as on the screens: 7B -> B, 10Q5 -> Q5, 11JEM -> JEM
             upper(substring(h.form from '^\s*0?(?:7|8|9|10|11)\s*[-/.]?\s*([A-Za-z]{1,3}[0-9]?)')) as grp
        from public.homework h join public.students s on s.upn = h.upn
       where h.subject = screens.hw_subject(arg) and s.year_group::text in ('7', '8', '9', '10', '11')
         -- pupils excused homework in Tutor Slides (all subjects, or just this one) are left out
         and not exists (select 1 from public.hidden_pupils x where x.upn = h.upn)
         and not exists (select 1 from public.hidden_homework x where x.upn = h.upn and x.subject = h.subject)
    ),
    -- Tutor Slides stores Sparx as 0 to 100 (%), Tassomai as points.
    r as (
      select y, grp, coalesce(value, 0) as v, updated_at from raw
       where grp is null or not (y || grp = any (screens.hidden_groups()))
    ),
    b as (  -- bands, matching HW_BANDS in index.html
      select r.*, case when arg = 'tassomai'
          then case when v >= 500 then 0 when v >= 300 then 1 when v > 0 then 2 else 3 end
          else case when v >= 100 then 0 when v >= 75 then 1 when v > 0 then 2 else 3 end end as band
        from r
    ),
    labels as (
      select * from (values (0, '500 plus', 'On 100%'), (1, '300 to 499', '75 to 99%'), (2, '1 to 299', 'Below 75%'), (3, 'Not started', 'Not started')) t(band, score_label, pct_label)
    ),
    per_group as (  -- Tassomai: average score; Sparx: % of the group on 100%
      select y, grp, case when arg = 'tassomai' then round(avg(v)) else round(100.0 * count(*) filter (where band = 0) / count(*), 1) end as val
        from b where grp is not null group by y, grp
    ),
    groups as (select y, jsonb_object_agg(grp, val) as g from per_group group by y),
    years as (
      select y, count(*) as n, round(avg(v)) as average from b group by y
    ),
    breakdown as (
      select yy.y, jsonb_agg(jsonb_build_object('label', case when arg = 'tassomai' then l.score_label else l.pct_label end,
               'value', round(100.0 * (select count(*) from b where b.y = yy.y and b.band = l.band) / yy.n, 1)) order by l.band) as segs
        from years yy cross join labels l group by yy.y
    )
    select jsonb_build_object('source', 'tutor-slides', 'what', case when arg = 'tassomai' then 'score' else 'completion' end,
             'uploadedAt', (select max(updated_at) from r), 'rows', (select count(*) from r),
             'years', coalesce(jsonb_object_agg('y' || years.y, jsonb_build_object('students', years.n, 'average', years.average,
               'groups', coalesce(groups.g, '{}'::jsonb), 'breakdown', breakdown.segs)), '{}'::jsonb))
      into out
      from years left join groups using (y) left join breakdown using (y);
    return case when out -> 'years' = '{}'::jsonb then null else out end;
  end if;
  return null;
end $$;
revoke all on function screens.shared_doc(text) from public;
grant execute on function screens.shared_doc(text) to anon, authenticated;
