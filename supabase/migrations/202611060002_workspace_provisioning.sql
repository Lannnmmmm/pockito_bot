-- Pockito / Supabase migration 0002
-- Ensure every workspace has an owner and settings row; close direct membership bypasses.

create or replace function public.handle_workspace_created()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.workspace_members(workspace_id,user_id,role)
  values(new.id,new.created_by,'owner')
  on conflict(workspace_id,user_id) do nothing;

  insert into public.workspace_settings(workspace_id)
  values(new.id)
  on conflict(workspace_id) do nothing;

  return new;
end;
$$;

create trigger on_workspace_created
  after insert on public.workspaces
  for each row execute procedure public.handle_workspace_created();

-- Personal workspace creation now relies on on_workspace_created for owner membership/settings.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_display_name text;
begin
  v_display_name := coalesce(
    nullif(new.raw_user_meta_data ->> 'display_name',''),
    nullif(new.raw_user_meta_data ->> 'full_name',''),
    split_part(coalesce(new.email,'user'),'@',1)
  );

  insert into public.profiles(id,display_name)
  values(new.id,v_display_name)
  on conflict(id) do nothing;

  insert into public.workspaces(name,kind,created_by)
  values(left(v_display_name,70) || ' - Personal','personal',new.id);

  return new;
end;
$$;

-- Membership changes must use trusted invitation/administration RPCs.
drop policy if exists "owner manage membership" on public.workspace_members;
create policy "owner update membership" on public.workspace_members
  for update to authenticated
  using(public.is_workspace_owner(workspace_id))
  with check(public.is_workspace_owner(workspace_id));
create policy "owner remove membership" on public.workspace_members
  for delete to authenticated
  using(public.is_workspace_owner(workspace_id));

revoke insert,delete on public.workspace_members from authenticated;
grant update on public.workspace_members to authenticated;

-- No direct mutation path for invitation status or membership acceptance from browser.
-- A later migration will add create_invitation and accept_invitation RPCs.
