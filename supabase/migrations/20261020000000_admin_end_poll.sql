-- Close an active poll without rewriting its options or vote totals.
create or replace function public.admin_end_poll(p_poll_id text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  poll_data jsonb;
  deadline_at timestamptz;
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

  deadline_at := (poll_data->>'deadline')::timestamptz;
  if deadline_at is null or deadline_at <= clock_timestamp() then
    return false;
  end if;

  update public.polls
  set data = jsonb_set(poll_data, '{deadline}', to_jsonb(clock_timestamp()))
  where id = p_poll_id;
  return true;
end;
$$;

revoke all on function public.admin_end_poll(text) from public, anon, authenticated;
grant execute on function public.admin_end_poll(text) to authenticated;

notify pgrst, 'reload schema';
