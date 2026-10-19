-- Assumes the existing public.polls table has id (text), data (jsonb), and created_at.
-- The existing is_poll_admin() function decides which authenticated users may edit.

create or replace function public.cast_vote_limited(
  p_poll_id text,
  p_option_ids text[],
  p_voter_name text,
  p_voter_token text
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  poll_data jsonb;
  option_data jsonb;
  updated_options jsonb := '[]'::jsonb;
  tokens jsonb;
  option_count integer;
  selection_limit integer;
  selected_count integer := 0;
  unique_count integer;
  voter_name text := nullif(btrim(p_voter_name), '');
  configured_limit numeric;
  deadline_at timestamptz;
begin
  select data into poll_data
  from public.polls
  where id = p_poll_id
  for update;

  if not found then
    raise exception '找不到投票';
  end if;
  if jsonb_typeof(poll_data->'options') is distinct from 'array' then
    raise exception '投票選項格式錯誤';
  end if;
  deadline_at := (poll_data->>'deadline')::timestamptz;
  if deadline_at is null or deadline_at <= now() then
    raise exception '投票已截止';
  end if;
  if p_voter_token is null or length(btrim(p_voter_token)) < 1
     or length(p_voter_token) > 256 then
    raise exception '投票者識別碼無效';
  end if;

  tokens := coalesce(poll_data->'votedTokens', '[]'::jsonb);
  if jsonb_typeof(tokens) is distinct from 'array' then
    raise exception '投票紀錄格式錯誤';
  end if;
  if tokens ? p_voter_token then
    raise exception '已投過此投票';
  end if;
  if coalesce((poll_data->>'isAnonymous')::boolean, false) = false
     and (voter_name is null or length(voter_name) > 100) then
    raise exception '請輸入 100 字以內的姓名';
  end if;

  option_count := jsonb_array_length(poll_data->'options');
  if coalesce((poll_data->>'isMultiple')::boolean, false) then
    if poll_data ? 'maxSelections' then
      if jsonb_typeof(poll_data->'maxSelections') is distinct from 'number' then
        raise exception '投票上限設定無效';
      end if;
      configured_limit := (poll_data->>'maxSelections')::numeric;
      if configured_limit <> trunc(configured_limit)
         or configured_limit < 1 or configured_limit > option_count then
        raise exception '投票上限設定無效';
      end if;
      selection_limit := configured_limit::integer;
    else
      -- Older polls had no per-ballot limit.
      selection_limit := option_count;
    end if;
  else
    selection_limit := 1;
  end if;

  if p_option_ids is null or cardinality(p_option_ids) < 1
     or cardinality(p_option_ids) > selection_limit then
    raise exception '每次最多可選 % 項', selection_limit;
  end if;
  select count(distinct selected.choice) into unique_count
  from unnest(p_option_ids) as selected(choice);
  if unique_count <> cardinality(p_option_ids) then
    raise exception '不可重複選擇同一選項';
  end if;

  for option_data in select value from jsonb_array_elements(poll_data->'options') loop
    if option_data->>'id' = any(p_option_ids) then
      selected_count := selected_count + 1;
      option_data := option_data || jsonb_build_object(
        'votes', coalesce((option_data->>'votes')::integer, 0) + 1,
        'voters', case
          when coalesce((poll_data->>'isAnonymous')::boolean, false)
            then coalesce(option_data->'voters', '[]'::jsonb)
          else coalesce(option_data->'voters', '[]'::jsonb) || jsonb_build_array(voter_name)
        end
      );
    end if;
    updated_options := updated_options || jsonb_build_array(option_data);
  end loop;
  if selected_count <> cardinality(p_option_ids) then
    raise exception '選項不存在';
  end if;

  update public.polls
  set data = poll_data || jsonb_build_object(
    'options', updated_options,
    'votedTokens', tokens || jsonb_build_array(p_voter_token)
  )
  where id = p_poll_id;
  return true;
end;
$$;

create or replace function public.admin_update_poll(
  p_poll_id text,
  p_changes jsonb
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  poll_data jsonb;
  incoming_option jsonb;
  old_option jsonb;
  updated_options jsonb := '[]'::jsonb;
  seen_ids text[] := array[]::text[];
  option_id text;
  option_text text;
  option_image text;
  new_title text;
  new_desc text;
  new_deadline timestamptz;
  new_multiple boolean;
  new_anonymous boolean;
  new_limit numeric;
  has_votes boolean;
begin
  if not coalesce(public.is_poll_admin(), false) then
    raise exception '沒有管理者權限' using errcode = '42501';
  end if;
  select data into poll_data
  from public.polls
  where id = p_poll_id
  for update;
  if not found then
    raise exception '找不到投票';
  end if;
  if jsonb_typeof(p_changes) is distinct from 'object'
     or jsonb_typeof(p_changes->'options') is distinct from 'array'
     or jsonb_typeof(p_changes->'isMultiple') is distinct from 'boolean'
     or jsonb_typeof(p_changes->'isAnonymous') is distinct from 'boolean'
     or jsonb_typeof(p_changes->'maxSelections') is distinct from 'number' then
    raise exception '編輯資料格式錯誤';
  end if;

  new_title := btrim(p_changes->>'title');
  new_desc := coalesce(btrim(p_changes->>'desc'), '');
  new_deadline := (p_changes->>'deadline')::timestamptz;
  new_multiple := (p_changes->>'isMultiple')::boolean;
  new_anonymous := (p_changes->>'isAnonymous')::boolean;
  new_limit := (p_changes->>'maxSelections')::numeric;
  if new_title is null or length(new_title) not between 1 and 200
     or length(new_desc) > 2000 or new_deadline is null then
    raise exception '標題、說明或截止時間無效';
  end if;
  if jsonb_array_length(p_changes->'options') < 2 then
    raise exception '至少需要兩個選項';
  end if;
  if new_limit <> trunc(new_limit) or new_limit < 1
     or new_limit > jsonb_array_length(p_changes->'options')
     or (not new_multiple and new_limit <> 1) then
    raise exception '每次投票上限無效';
  end if;

  select exists (
    select 1 from jsonb_array_elements(poll_data->'options') as existing(value)
    where coalesce((existing.value->>'votes')::integer, 0) > 0
  ) into has_votes;
  if has_votes and (
    new_multiple is distinct from coalesce((poll_data->>'isMultiple')::boolean, false)
    or new_anonymous is distinct from coalesce((poll_data->>'isAnonymous')::boolean, false)
  ) then
    raise exception '已有票數，不能變更單選／多選或匿名設定';
  end if;

  for incoming_option in select value from jsonb_array_elements(p_changes->'options') loop
    option_id := incoming_option->>'id';
    option_text := btrim(incoming_option->>'text');
    option_image := coalesce(incoming_option->>'image', '');
    if option_id is null or length(option_id) < 1 or length(option_id) > 200
       or option_id = any(seen_ids)
       or option_text is null or length(option_text) not between 1 and 200
       or jsonb_typeof(incoming_option->'image') is distinct from 'string'
       or length(option_image) > 1000000 then
      raise exception '選項資料無效或 ID 重複';
    end if;
    seen_ids := array_append(seen_ids, option_id);
    select value into old_option
    from jsonb_array_elements(poll_data->'options')
    where value->>'id' = option_id
    limit 1;
    updated_options := updated_options || jsonb_build_array(
      coalesce(old_option, '{}'::jsonb) || jsonb_build_object(
        'id', option_id, 'text', option_text, 'image', option_image,
        'votes', coalesce((old_option->>'votes')::integer, 0),
        'voters', coalesce(old_option->'voters', '[]'::jsonb)
      )
    );
  end loop;

  for old_option in select value from jsonb_array_elements(poll_data->'options') loop
    if not (old_option->>'id' = any(seen_ids))
       and (coalesce((old_option->>'votes')::integer, 0) > 0
         or jsonb_array_length(coalesce(old_option->'voters', '[]'::jsonb)) > 0) then
      raise exception '已有票數的選項不可刪除';
    end if;
  end loop;

  update public.polls
  set data = poll_data || jsonb_build_object(
    'title', new_title,
    'desc', new_desc,
    'deadline', new_deadline,
    'isMultiple', new_multiple,
    'isAnonymous', new_anonymous,
    'maxSelections', new_limit::integer,
    'options', updated_options
  )
  where id = p_poll_id;
  return true;
end;
$$;

revoke all on function public.cast_vote_limited(text, text[], text, text) from public, anon, authenticated;
grant execute on function public.cast_vote_limited(text, text[], text, text) to anon, authenticated;
revoke all on function public.admin_update_poll(text, jsonb) from public, anon, authenticated;
grant execute on function public.admin_update_poll(text, jsonb) to authenticated;

-- Voting and editing must go through the checked RPCs, not direct REST updates.
revoke update on table public.polls from public, anon, authenticated;

-- The old vote RPC must not remain callable, or callers could bypass the new limit.
do $$
declare
  old_vote_function regprocedure;
begin
  for old_vote_function in
    select p.oid::regprocedure
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'cast_vote'
  loop
    execute format('revoke all on function %s from public, anon, authenticated', old_vote_function);
  end loop;
end;
$$;

notify pgrst, 'reload schema';
