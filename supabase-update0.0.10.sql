-- =====================================================================
-- HiBlue · update0.0.10 — Social: prietenii, block/raportare, postări, sondaje, comentarii,
--                         salvate, stories, căutare, stocare media.
-- Rulează O SINGURĂ DATĂ în Supabase → SQL Editor (după update0.0.4.sql). Idempotent.
--
-- Principii:
--  * Tabelele au RLS activ FĂRĂ politici: clientul NU poate citi/scrie direct, doar prin funcțiile RPC de mai jos
--    (security definer). Fiecare funcție verifică auth.uid(), block-urile și prietenia.
--  * Nu se folosește service_role în client. Nu se modifică tabelele existente, în afară de două coloane noi în profiles.
--  * Media (poze/video) stă în bucket-ul public 'media', doar în folderul <uid>/ al utilizatorului.
-- =====================================================================

-- ============ 0) profiles: copertă ============
alter table public.profiles add column if not exists cover text;
alter table public.profiles drop constraint if exists profiles_cover_len;
alter table public.profiles add  constraint profiles_cover_len check (char_length(coalesce(cover,'')) <= 500);

-- ============ 1) prietenii / block / raportări ============
create table if not exists public.friendships (
  user_a      uuid not null references auth.users(id) on delete cascade,
  user_b      uuid not null references auth.users(id) on delete cascade,
  requester   uuid not null references auth.users(id) on delete cascade,
  status      text not null default 'pending' check (status in ('pending','accepted')),
  created_at  timestamptz not null default now(),
  accepted_at timestamptz,
  primary key (user_a, user_b),
  check (user_a < user_b),
  check (requester = user_a or requester = user_b)
);
create index if not exists friendships_b_idx on public.friendships (user_b);

create table if not exists public.blocks (
  blocker    uuid not null references auth.users(id) on delete cascade,
  blocked    uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker, blocked),
  check (blocker <> blocked)
);
create index if not exists blocks_blocked_idx on public.blocks (blocked);

create table if not exists public.reports (
  id          bigserial primary key,
  reporter    uuid not null references auth.users(id) on delete cascade,
  target_type text not null check (target_type in ('user','post','comment','story','message')),
  target_id   text not null,
  target_user uuid,
  reason      text not null check (reason in ('spam','harassment','hate','nudity','violence','scam','impersonation','self_harm','other')),
  details     text check (char_length(coalesce(details,'')) <= 500),
  status      text not null default 'open',
  created_at  timestamptz not null default now()
);
create index if not exists reports_reporter_idx on public.reports (reporter, created_at desc);

-- ============ 2) postări, sondaje, aprecieri, comentarii, salvate ============
create table if not exists public.posts (
  id          uuid primary key default gen_random_uuid(),
  author      uuid not null references auth.users(id) on delete cascade,
  body        text not null default '' check (char_length(body) <= 3000),
  media       jsonb not null default '[]'::jsonb check (jsonb_typeof(media) = 'array' and jsonb_array_length(media) <= 10),
  audience    text not null default 'public' check (audience in ('public','friends')),
  shared_from uuid references public.posts(id) on delete set null,
  created_at  timestamptz not null default now(),
  edited_at   timestamptz
);
create index if not exists posts_author_idx  on public.posts (author, created_at desc);
create index if not exists posts_created_idx on public.posts (created_at desc, id desc);

create table if not exists public.polls (
  post_id      uuid primary key references public.posts(id) on delete cascade,
  question     text not null check (char_length(question) between 1 and 200),
  multiple     boolean not null default false,
  anonymous    boolean not null default false,
  quiz         boolean not null default false,
  explanation  text check (char_length(coalesce(explanation,'')) <= 300),
  allow_add    boolean not null default false,
  allow_change boolean not null default true,
  results      text not null default 'always' check (results in ('always','after_vote','after_close')),
  closes_at    timestamptz
);
create table if not exists public.poll_options (
  id       bigserial primary key,
  post_id  uuid not null references public.polls(post_id) on delete cascade,
  idx      int  not null,
  label    text not null check (char_length(label) between 1 and 100),
  correct  boolean not null default false,
  added_by uuid references auth.users(id) on delete set null,
  unique (post_id, idx)
);
create table if not exists public.poll_votes (
  option_id  bigint not null references public.poll_options(id) on delete cascade,
  user_id    uuid   not null references auth.users(id) on delete cascade,
  post_id    uuid   not null,
  created_at timestamptz not null default now(),
  primary key (option_id, user_id)
);
create index if not exists poll_votes_post_idx on public.poll_votes (post_id, user_id);

create table if not exists public.post_likes (
  post_id    uuid not null references public.posts(id) on delete cascade,
  user_id    uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (post_id, user_id)
);
create table if not exists public.comments (
  id         uuid primary key default gen_random_uuid(),
  post_id    uuid not null references public.posts(id) on delete cascade,
  author     uuid not null references auth.users(id) on delete cascade,
  parent_id  uuid references public.comments(id) on delete cascade,
  body       text not null check (char_length(body) between 1 and 1000),
  created_at timestamptz not null default now()
);
create index if not exists comments_post_idx on public.comments (post_id, created_at);
create table if not exists public.comment_likes (
  comment_id uuid not null references public.comments(id) on delete cascade,
  user_id    uuid not null references auth.users(id) on delete cascade,
  primary key (comment_id, user_id)
);
create table if not exists public.saves (
  user_id    uuid not null references auth.users(id) on delete cascade,
  post_id    uuid not null references public.posts(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, post_id)
);

-- ============ 3) stories ============
create table if not exists public.stories (
  id         uuid primary key default gen_random_uuid(),
  author     uuid not null references auth.users(id) on delete cascade,
  kind       text not null check (kind in ('image','video','text')),
  media_url  text,
  body       text check (char_length(coalesce(body,'')) <= 300),
  bg         text check (char_length(coalesce(bg,'')) <= 40),
  meta       jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '24 hours')
);
create index if not exists stories_author_idx on public.stories (author, created_at desc);
create index if not exists stories_exp_idx on public.stories (expires_at);
create table if not exists public.story_views (
  story_id  uuid not null references public.stories(id) on delete cascade,
  viewer    uuid not null references auth.users(id) on delete cascade,
  viewed_at timestamptz not null default now(),
  primary key (story_id, viewer)
);
create table if not exists public.story_likes (
  story_id uuid not null references public.stories(id) on delete cascade,
  user_id  uuid not null references auth.users(id) on delete cascade,
  primary key (story_id, user_id)
);

-- ============ 4) RLS: activ, fără politici (acces doar prin funcții) ============
alter table public.friendships    enable row level security;
alter table public.blocks         enable row level security;
alter table public.reports        enable row level security;
alter table public.posts          enable row level security;
alter table public.polls          enable row level security;
alter table public.poll_options   enable row level security;
alter table public.poll_votes     enable row level security;
alter table public.post_likes     enable row level security;
alter table public.comments       enable row level security;
alter table public.comment_likes  enable row level security;
alter table public.saves          enable row level security;
alter table public.stories        enable row level security;
alter table public.story_views    enable row level security;
alter table public.story_likes    enable row level security;

-- ============ 5) funcții ajutătoare (NU sunt expuse clientului) ============
create or replace function public.is_blocked_pair(a uuid, b uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.blocks where (blocker = a and blocked = b) or (blocker = b and blocked = a));
$$;

create or replace function public.are_friends(a uuid, b uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.friendships f
                 where f.user_a = least(a, b) and f.user_b = greatest(a, b) and f.status = 'accepted');
$$;

create or replace function public.can_view_post(p_author uuid, p_audience text) returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null
     and not public.is_blocked_pair(auth.uid(), p_author)
     and (p_author = auth.uid() or p_audience = 'public' or public.are_friends(auth.uid(), p_author));
$$;

create or replace function public.require_user() returns uuid
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'forbidden' using errcode = '42501'; end if;
  return auth.uid();
end $$;

-- o postare -> JSON complet pentru client (autor, media, contoare, starea mea, sondaj)
create or replace function public.post_to_json(p public.posts) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  a record; pl record; poll jsonb := null; sh jsonb := null; opts jsonb;
  voted boolean; show boolean; total int; closed boolean;
begin
  select id, username, handle, avatar into a from public.profiles where id = p.author;
  if p.shared_from is not null then
    select jsonb_build_object('id', q.id, 'body', q.body, 'media', q.media, 'created_at', q.created_at,
                              'author', jsonb_build_object('id', pr.id, 'name', pr.username, 'handle', pr.handle, 'avatar', pr.avatar))
      into sh
      from public.posts q left join public.profiles pr on pr.id = q.author
     where q.id = p.shared_from and public.can_view_post(q.author, q.audience);
  end if;
  select * into pl from public.polls where post_id = p.id;
  if found then
    closed := pl.closes_at is not null and pl.closes_at <= now();
    voted  := exists (select 1 from public.poll_votes v where v.post_id = p.id and v.user_id = me);
    show   := pl.results = 'always' or (pl.results = 'after_vote' and (voted or p.author = me)) or (pl.results = 'after_close' and closed);
    select count(distinct user_id) into total from public.poll_votes where post_id = p.id;
    select jsonb_agg(jsonb_build_object(
             'id', o.id, 'label', o.label,
             'votes', case when show then (select count(*) from public.poll_votes v where v.option_id = o.id) else null end,
             'mine',  exists (select 1 from public.poll_votes v where v.option_id = o.id and v.user_id = me),
             'correct', case when pl.quiz and (voted or closed) then o.correct else null end) order by o.idx)
      into opts from public.poll_options o where o.post_id = p.id;
    poll := jsonb_build_object(
      'question', pl.question, 'multiple', pl.multiple, 'anonymous', pl.anonymous, 'quiz', pl.quiz,
      'allow_add', pl.allow_add, 'allow_change', pl.allow_change, 'results', pl.results,
      'closes_at', pl.closes_at, 'closed', closed, 'voted', voted, 'show', show,
      'total', case when show then total else null end,
      'options', coalesce(opts, '[]'::jsonb),
      'explanation', case when pl.quiz and (voted or closed) then pl.explanation else null end);
  end if;
  return jsonb_build_object(
    'id', p.id,
    'author', jsonb_build_object('id', a.id, 'name', a.username, 'handle', a.handle, 'avatar', a.avatar),
    'body', p.body, 'media', p.media, 'audience', p.audience,
    'created_at', p.created_at, 'edited_at', p.edited_at, 'shared', sh, 'poll', poll,
    'likes',    (select count(*) from public.post_likes where post_id = p.id),
    'comments', (select count(*) from public.comments  where post_id = p.id),
    'liked', exists (select 1 from public.post_likes where post_id = p.id and user_id = me),
    'saved', exists (select 1 from public.saves      where post_id = p.id and user_id = me),
    'mine', p.author = me);
end $$;

-- ============ 6) prietenii ============
create or replace function public.relation_of(t uuid) returns text
language plpgsql stable security definer set search_path = public as $$
declare me uuid := public.require_user(); f record;
begin
  if t = me then return 'self'; end if;
  if exists (select 1 from public.blocks where blocker = me and blocked = t) then return 'blocked_by_me'; end if;
  if exists (select 1 from public.blocks where blocker = t and blocked = me) then return 'blocked_me'; end if;
  select status, requester into f from public.friendships where user_a = least(me, t) and user_b = greatest(me, t);
  if not found then return 'none'; end if;
  if f.status = 'accepted' then return 'friends'; end if;
  if f.requester = me then return 'pending_out'; end if;
  return 'pending_in';
end $$;

create or replace function public.friend_request(target uuid) returns text
language plpgsql security definer set search_path = public as $$
declare me uuid := public.require_user(); rel text;
begin
  if target is null or target = me then raise exception 'invalid' using errcode = '22023'; end if;
  if not exists (select 1 from public.profiles where id = target) then raise exception 'not found' using errcode = 'P0002'; end if;
  rel := public.relation_of(target);
  if rel in ('blocked_by_me', 'blocked_me') then raise exception 'forbidden' using errcode = '42501'; end if;
  if rel = 'pending_in' then
    update public.friendships set status = 'accepted', accepted_at = now()
     where user_a = least(me, target) and user_b = greatest(me, target);
  elsif rel = 'none' then
    insert into public.friendships (user_a, user_b, requester) values (least(me, target), greatest(me, target), me);
  end if;
  return public.relation_of(target);
end $$;

create or replace function public.friend_respond(target uuid, accept boolean) returns text
language plpgsql security definer set search_path = public as $$
declare me uuid := public.require_user();
begin
  if accept then
    update public.friendships set status = 'accepted', accepted_at = now()
     where user_a = least(me, target) and user_b = greatest(me, target) and status = 'pending' and requester = target;
  else
    delete from public.friendships
     where user_a = least(me, target) and user_b = greatest(me, target) and status = 'pending' and requester = target;
  end if;
  return public.relation_of(target);
end $$;

-- anulează cererea trimisă / șterge prietenul
create or replace function public.friend_remove(target uuid) returns text
language plpgsql security definer set search_path = public as $$
declare me uuid := public.require_user();
begin
  delete from public.friendships where user_a = least(me, target) and user_b = greatest(me, target);
  return public.relation_of(target);
end $$;

create or replace function public.friend_requests() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me uuid := public.require_user(); out jsonb;
begin
  select coalesce(jsonb_agg(jsonb_build_object('id', pr.id, 'name', pr.username, 'handle', pr.handle, 'avatar', pr.avatar, 'at', f.created_at)
                            order by f.created_at desc), '[]'::jsonb)
    into out
    from public.friendships f join public.profiles pr on pr.id = f.requester
   where f.status = 'pending' and f.requester <> me and (f.user_a = me or f.user_b = me)
     and not public.is_blocked_pair(me, f.requester);
  return out;
end $$;

create or replace function public.friends_of(p_user uuid, p_limit int default 100) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me uuid := public.require_user(); out jsonb;
begin
  if public.is_blocked_pair(me, p_user) then return '[]'::jsonb; end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', pr.id, 'name', pr.username, 'handle', pr.handle, 'avatar', pr.avatar)), '[]'::jsonb)
    into out
    from (select case when f.user_a = p_user then f.user_b else f.user_a end as fid
            from public.friendships f
           where f.status = 'accepted' and (f.user_a = p_user or f.user_b = p_user)
           limit least(greatest(coalesce(p_limit, 100), 1), 200)) x
    join public.profiles pr on pr.id = x.fid
   where not public.is_blocked_pair(me, pr.id);
  return out;
end $$;

-- ============ 7) block / raportare ============
create or replace function public.block_user(target uuid) returns text
language plpgsql security definer set search_path = public as $$
declare me uuid := public.require_user();
begin
  if target is null or target = me then raise exception 'invalid' using errcode = '22023'; end if;
  insert into public.blocks (blocker, blocked) values (me, target) on conflict do nothing;
  delete from public.friendships where user_a = least(me, target) and user_b = greatest(me, target);
  return public.relation_of(target);
end $$;

create or replace function public.unblock_user(target uuid) returns text
language plpgsql security definer set search_path = public as $$
declare me uuid := public.require_user();
begin
  delete from public.blocks where blocker = me and blocked = target;
  return public.relation_of(target);
end $$;

create or replace function public.my_blocks() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me uuid := public.require_user(); out jsonb;
begin
  select coalesce(jsonb_agg(jsonb_build_object('id', pr.id, 'name', pr.username, 'handle', pr.handle, 'avatar', pr.avatar) order by b.created_at desc), '[]'::jsonb)
    into out from public.blocks b join public.profiles pr on pr.id = b.blocked where b.blocker = me;
  return out;
end $$;

create or replace function public.report_submit(p_type text, p_id text, p_reason text, p_details text default null) returns boolean
language plpgsql security definer set search_path = public as $$
declare me uuid := public.require_user(); tu uuid := null;
begin
  if p_type not in ('user','post','comment','story','message') then raise exception 'invalid type' using errcode = '22023'; end if;
  if p_reason not in ('spam','harassment','hate','nudity','violence','scam','impersonation','self_harm','other') then raise exception 'invalid reason' using errcode = '22023'; end if;
  if p_id is null or char_length(p_id) = 0 or char_length(p_id) > 64 then raise exception 'invalid target' using errcode = '22023'; end if;
  if (select count(*) from public.reports where reporter = me and created_at > now() - interval '1 day') >= 30 then
    raise exception 'too many reports' using errcode = '54000';
  end if;
  begin
    if p_type = 'user' then tu := p_id::uuid;
    elsif p_type = 'post' then select author into tu from public.posts where id = p_id::uuid;
    elsif p_type = 'comment' then select author into tu from public.comments where id = p_id::uuid;
    elsif p_type = 'story' then select author into tu from public.stories where id = p_id::uuid;
    end if;
  exception when invalid_text_representation then
    raise exception 'invalid target' using errcode = '22023';
  end;
  insert into public.reports (reporter, target_type, target_id, target_user, reason, details)
  values (me, p_type, p_id, tu, p_reason, left(p_details, 500));
  return true;
end $$;

-- ============ 8) profil ============
create or replace function public.profile_view(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me uuid := public.require_user(); pr record; rel text; st jsonb;
begin
  select id, username, handle, bio, avatar, cover, created_at into pr from public.profiles where id = p_user;
  if not found then return null; end if;
  rel := public.relation_of(p_user);
  if rel = 'blocked_me' then return jsonb_build_object('id', p_user, 'relation', rel); end if;
  select jsonb_build_object('count', count(*),
           'seen', coalesce(bool_and(exists (select 1 from public.story_views v where v.story_id = s.id and v.viewer = me)), true))
    into st from public.stories s
   where s.author = p_user and s.expires_at > now() and (p_user = me or public.are_friends(me, p_user));
  return jsonb_build_object(
    'id', pr.id, 'name', pr.username, 'handle', pr.handle, 'bio', pr.bio, 'avatar', pr.avatar, 'cover', pr.cover,
    'joined', pr.created_at, 'relation', rel,
    'posts', (select count(*) from public.posts p where p.author = p_user and public.can_view_post(p.author, p.audience)),
    'friends', (select count(*) from public.friendships f where f.status = 'accepted' and (f.user_a = p_user or f.user_b = p_user)),
    'mutual', case when p_user = me then 0 else (
        select count(*) from public.friendships f1 join public.friendships f2
          on (case when f1.user_a = me then f1.user_b else f1.user_a end) = (case when f2.user_a = p_user then f2.user_b else f2.user_a end)
         where f1.status = 'accepted' and f2.status = 'accepted'
           and (f1.user_a = me or f1.user_b = me) and (f2.user_a = p_user or f2.user_b = p_user)) end,
    'story', st);
end $$;

create or replace function public.profile_posts(p_user uuid, p_before timestamptz default null, p_limit int default 15) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me uuid := public.require_user(); out jsonb;
begin
  p_limit := least(greatest(coalesce(p_limit, 15), 1), 30);
  select coalesce(jsonb_agg(public.post_to_json(x.r) order by x.ca desc, x.pid desc), '[]'::jsonb) into out from (
    select p as r, p.created_at as ca, p.id as pid from public.posts p
     where p.author = p_user and (p_before is null or p.created_at < p_before) and public.can_view_post(p.author, p.audience)
     order by p.created_at desc, p.id desc limit p_limit) x;
  return out;
end $$;

-- ============ 9) feed ============
create or replace function public.feed_page(p_scope text default 'all', p_before timestamptz default null, p_limit int default 15) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me uuid := public.require_user(); out jsonb;
begin
  p_limit := least(greatest(coalesce(p_limit, 15), 1), 30);
  select coalesce(jsonb_agg(public.post_to_json(x.r) order by x.ca desc, x.pid desc), '[]'::jsonb) into out from (
    select p as r, p.created_at as ca, p.id as pid from public.posts p
     where (p_before is null or p.created_at < p_before)
       and not public.is_blocked_pair(me, p.author)
       and ( p.author = me
             or public.are_friends(me, p.author)
             or (coalesce(p_scope, 'all') = 'all' and p.audience = 'public') )
     order by p.created_at desc, p.id desc limit p_limit) x;
  return out;
end $$;

create or replace function public.saved_posts(p_before timestamptz default null, p_limit int default 20) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me uuid := public.require_user(); out jsonb;
begin
  p_limit := least(greatest(coalesce(p_limit, 20), 1), 40);
  select coalesce(jsonb_agg((public.post_to_json(x.r) || jsonb_build_object('saved_at', x.sa)) order by x.sa desc), '[]'::jsonb) into out from (
    select p as r, s.created_at as sa from public.saves s join public.posts p on p.id = s.post_id
     where s.user_id = me and (p_before is null or s.created_at < p_before) and public.can_view_post(p.author, p.audience)
     order by s.created_at desc limit p_limit) x;
  return out;
end $$;

-- ============ 10) postări: creare / ștergere / like / save / comentarii ============
create or replace function public.post_add(p_body text, p_media jsonb default '[]'::jsonb, p_audience text default 'public',
                                           p_shared_from uuid default null, p_poll jsonb default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := public.require_user(); pid uuid; m jsonb; o jsonb; i int := 0; ncorrect int := 0; nopt int;
  q_multiple boolean; q_quiz boolean; mins int; src public.posts;
begin
  p_body := coalesce(p_body, ''); p_media := coalesce(p_media, '[]'::jsonb);
  if p_audience not in ('public', 'friends') then raise exception 'invalid audience' using errcode = '22023'; end if;
  if jsonb_typeof(p_media) <> 'array' or jsonb_array_length(p_media) > 10 then raise exception 'invalid media' using errcode = '22023'; end if;
  for m in select * from jsonb_array_elements(p_media) loop
    if coalesce(m->>'type', '') not in ('image', 'video') or position('/media/' || me::text || '/' in coalesce(m->>'url', '')) = 0 then
      raise exception 'invalid media item' using errcode = '22023';
    end if;
  end loop;
  if p_shared_from is not null then
    select * into src from public.posts where id = p_shared_from;
    if not found or not public.can_view_post(src.author, src.audience) then raise exception 'not found' using errcode = 'P0002'; end if;
    if src.shared_from is not null then p_shared_from := src.shared_from; end if;
  end if;
  if char_length(btrim(p_body)) = 0 and jsonb_array_length(p_media) = 0 and p_poll is null and p_shared_from is null then
    raise exception 'empty post' using errcode = '22023';
  end if;
  if (select count(*) from public.posts where author = me and created_at > now() - interval '1 hour') >= 30 then
    raise exception 'too many posts' using errcode = '54000';
  end if;

  insert into public.posts (author, body, media, audience, shared_from)
  values (me, p_body, p_media, p_audience, p_shared_from) returning id into pid;

  if p_poll is not null then
    nopt := coalesce(jsonb_array_length(p_poll->'options'), 0);
    if nopt < 2 or nopt > 10 then raise exception 'poll needs 2-10 options' using errcode = '22023'; end if;
    q_multiple := coalesce((p_poll->>'multiple')::boolean, false);
    q_quiz := coalesce((p_poll->>'quiz')::boolean, false);
    mins := nullif(p_poll->>'closes_in_minutes', '')::int;
    if mins is not null and (mins < 1 or mins > 60 * 24 * 30) then raise exception 'invalid deadline' using errcode = '22023'; end if;
    insert into public.polls (post_id, question, multiple, anonymous, quiz, explanation, allow_add, allow_change, results, closes_at)
    values (pid, left(btrim(coalesce(p_poll->>'question', '')), 200), q_multiple,
            coalesce((p_poll->>'anonymous')::boolean, false), q_quiz, left(p_poll->>'explanation', 300),
            coalesce((p_poll->>'allow_add')::boolean, false),
            case when q_quiz then false else coalesce((p_poll->>'allow_change')::boolean, true) end,
            coalesce(nullif(p_poll->>'results', ''), 'always'),
            case when mins is null then null else now() + make_interval(mins => mins) end);
    for o in select * from jsonb_array_elements(p_poll->'options') loop
      insert into public.poll_options (post_id, idx, label, correct, added_by)
      values (pid, i, left(btrim(coalesce(o->>'label', '')), 100), coalesce((o->>'correct')::boolean, false), me);
      if coalesce((o->>'correct')::boolean, false) then ncorrect := ncorrect + 1; end if;
      i := i + 1;
    end loop;
    if q_quiz and (ncorrect < 1 or (not q_multiple and ncorrect <> 1)) then raise exception 'quiz needs correct answer' using errcode = '22023'; end if;
  end if;
  select * into src from public.posts where id = pid;
  return public.post_to_json(src);
end $$;

create or replace function public.post_delete(p_id uuid) returns boolean
language plpgsql security definer set search_path = public as $$
declare me uuid := public.require_user();
begin
  delete from public.posts where id = p_id and author = me;
  return found;
end $$;

create or replace function public.post_edit(p_id uuid, p_body text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := public.require_user(); r public.posts;
begin
  if char_length(coalesce(p_body, '')) > 3000 then raise exception 'too long' using errcode = '22023'; end if;
  update public.posts set body = coalesce(p_body, ''), edited_at = now() where id = p_id and author = me returning * into r;
  if not found then raise exception 'forbidden' using errcode = '42501'; end if;
  return public.post_to_json(r);
end $$;

create or replace function public.post_like(p_id uuid, p_on boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := public.require_user(); po public.posts;
begin
  select * into po from public.posts where id = p_id;
  if not found or not public.can_view_post(po.author, po.audience) then raise exception 'not found' using errcode = 'P0002'; end if;
  if p_on then insert into public.post_likes (post_id, user_id) values (p_id, me) on conflict do nothing;
  else delete from public.post_likes where post_id = p_id and user_id = me; end if;
  return jsonb_build_object('liked', p_on, 'likes', (select count(*) from public.post_likes where post_id = p_id));
end $$;

create or replace function public.post_save(p_id uuid, p_on boolean) returns boolean
language plpgsql security definer set search_path = public as $$
declare me uuid := public.require_user(); po public.posts;
begin
  select * into po from public.posts where id = p_id;
  if not found or not public.can_view_post(po.author, po.audience) then raise exception 'not found' using errcode = 'P0002'; end if;
  if p_on then insert into public.saves (user_id, post_id) values (me, p_id) on conflict do nothing;
  else delete from public.saves where user_id = me and post_id = p_id; end if;
  return p_on;
end $$;

create or replace function public.post_likers(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me uuid := public.require_user(); po public.posts; out jsonb;
begin
  select * into po from public.posts where id = p_id;
  if not found or not public.can_view_post(po.author, po.audience) then return '[]'::jsonb; end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', pr.id, 'name', pr.username, 'handle', pr.handle, 'avatar', pr.avatar)), '[]'::jsonb)
    into out from (select user_id from public.post_likes where post_id = p_id order by created_at desc limit 100) l
    join public.profiles pr on pr.id = l.user_id where not public.is_blocked_pair(me, pr.id);
  return out;
end $$;

create or replace function public.comments_list(p_post uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me uuid := public.require_user(); po public.posts; out jsonb;
begin
  select * into po from public.posts where id = p_post;
  if not found or not public.can_view_post(po.author, po.audience) then return '[]'::jsonb; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', c.id, 'parent', c.parent_id, 'body', c.body, 'created_at', c.created_at,
      'author', jsonb_build_object('id', pr.id, 'name', pr.username, 'handle', pr.handle, 'avatar', pr.avatar),
      'likes', (select count(*) from public.comment_likes cl where cl.comment_id = c.id),
      'liked', exists (select 1 from public.comment_likes cl where cl.comment_id = c.id and cl.user_id = me),
      'mine', c.author = me, 'can_delete', (c.author = me or po.author = me)) order by c.created_at), '[]'::jsonb)
    into out
    from public.comments c join public.profiles pr on pr.id = c.author
   where c.post_id = p_post and not public.is_blocked_pair(me, c.author);
  return out;
end $$;

create or replace function public.comment_add(p_post uuid, p_body text, p_parent uuid default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := public.require_user(); po public.posts; cid uuid; par public.comments; pr record;
begin
  select * into po from public.posts where id = p_post;
  if not found or not public.can_view_post(po.author, po.audience) then raise exception 'not found' using errcode = 'P0002'; end if;
  p_body := btrim(coalesce(p_body, ''));
  if char_length(p_body) < 1 or char_length(p_body) > 1000 then raise exception 'invalid comment' using errcode = '22023'; end if;
  if p_parent is not null then
    select * into par from public.comments where id = p_parent and post_id = p_post;
    if not found then raise exception 'invalid parent' using errcode = '22023'; end if;
    if par.parent_id is not null then p_parent := par.parent_id; end if;   -- un singur nivel de răspunsuri
  end if;
  if (select count(*) from public.comments where author = me and created_at > now() - interval '1 minute') >= 20 then
    raise exception 'too many comments' using errcode = '54000';
  end if;
  insert into public.comments (post_id, author, parent_id, body) values (p_post, me, p_parent, p_body) returning id into cid;
  select id, username, handle, avatar into pr from public.profiles where id = me;
  return jsonb_build_object('id', cid, 'parent', p_parent, 'body', p_body, 'created_at', now(),
    'author', jsonb_build_object('id', pr.id, 'name', pr.username, 'handle', pr.handle, 'avatar', pr.avatar),
    'likes', 0, 'liked', false, 'mine', true, 'can_delete', true);
end $$;

create or replace function public.comment_delete(p_id uuid) returns boolean
language plpgsql security definer set search_path = public as $$
declare me uuid := public.require_user();
begin
  delete from public.comments c
   where c.id = p_id and (c.author = me or exists (select 1 from public.posts p where p.id = c.post_id and p.author = me));
  return found;
end $$;

create or replace function public.comment_like(p_id uuid, p_on boolean) returns boolean
language plpgsql security definer set search_path = public as $$
declare me uuid := public.require_user(); c public.comments; po public.posts;
begin
  select * into c from public.comments where id = p_id;
  if not found then raise exception 'not found' using errcode = 'P0002'; end if;
  select * into po from public.posts where id = c.post_id;
  if not public.can_view_post(po.author, po.audience) then raise exception 'not found' using errcode = 'P0002'; end if;
  if p_on then insert into public.comment_likes (comment_id, user_id) values (p_id, me) on conflict do nothing;
  else delete from public.comment_likes where comment_id = p_id and user_id = me; end if;
  return p_on;
end $$;

-- ============ 11) sondaje ============
create or replace function public.poll_vote(p_post uuid, p_options bigint[]) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := public.require_user(); pl public.polls; po public.posts; n int; had boolean;
begin
  select * into po from public.posts where id = p_post;
  if not found or not public.can_view_post(po.author, po.audience) then raise exception 'not found' using errcode = 'P0002'; end if;
  select * into pl from public.polls where post_id = p_post;
  if not found then raise exception 'not a poll' using errcode = '22023'; end if;
  if pl.closes_at is not null and pl.closes_at <= now() then raise exception 'poll closed' using errcode = '22023'; end if;
  p_options := array(select distinct x from unnest(coalesce(p_options, '{}'::bigint[])) x);
  select count(*) into n from public.poll_options where post_id = p_post and id = any(p_options);
  if n <> coalesce(array_length(p_options, 1), 0) then raise exception 'invalid option' using errcode = '22023'; end if;
  if not pl.multiple and n > 1 then raise exception 'single choice' using errcode = '22023'; end if;
  had := exists (select 1 from public.poll_votes where post_id = p_post and user_id = me);
  if had and not pl.allow_change then raise exception 'vote locked' using errcode = '22023'; end if;
  delete from public.poll_votes where post_id = p_post and user_id = me;
  if n > 0 then
    insert into public.poll_votes (option_id, user_id, post_id)
    select id, me, p_post from public.poll_options where post_id = p_post and id = any(p_options);
  end if;
  return public.post_to_json(po)->'poll';
end $$;

create or replace function public.poll_add_option(p_post uuid, p_label text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := public.require_user(); pl public.polls; po public.posts; nx int;
begin
  select * into po from public.posts where id = p_post;
  if not found or not public.can_view_post(po.author, po.audience) then raise exception 'not found' using errcode = 'P0002'; end if;
  select * into pl from public.polls where post_id = p_post;
  if not found or not pl.allow_add then raise exception 'forbidden' using errcode = '42501'; end if;
  if pl.closes_at is not null and pl.closes_at <= now() then raise exception 'poll closed' using errcode = '22023'; end if;
  p_label := btrim(coalesce(p_label, ''));
  if char_length(p_label) < 1 or char_length(p_label) > 100 then raise exception 'invalid label' using errcode = '22023'; end if;
  select coalesce(max(idx), -1) + 1 into nx from public.poll_options where post_id = p_post;
  if nx >= 10 then raise exception 'too many options' using errcode = '22023'; end if;
  insert into public.poll_options (post_id, idx, label, added_by) values (p_post, nx, p_label, me);
  return public.post_to_json(po)->'poll';
end $$;

create or replace function public.poll_voters(p_post uuid, p_option bigint) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me uuid := public.require_user(); pl public.polls; po public.posts; out jsonb; voted boolean; closed boolean;
begin
  select * into po from public.posts where id = p_post;
  if not found or not public.can_view_post(po.author, po.audience) then return '[]'::jsonb; end if;
  select * into pl from public.polls where post_id = p_post;
  if not found or pl.anonymous then return '[]'::jsonb; end if;
  closed := pl.closes_at is not null and pl.closes_at <= now();
  voted := exists (select 1 from public.poll_votes where post_id = p_post and user_id = me);
  if not (pl.results = 'always' or (pl.results = 'after_vote' and (voted or po.author = me)) or (pl.results = 'after_close' and closed)) then
    return '[]'::jsonb;
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', pr.id, 'name', pr.username, 'handle', pr.handle, 'avatar', pr.avatar)), '[]'::jsonb)
    into out from (select user_id from public.poll_votes where option_id = p_option and post_id = p_post order by created_at limit 100) v
    join public.profiles pr on pr.id = v.user_id where not public.is_blocked_pair(me, pr.id);
  return out;
end $$;

-- ============ 12) stories ============
create or replace function public.story_add(p_kind text, p_media text, p_body text, p_bg text, p_meta jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := public.require_user(); sid uuid;
begin
  if p_kind not in ('image', 'video', 'text') then raise exception 'invalid kind' using errcode = '22023'; end if;
  if p_kind in ('image', 'video') and position('/media/' || me::text || '/' in coalesce(p_media, '')) = 0 then
    raise exception 'invalid media' using errcode = '22023';
  end if;
  if p_kind = 'text' and char_length(btrim(coalesce(p_body, ''))) = 0 then raise exception 'empty story' using errcode = '22023'; end if;
  if (select count(*) from public.stories where author = me and created_at > now() - interval '1 day') >= 50 then
    raise exception 'too many stories' using errcode = '54000';
  end if;
  insert into public.stories (author, kind, media_url, body, bg, meta)
  values (me, p_kind, case when p_kind = 'text' then null else p_media end, left(p_body, 300), left(p_bg, 40), coalesce(p_meta, '{}'::jsonb))
  returning id into sid;
  return jsonb_build_object('id', sid);
end $$;

create or replace function public.story_delete(p_id uuid) returns boolean
language plpgsql security definer set search_path = public as $$
declare me uuid := public.require_user();
begin
  delete from public.stories where id = p_id and author = me;
  return found;
end $$;

create or replace function public.story_rail() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me uuid := public.require_user(); out jsonb;
begin
  with s as (
    select st.* from public.stories st
     where st.expires_at > now()
       and (st.author = me or (public.are_friends(me, st.author) and not public.is_blocked_pair(me, st.author)))
  ), g as (
    select s.author, count(*) as cnt, max(s.created_at) as latest,
           bool_and(exists (select 1 from public.story_views v where v.story_id = s.id and v.viewer = me)) as seen
      from s group by s.author
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'user', jsonb_build_object('id', pr.id, 'name', pr.username, 'handle', pr.handle, 'avatar', pr.avatar),
           'own', g.author = me, 'seen', g.seen, 'count', g.cnt, 'latest', g.latest)
           order by (g.author = me) desc, g.seen asc, g.latest desc), '[]'::jsonb)
    into out from g join public.profiles pr on pr.id = g.author;
  return out;
end $$;

create or replace function public.stories_of(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me uuid := public.require_user(); out jsonb;
begin
  if p_user <> me and (public.is_blocked_pair(me, p_user) or not public.are_friends(me, p_user)) then return '[]'::jsonb; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', s.id, 'kind', s.kind, 'media_url', s.media_url, 'body', s.body, 'bg', s.bg, 'meta', s.meta,
      'created_at', s.created_at, 'expires_at', s.expires_at,
      'seen', exists (select 1 from public.story_views v where v.story_id = s.id and v.viewer = me),
      'liked', exists (select 1 from public.story_likes l where l.story_id = s.id and l.user_id = me),
      'views', case when s.author = me then (select count(*) from public.story_views v where v.story_id = s.id) else null end,
      'likes', case when s.author = me then (select count(*) from public.story_likes l where l.story_id = s.id) else null end)
      order by s.created_at), '[]'::jsonb)
    into out from public.stories s where s.author = p_user and s.expires_at > now();
  return out;
end $$;

create or replace function public.story_view(p_id uuid) returns boolean
language plpgsql security definer set search_path = public as $$
declare me uuid := public.require_user(); s public.stories;
begin
  select * into s from public.stories where id = p_id and expires_at > now();
  if not found or s.author = me then return false; end if;
  if public.is_blocked_pair(me, s.author) or not public.are_friends(me, s.author) then return false; end if;
  insert into public.story_views (story_id, viewer) values (p_id, me) on conflict do nothing;
  return true;
end $$;

create or replace function public.story_viewers(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me uuid := public.require_user(); out jsonb;
begin
  if not exists (select 1 from public.stories where id = p_id and author = me) then return '[]'::jsonb; end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', pr.id, 'name', pr.username, 'handle', pr.handle, 'avatar', pr.avatar,
           'at', v.viewed_at, 'liked', exists (select 1 from public.story_likes l where l.story_id = p_id and l.user_id = v.viewer))
           order by v.viewed_at desc), '[]'::jsonb)
    into out from public.story_views v join public.profiles pr on pr.id = v.viewer where v.story_id = p_id;
  return out;
end $$;

create or replace function public.story_like(p_id uuid, p_on boolean) returns boolean
language plpgsql security definer set search_path = public as $$
declare me uuid := public.require_user(); s public.stories;
begin
  select * into s from public.stories where id = p_id and expires_at > now();
  if not found or public.is_blocked_pair(me, s.author) or (s.author <> me and not public.are_friends(me, s.author)) then
    raise exception 'not found' using errcode = 'P0002';
  end if;
  if p_on then insert into public.story_likes (story_id, user_id) values (p_id, me) on conflict do nothing;
  else delete from public.story_likes where story_id = p_id and user_id = me; end if;
  return p_on;
end $$;

-- ============ 13) căutare ============
create or replace function public.search_users(q text, lim int default 20) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me uuid := public.require_user(); pat text; out jsonb;
begin
  q := btrim(coalesce(q, ''));
  if char_length(q) < 2 then return '[]'::jsonb; end if;
  q := left(q, 40);
  pat := '%' || replace(replace(replace(lower(ltrim(q, '@')), '\', '\\'), '%', '\%'), '_', '\_') || '%';
  select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'name', x.username, 'handle', x.handle, 'avatar', x.avatar,
           'relation', public.relation_of(x.id)) order by x.rank, x.username), '[]'::jsonb)
    into out from (
      select pr.id, pr.username, pr.handle, pr.avatar,
             case when lower(pr.handle) = lower(ltrim(q, '@')) then 0 when lower(pr.handle) like pat then 1 else 2 end as rank
        from public.profiles pr
       where pr.id <> me and (lower(pr.handle) like pat or lower(pr.username) like pat)
         and not public.is_blocked_pair(me, pr.id)
       order by rank, pr.username limit least(greatest(coalesce(lim, 20), 1), 40)) x;
  return out;
end $$;

-- ============ 14) stocare media (bucket public, doar în folderul propriu) ============
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('media', 'media', true, 52428800,
        array['image/jpeg','image/png','image/webp','image/gif','video/mp4','video/webm','video/quicktime'])
on conflict (id) do update set public = excluded.public, file_size_limit = excluded.file_size_limit,
                               allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists media_insert_own on storage.objects;
create policy media_insert_own on storage.objects for insert to authenticated
  with check (bucket_id = 'media' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists media_delete_own on storage.objects;
create policy media_delete_own on storage.objects for delete to authenticated
  using (bucket_id = 'media' and (storage.foldername(name))[1] = auth.uid()::text);

-- ============ 15) permisiuni: doar utilizatorii autentificați pot apela funcțiile publice; ajutătoarele rămân interne ============
do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig, p.proname as name
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname = any (array[
         'relation_of','friend_request','friend_respond','friend_remove','friend_requests','friends_of',
         'block_user','unblock_user','my_blocks','report_submit','profile_view','profile_posts','feed_page','saved_posts',
         'post_add','post_delete','post_edit','post_like','post_save','post_likers','comments_list','comment_add','comment_delete','comment_like',
         'poll_vote','poll_add_option','poll_voters','story_add','story_delete','story_rail','stories_of','story_view','story_viewers','story_like','search_users'])
  loop
    execute format('revoke all on function %s from public, anon', r.sig);
    execute format('grant execute on function %s to authenticated', r.sig);
  end loop;
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname = any (array['is_blocked_pair','are_friends','can_view_post','require_user','post_to_json'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', r.sig);
  end loop;
end $$;
