-- =====================================================================
-- HiBlue · update0.0.11 — Chat (conversații directe): mesaje, răspunsuri, reacții, fixări, ștergere, citit/văzut.
-- Rulează O SINGURĂ DATĂ în Supabase → SQL Editor, DUPĂ update0.0.10.sql. Idempotent.
-- Aceleași principii: RLS activ fără politici (acces doar prin funcțiile de mai jos), block-urile se respectă,
-- media doar din folderul propriu al utilizatorului. Mesajele NU sunt criptate end-to-end (se pot citi din baza de date).
-- =====================================================================

create table if not exists public.conversations (
  id              uuid primary key default gen_random_uuid(),
  kind            text not null default 'dm' check (kind in ('dm')),
  dm_key          text unique,
  created_at      timestamptz not null default now(),
  last_message_at timestamptz not null default now()
);

create table if not exists public.conversation_members (
  conv_id      uuid not null references public.conversations(id) on delete cascade,
  user_id      uuid not null references auth.users(id) on delete cascade,
  pinned       boolean not null default false,
  pinned_at    timestamptz,
  muted        boolean not null default false,
  archived     boolean not null default false,
  last_read_at timestamptz not null default now(),
  cleared_at   timestamptz,
  hidden_at    timestamptz,
  joined_at    timestamptz not null default now(),
  primary key (conv_id, user_id)
);
create index if not exists conv_members_user_idx on public.conversation_members (user_id);

create table if not exists public.messages (
  id         uuid primary key default gen_random_uuid(),
  conv_id    uuid not null references public.conversations(id) on delete cascade,
  sender     uuid not null references auth.users(id) on delete cascade,
  body       text not null default '' check (char_length(body) <= 4000),
  kind       text not null default 'text' check (kind in ('text','image','video','post','system')),
  media      jsonb not null default '[]'::jsonb check (jsonb_typeof(media) = 'array' and jsonb_array_length(media) <= 10),
  ref        jsonb,
  reply_to   uuid references public.messages(id) on delete set null,
  created_at timestamptz not null default now(),
  edited_at  timestamptz,
  deleted_at timestamptz
);
create index if not exists messages_conv_idx on public.messages (conv_id, created_at desc);

create table if not exists public.message_hides (
  message_id uuid not null references public.messages(id) on delete cascade,
  user_id    uuid not null references auth.users(id) on delete cascade,
  primary key (message_id, user_id)
);
create table if not exists public.message_reactions (
  message_id uuid not null references public.messages(id) on delete cascade,
  user_id    uuid not null references auth.users(id) on delete cascade,
  emoji      text not null check (char_length(emoji) between 1 and 8),
  created_at timestamptz not null default now(),
  primary key (message_id, user_id)
);
create table if not exists public.message_pins (
  conv_id    uuid not null references public.conversations(id) on delete cascade,
  message_id uuid not null references public.messages(id) on delete cascade,
  pinned_by  uuid not null references auth.users(id) on delete cascade,
  pinned_at  timestamptz not null default now(),
  primary key (conv_id, message_id)
);

alter table public.conversations        enable row level security;
alter table public.conversation_members enable row level security;
alter table public.messages             enable row level security;
alter table public.message_hides        enable row level security;
alter table public.message_reactions    enable row level security;
alter table public.message_pins         enable row level security;

-- ---------- ajutătoare (interne) ----------
create or replace function public.conv_member(p_conv uuid) returns public.conversation_members
language plpgsql stable security definer set search_path = public as $$
declare me uuid := public.require_user(); m public.conversation_members;
begin
  select * into m from public.conversation_members where conv_id = p_conv and user_id = me;
  if not found then raise exception 'forbidden' using errcode = '42501'; end if;
  return m;
end $$;

create or replace function public.conv_other(p_conv uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select user_id from public.conversation_members where conv_id = p_conv and user_id <> auth.uid() limit 1;
$$;

create or replace function public.msg_to_json(m public.messages) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me uuid := auth.uid(); rp jsonb := null; r record;
begin
  if m.reply_to is not null then
    select x.id, x.sender, x.body, x.kind, x.deleted_at into r from public.messages x where x.id = m.reply_to;
    if found then
      rp := jsonb_build_object('id', r.id, 'sender', r.sender, 'kind', r.kind,
              'body', case when r.deleted_at is not null then '' else left(r.body, 120) end, 'deleted', r.deleted_at is not null);
    end if;
  end if;
  return jsonb_build_object(
    'id', m.id, 'conv', m.conv_id, 'sender', m.sender, 'mine', m.sender = me,
    'kind', m.kind, 'body', case when m.deleted_at is null then m.body else '' end,
    'media', case when m.deleted_at is null then m.media else '[]'::jsonb end,
    'ref', case when m.deleted_at is null then m.ref else null end,
    'reply', rp, 'created_at', m.created_at, 'edited_at', m.edited_at, 'deleted', m.deleted_at is not null,
    'reactions', coalesce((select jsonb_agg(jsonb_build_object('emoji', g.emoji, 'n', g.n, 'mine', g.mine) order by g.n desc)
                             from (select emoji, count(*) as n, bool_or(user_id = me) as mine
                                     from public.message_reactions where message_id = m.id group by emoji) g), '[]'::jsonb),
    'pinned', exists (select 1 from public.message_pins p where p.message_id = m.id));
end $$;

-- ---------- conversații ----------
create or replace function public.dm_open(target uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := public.require_user(); k text; cid uuid; pr record;
begin
  if target is null or target = me then raise exception 'invalid' using errcode = '22023'; end if;
  if not exists (select 1 from public.profiles where id = target) then raise exception 'not found' using errcode = 'P0002'; end if;
  if public.is_blocked_pair(me, target) then raise exception 'forbidden' using errcode = '42501'; end if;
  k := least(me, target)::text || ':' || greatest(me, target)::text;
  select id into cid from public.conversations where dm_key = k;
  if cid is null then
    insert into public.conversations (dm_key) values (k) on conflict (dm_key) do nothing;
    select id into cid from public.conversations where dm_key = k;
    insert into public.conversation_members (conv_id, user_id) values (cid, me), (cid, target) on conflict do nothing;
  end if;
  update public.conversation_members set hidden_at = null where conv_id = cid and user_id = me;
  select id, username, handle, avatar into pr from public.profiles where id = target;
  return jsonb_build_object('id', cid, 'other', jsonb_build_object('id', pr.id, 'name', pr.username, 'handle', pr.handle, 'avatar', pr.avatar));
end $$;

create or replace function public.chat_list() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me uuid := public.require_user(); out jsonb;
begin
  select coalesce(jsonb_agg(row_j order by pin desc, pin_at desc nulls last, last_at desc), '[]'::jsonb) into out from (
    select
      jsonb_build_object(
        'id', c.id,
        'other', jsonb_build_object('id', pr.id, 'name', pr.username, 'handle', pr.handle, 'avatar', pr.avatar),
        'pinned', mm.pinned, 'muted', mm.muted, 'archived', mm.archived,
        'last', (select jsonb_build_object('id', x.id, 'body', case when x.deleted_at is null then left(x.body, 80) else '' end, 'kind', x.kind,
                          'mine', x.sender = me, 'deleted', x.deleted_at is not null, 'at', x.created_at)
                   from public.messages x
                  where x.conv_id = c.id and x.created_at > coalesce(mm.cleared_at, '-infinity')
                    and not exists (select 1 from public.message_hides h where h.message_id = x.id and h.user_id = me)
                  order by x.created_at desc limit 1),
        'unread', (select count(*) from public.messages x
                    where x.conv_id = c.id and x.sender <> me and x.deleted_at is null and x.created_at > mm.last_read_at
                      and x.created_at > coalesce(mm.cleared_at, '-infinity')
                      and not exists (select 1 from public.message_hides h where h.message_id = x.id and h.user_id = me)),
        'last_at', c.last_message_at) as row_j,
      mm.pinned as pin, mm.pinned_at as pin_at, c.last_message_at as last_at
    from public.conversation_members mm
    join public.conversations c on c.id = mm.conv_id
    join public.conversation_members om on om.conv_id = c.id and om.user_id <> me
    join public.profiles pr on pr.id = om.user_id
    where mm.user_id = me
      and (mm.hidden_at is null or c.last_message_at > mm.hidden_at)
      and not public.is_blocked_pair(me, om.user_id)
      and exists (select 1 from public.messages x where x.conv_id = c.id and x.created_at > coalesce(mm.cleared_at, '-infinity')
                  and not exists (select 1 from public.message_hides h where h.message_id = x.id and h.user_id = me))
  ) t;
  return out;
end $$;

create or replace function public.chat_unread_total() returns int
language plpgsql stable security definer set search_path = public as $$
declare me uuid := public.require_user(); n int;
begin
  select count(*) into n from public.messages x
    join public.conversation_members mm on mm.conv_id = x.conv_id and mm.user_id = me
   where x.sender <> me and x.deleted_at is null and x.created_at > mm.last_read_at and not mm.muted
     and x.created_at > coalesce(mm.cleared_at, '-infinity')
     and not public.is_blocked_pair(me, x.sender)
     and not exists (select 1 from public.message_hides h where h.message_id = x.id and h.user_id = me);
  return coalesce(n, 0);
end $$;

create or replace function public.chat_messages(p_conv uuid, p_before timestamptz default null, p_limit int default 40) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me uuid := public.require_user(); mm public.conversation_members; oth uuid; om public.conversation_members; arr jsonb; pins jsonb;
begin
  mm := public.conv_member(p_conv);
  p_limit := least(greatest(coalesce(p_limit, 40), 1), 80);
  oth := public.conv_other(p_conv);
  select * into om from public.conversation_members where conv_id = p_conv and user_id = oth;
  select coalesce(jsonb_agg(public.msg_to_json(x.r) order by x.ca desc), '[]'::jsonb) into arr from (
    select m as r, m.created_at as ca from public.messages m
     where m.conv_id = p_conv and (p_before is null or m.created_at < p_before)
       and m.created_at > coalesce(mm.cleared_at, '-infinity')
       and not exists (select 1 from public.message_hides h where h.message_id = m.id and h.user_id = me)
     order by m.created_at desc limit p_limit) x;
  select coalesce(jsonb_agg(public.msg_to_json(m) order by p.pinned_at desc), '[]'::jsonb) into pins
    from public.message_pins p join public.messages m on m.id = p.message_id
   where p.conv_id = p_conv and m.deleted_at is null;
  return jsonb_build_object('messages', arr, 'pins', pins,
           'other_read_at', om.last_read_at, 'pinned', mm.pinned, 'muted', mm.muted, 'archived', mm.archived,
           'blocked', public.is_blocked_pair(me, oth));
end $$;

create or replace function public.chat_send(p_conv uuid, p_body text default '', p_kind text default 'text',
                                            p_media jsonb default '[]'::jsonb, p_reply uuid default null, p_post uuid default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := public.require_user(); mm public.conversation_members; oth uuid; mid uuid; mg public.messages;
        m jsonb; ref jsonb := null; po public.posts; pr record; thumb text;
begin
  mm := public.conv_member(p_conv);
  oth := public.conv_other(p_conv);
  if public.is_blocked_pair(me, oth) then raise exception 'forbidden' using errcode = '42501'; end if;
  p_body := coalesce(p_body, ''); p_media := coalesce(p_media, '[]'::jsonb);
  if p_kind not in ('text', 'image', 'video', 'post') then raise exception 'invalid kind' using errcode = '22023'; end if;
  if char_length(p_body) > 4000 then raise exception 'too long' using errcode = '22023'; end if;
  if p_kind = 'text' and char_length(btrim(p_body)) = 0 then raise exception 'empty message' using errcode = '22023'; end if;
  if p_kind in ('image', 'video') then
    if jsonb_typeof(p_media) <> 'array' or jsonb_array_length(p_media) not between 1 and 10 then raise exception 'invalid media' using errcode = '22023'; end if;
    for m in select * from jsonb_array_elements(p_media) loop
      if coalesce(m->>'type', '') not in ('image', 'video') or position('/media/' || me::text || '/' in coalesce(m->>'url', '')) = 0 then
        raise exception 'invalid media item' using errcode = '22023';
      end if;
    end loop;
  else p_media := '[]'::jsonb; end if;
  if p_kind = 'post' then
    select * into po from public.posts where id = p_post;
    if not found or not public.can_view_post(po.author, po.audience) then raise exception 'not found' using errcode = 'P0002'; end if;
    select username, handle into pr from public.profiles where id = po.author;
    thumb := po.media->0->>'url';
    ref := jsonb_build_object('post_id', po.id, 'author_id', po.author, 'author', pr.username, 'handle', pr.handle,
                              'text', left(po.body, 140), 'thumb', thumb, 'poll', exists (select 1 from public.polls where post_id = po.id));
  end if;
  if p_reply is not null and not exists (select 1 from public.messages where id = p_reply and conv_id = p_conv) then
    raise exception 'invalid reply' using errcode = '22023';
  end if;
  if (select count(*) from public.messages where sender = me and created_at > now() - interval '1 minute') >= 40 then
    raise exception 'too many messages' using errcode = '54000';
  end if;
  insert into public.messages (conv_id, sender, body, kind, media, ref, reply_to)
  values (p_conv, me, p_body, p_kind, p_media, ref, p_reply) returning id into mid;
  update public.conversations set last_message_at = now() where id = p_conv;
  update public.conversation_members set last_read_at = now(), hidden_at = null where conv_id = p_conv and user_id = me;
  select * into mg from public.messages where id = mid;
  return public.msg_to_json(mg);
end $$;

create or replace function public.chat_edit(p_msg uuid, p_body text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := public.require_user(); mg public.messages;
begin
  p_body := btrim(coalesce(p_body, ''));
  if char_length(p_body) < 1 or char_length(p_body) > 4000 then raise exception 'invalid message' using errcode = '22023'; end if;
  update public.messages set body = p_body, edited_at = now()
   where id = p_msg and sender = me and kind = 'text' and deleted_at is null and created_at > now() - interval '24 hours'
   returning * into mg;
  if not found then raise exception 'forbidden' using errcode = '42501'; end if;
  return public.msg_to_json(mg);
end $$;

-- p_all = true: șterge pentru toți (doar al tău); false: ascunde doar pentru tine
create or replace function public.chat_delete(p_msg uuid, p_all boolean) returns boolean
language plpgsql security definer set search_path = public as $$
declare me uuid := public.require_user(); mg public.messages;
begin
  select * into mg from public.messages where id = p_msg;
  if not found then return false; end if;
  perform public.conv_member(mg.conv_id);
  if p_all then
    if mg.sender <> me then raise exception 'forbidden' using errcode = '42501'; end if;
    update public.messages set deleted_at = now(), body = '', media = '[]'::jsonb, ref = null where id = p_msg;
    delete from public.message_pins where message_id = p_msg;
  else
    insert into public.message_hides (message_id, user_id) values (p_msg, me) on conflict do nothing;
  end if;
  return true;
end $$;

create or replace function public.chat_react(p_msg uuid, p_emoji text, p_on boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := public.require_user(); mg public.messages;
begin
  select * into mg from public.messages where id = p_msg and deleted_at is null;
  if not found then raise exception 'not found' using errcode = 'P0002'; end if;
  perform public.conv_member(mg.conv_id);
  if public.is_blocked_pair(me, public.conv_other(mg.conv_id)) then raise exception 'forbidden' using errcode = '42501'; end if;
  if p_on then
    insert into public.message_reactions (message_id, user_id, emoji) values (p_msg, me, left(p_emoji, 8))
    on conflict (message_id, user_id) do update set emoji = excluded.emoji, created_at = now();
  else delete from public.message_reactions where message_id = p_msg and user_id = me; end if;
  select * into mg from public.messages where id = p_msg;
  return public.msg_to_json(mg);
end $$;

create or replace function public.chat_pin_msg(p_conv uuid, p_msg uuid, p_on boolean) returns boolean
language plpgsql security definer set search_path = public as $$
declare me uuid := public.require_user();
begin
  perform public.conv_member(p_conv);
  if not exists (select 1 from public.messages where id = p_msg and conv_id = p_conv and deleted_at is null) then raise exception 'not found' using errcode = 'P0002'; end if;
  if p_on then
    if (select count(*) from public.message_pins where conv_id = p_conv) >= 5 then raise exception 'too many pins' using errcode = '54000'; end if;
    insert into public.message_pins (conv_id, message_id, pinned_by) values (p_conv, p_msg, me) on conflict do nothing;
  else delete from public.message_pins where conv_id = p_conv and message_id = p_msg; end if;
  return p_on;
end $$;

create or replace function public.chat_set(p_conv uuid, p_field text, p_on boolean) returns boolean
language plpgsql security definer set search_path = public as $$
declare me uuid := public.require_user();
begin
  perform public.conv_member(p_conv);
  if p_field = 'pinned' then
    if p_on and (select count(*) from public.conversation_members where user_id = me and pinned) >= 5 then raise exception 'too many pins' using errcode = '54000'; end if;
    update public.conversation_members set pinned = p_on, pinned_at = case when p_on then now() else null end where conv_id = p_conv and user_id = me;
  elsif p_field = 'muted' then update public.conversation_members set muted = p_on where conv_id = p_conv and user_id = me;
  elsif p_field = 'archived' then update public.conversation_members set archived = p_on where conv_id = p_conv and user_id = me;
  else raise exception 'invalid field' using errcode = '22023'; end if;
  return p_on;
end $$;

create or replace function public.chat_read(p_conv uuid) returns boolean
language plpgsql security definer set search_path = public as $$
declare me uuid := public.require_user();
begin
  perform public.conv_member(p_conv);
  update public.conversation_members set last_read_at = now() where conv_id = p_conv and user_id = me;
  return true;
end $$;

-- șterge conversația DOAR pentru tine (istoricul dispare; reapare doar la un mesaj nou)
create or replace function public.chat_delete_conv(p_conv uuid) returns boolean
language plpgsql security definer set search_path = public as $$
declare me uuid := public.require_user();
begin
  perform public.conv_member(p_conv);
  update public.conversation_members set cleared_at = now(), hidden_at = now(), pinned = false, pinned_at = null, last_read_at = now()
   where conv_id = p_conv and user_id = me;
  return true;
end $$;

create or replace function public.chat_search(p_conv uuid, p_q text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me uuid := public.require_user(); mm public.conversation_members; pat text; out jsonb;
begin
  mm := public.conv_member(p_conv);
  p_q := btrim(coalesce(p_q, ''));
  if char_length(p_q) < 2 then return '[]'::jsonb; end if;
  pat := '%' || replace(replace(replace(lower(left(p_q, 60)), '\', '\\'), '%', '\%'), '_', '\_') || '%';
  select coalesce(jsonb_agg(public.msg_to_json(x.r) order by x.ca desc), '[]'::jsonb) into out from (
    select m as r, m.created_at as ca from public.messages m
     where m.conv_id = p_conv and m.deleted_at is null and lower(m.body) like pat and m.created_at > coalesce(mm.cleared_at, '-infinity')
       and not exists (select 1 from public.message_hides h where h.message_id = m.id and h.user_id = me)
     order by m.created_at desc limit 40) x;
  return out;
end $$;

do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = any (array['dm_open','chat_list','chat_unread_total','chat_messages','chat_send','chat_edit','chat_delete','chat_react','chat_pin_msg','chat_set','chat_read','chat_delete_conv','chat_search'])
  loop
    execute format('revoke all on function %s from public, anon', r.sig);
    execute format('grant execute on function %s to authenticated', r.sig);
  end loop;
  for r in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = any (array['conv_member','conv_other','msg_to_json'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', r.sig);
  end loop;
end $$;
