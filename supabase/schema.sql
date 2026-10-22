-- Поток 2.0: выполнить целиком в SQL Editor проекта Supabase.
-- Повторный запуск не удаляет данные. Требуются стандартные auth и storage Supabase.
begin;
create table if not exists public.potok_workspaces (
 user_id uuid primary key references auth.users(id) on delete cascade,
 data jsonb not null default '{"version":1,"transactions":[],"imports":[]}',
 revision bigint not null default 0,
 updated_at timestamptz not null default now()
);
create table if not exists public.potok_files (
 id uuid primary key, user_id uuid not null references auth.users(id) on delete cascade,
 name text not null, path text not null unique, sha256 text not null,
 size bigint not null check(size between 1 and 31457280), mime text not null default '',
 created_at timestamptz not null default now(), unique(user_id,sha256)
);
create table if not exists public.potok_closures (
 id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users(id) on delete cascade,
 month date not null check(extract(day from month)=1), snapshot jsonb not null,
 closed_at timestamptz not null default now(), reopened_at timestamptz, reopen_reason text
);
create unique index if not exists potok_one_active_closure on public.potok_closures(user_id,month) where reopened_at is null;
create index if not exists potok_closures_user on public.potok_closures(user_id,month);
alter table public.potok_workspaces enable row level security;
alter table public.potok_files enable row level security;
alter table public.potok_closures enable row level security;
revoke all on public.potok_workspaces,public.potok_files,public.potok_closures from anon,authenticated;
grant select on public.potok_workspaces,public.potok_files,public.potok_closures to authenticated;
drop policy if exists potok_workspace_read on public.potok_workspaces;
create policy potok_workspace_read on public.potok_workspaces for select to authenticated using(user_id=(select auth.uid()));
drop policy if exists potok_files_read on public.potok_files;
create policy potok_files_read on public.potok_files for select to authenticated using(user_id=(select auth.uid()));
drop policy if exists potok_closures_read on public.potok_closures;
create policy potok_closures_read on public.potok_closures for select to authenticated using(user_id=(select auth.uid()));

create or replace function public.potok_require_user() returns uuid language plpgsql stable set search_path='' as $$
begin if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if; return auth.uid(); end $$;

-- Проекция включает всю историю до закрытого месяца: старые остатки влияют на новые.
-- Ссылка на оригинал исключена, поэтому файл можно прикрепить и после закрытия.
create or replace function public.potok_projection(d jsonb, cutoff date) returns jsonb language sql immutable set search_path='' as $$
 select jsonb_build_object(
 'transactions',coalesce((select jsonb_agg(t order by t->>'id') from jsonb_array_elements(d->'transactions') t where (t->>'date')::date<=cutoff),'[]'::jsonb),
 'imports',coalesce((select jsonb_agg(i-'cloudFileId' order by i->>'id') from jsonb_array_elements(d->'imports') i where (i->>'start')::date<=cutoff),'[]'::jsonb));
$$;

create or replace function public.potok_validate(d jsonb) returns void language plpgsql set search_path='' as $$
declare t jsonb; i jsonb; n numeric;
begin
 if jsonb_typeof(d) is distinct from 'object' or d->>'version' is distinct from '1' or jsonb_typeof(d->'transactions') is distinct from 'array' or jsonb_typeof(d->'imports') is distinct from 'array' then raise exception 'INVALID_DATA'; end if;
 if octet_length(d::text)>16000000 or jsonb_array_length(d->'transactions')>20000 then raise exception 'WORKSPACE_TOO_LARGE'; end if;
 if exists(select 1 from jsonb_array_elements(d->'transactions') tx group by tx->>'id' having count(*)>1) or exists(select 1 from jsonb_array_elements(d->'transactions') tx group by tx->>'key' having count(*)>1) or exists(select 1 from jsonb_array_elements(d->'imports') imp group by imp->>'id' having count(*)>1) then raise exception 'DUPLICATE_ID'; end if;
 for i in select value from jsonb_array_elements(d->'imports') loop
  if coalesce(i->>'id','')='' or coalesce(i->>'account','')='' or coalesce(i->>'start','')!~'^\d{4}-\d{2}-\d{2}$' or coalesce(i->>'end','')!~'^\d{4}-\d{2}-\d{2}$' or (i->>'start')::date>(i->>'end')::date then raise exception 'INVALID_IMPORT'; end if;
  if not(i ? 'opening') or (i->'opening'<>'null'::jsonb and (jsonb_typeof(i->'opening')<>'number' or (i->>'opening')::numeric<>trunc((i->>'opening')::numeric) or abs((i->>'opening')::numeric)>9000000000000000)) then raise exception 'INVALID_BALANCE'; end if;
 end loop;
 for t in select value from jsonb_array_elements(d->'transactions') loop
  if coalesce(t->>'id','')='' or coalesce(t->>'key','')='' or coalesce(t->>'account','')='' or coalesce(t->>'date','')!~'^\d{4}-\d{2}-\d{2}$' or jsonb_typeof(t->'amount') is distinct from 'number' then raise exception 'INVALID_TRANSACTION'; end if;
  n=(t->>'amount')::numeric;
  if n<>trunc(n) or n=0 or abs(n)>1000000000000 then raise exception 'INVALID_AMOUNT'; end if;
  if not exists(select 1 from jsonb_array_elements(d->'imports') imp where imp->>'id'=t->>'importId' and imp->>'account'=t->>'account' and (t->>'date')::date between (imp->>'start')::date and (imp->>'end')::date) then raise exception 'MISSING_IMPORT'; end if;
 end loop;
end $$;

create or replace function public.potok_load() returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=public.potok_require_user(); w public.potok_workspaces;
begin insert into public.potok_workspaces(user_id) values(u) on conflict do nothing;
 select * into w from public.potok_workspaces where user_id=u;
 return jsonb_build_object('data',w.data,'revision',w.revision);
end $$;

create or replace function public.potok_save(next_data jsonb, expected_revision bigint) returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=public.potok_require_user(); w public.potok_workspaces; cutoff date; i jsonb;
begin
 perform public.potok_validate(next_data);
 insert into public.potok_workspaces(user_id) values(u) on conflict do nothing;
 select * into w from public.potok_workspaces where user_id=u for update;
 if w.revision<>expected_revision then raise exception 'REVISION_CONFLICT'; end if;
 select (max(month)+interval '1 month - 1 day')::date into cutoff from public.potok_closures where user_id=u and reopened_at is null;
 if cutoff is not null and public.potok_projection(w.data,cutoff)<>public.potok_projection(next_data,cutoff) then raise exception 'MONTH_LOCKED'; end if;
 for i in select value from jsonb_array_elements(next_data->'imports') loop
  if coalesce(i->>'cloudFileId','')<>'' and not exists(select 1 from public.potok_files f where f.id::text=i->>'cloudFileId' and f.user_id=u) then raise exception 'FILE_NOT_OWNED'; end if;
 end loop;
 update public.potok_workspaces set data=next_data,revision=revision+1,updated_at=now() where user_id=u returning * into w;
 return jsonb_build_object('data',w.data,'revision',w.revision);
end $$;

create or replace function public.potok_summary(d jsonb,m date) returns jsonb language plpgsql set search_path='' as $$
declare e date:=(m+interval '1 month - 1 day')::date; a text; anchor jsonb; accounts jsonb:='[]'; op bigint; inc bigint; exp bigint; cnt bigint; total_in bigint:=0; total_out bigint:=0; total_count bigint:=0; total_open bigint:=0; missing boolean:=false;
begin
 for a in select distinct i->>'account' from jsonb_array_elements(d->'imports') i where (i->>'start')::date<=e order by 1 loop
  anchor:=null; op:=null;
  select i into anchor from jsonb_array_elements(d->'imports') i where i->>'account'=a and i->'opening'<>'null'::jsonb and (i->>'start')::date<=m order by i->>'start',i->>'id' limit 1;
  if anchor is not null then select (anchor->>'opening')::bigint+coalesce(sum((t->>'amount')::bigint),0) into op from jsonb_array_elements(d->'transactions') t where t->>'account'=a and (t->>'date')::date>=(anchor->>'start')::date and (t->>'date')::date<m; end if;
  select coalesce(sum(greatest((t->>'amount')::bigint,0)),0),coalesce(sum(greatest(-(t->>'amount')::bigint,0)),0),count(*) into inc,exp,cnt from jsonb_array_elements(d->'transactions') t where t->>'account'=a and (t->>'date')::date between m and e;
  accounts:=accounts||jsonb_build_array(jsonb_build_object('account',a,'opening',op,'income',inc,'expense',exp,'closing',op+inc-exp,'count',cnt));
  total_in:=total_in+inc; total_out:=total_out+exp; total_count:=total_count+cnt;
  if op is null then missing:=true; else total_open:=total_open+op; end if;
 end loop;
 return jsonb_build_object('month',to_char(m,'YYYY-MM'),'accounts',accounts,'income',total_in,'expense',total_out,'net',total_in-total_out,'count',total_count,'opening',case when missing or accounts='[]'::jsonb then null else total_open end,'closing',case when missing or accounts='[]'::jsonb then null else total_open+total_in-total_out end);
end $$;

create or replace function public.potok_close_month(month_value date,expected_revision bigint,reviewed boolean) returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=public.potok_require_user(); w public.potok_workspaces; s jsonb; c public.potok_closures;
begin
 select * into w from public.potok_workspaces where user_id=u for update;
 if not found or w.revision<>expected_revision then raise exception 'REVISION_CONFLICT'; end if;
 if reviewed is distinct from true then raise exception 'REVIEW_REQUIRED'; end if;
 if month_value<>date_trunc('month',month_value)::date or month_value>=date_trunc('month',now() at time zone 'Asia/Yekaterinburg')::date then raise exception 'ONLY_PAST_MONTH'; end if;
 s:=public.potok_summary(w.data,month_value);
 if s->'opening'='null'::jsonb then raise exception 'OPENING_REQUIRED'; end if;
 if (s->>'count')::bigint=0 then raise exception 'EMPTY_MONTH'; end if;
 if exists(select 1 from jsonb_array_elements(w.data->'imports') i where (i->>'start')::date<month_value+interval '1 month' and (i->>'end')::date>=month_value and (coalesce((i->>'rejected')::int,0)>0 or coalesce((i->>'mismatch')::bigint,0)<>0)) then raise exception 'UNRESOLVED_IMPORT'; end if;
 s:=s||jsonb_build_object('transactions',coalesce((select jsonb_agg(t order by t->>'date',t->>'id') from jsonb_array_elements(w.data->'transactions') t where (t->>'date')::date>=month_value and (t->>'date')::date<month_value+interval '1 month'),'[]'::jsonb),'source_revision',w.revision,'reviewed',true);
 insert into public.potok_closures(user_id,month,snapshot) values(u,month_value,s) returning * into c;
 update public.potok_workspaces set revision=revision+1,updated_at=now() where user_id=u;
 return to_jsonb(c);
end $$;

create or replace function public.potok_reopen_month(closure_id uuid,reason text,expected_revision bigint) returns void language plpgsql security definer set search_path='' as $$
declare u uuid:=public.potok_require_user(); w public.potok_workspaces; c public.potok_closures;
begin
 select * into w from public.potok_workspaces where user_id=u for update;
 if not found or w.revision<>expected_revision then raise exception 'REVISION_CONFLICT'; end if;
 if length(trim(coalesce(reason,'')))<5 then raise exception 'REASON_REQUIRED'; end if;
 select * into c from public.potok_closures where id=closure_id and user_id=u and reopened_at is null;
 if not found then raise exception 'CLOSURE_NOT_FOUND'; end if;
 if exists(select 1 from public.potok_closures where user_id=u and reopened_at is null and month>c.month) then raise exception 'REOPEN_LATEST_FIRST'; end if;
 update public.potok_closures set reopened_at=now(),reopen_reason=left(trim(reason),1000) where id=c.id;
 update public.potok_workspaces set revision=revision+1,updated_at=now() where user_id=u;
end $$;

insert into storage.buckets(id,name,public,file_size_limit) values('potok-statements','potok-statements',false,31457280) on conflict(id) do update set public=false,file_size_limit=31457280;
drop policy if exists potok_storage_read on storage.objects;
create policy potok_storage_read on storage.objects for select to authenticated using(bucket_id='potok-statements' and (storage.foldername(name))[1]=(select auth.uid())::text);
drop policy if exists potok_storage_insert on storage.objects;
create policy potok_storage_insert on storage.objects for insert to authenticated with check(bucket_id='potok-statements' and (storage.foldername(name))[1]=(select auth.uid())::text);
-- Нет UPDATE: сохранённый оригинал нельзя перезаписать.
drop policy if exists potok_storage_cleanup on storage.objects;
create policy potok_storage_cleanup on storage.objects for delete to authenticated using(bucket_id='potok-statements' and (storage.foldername(name))[1]=(select auth.uid())::text and not exists(select 1 from public.potok_files f where f.path=storage.objects.name));
create or replace function public.potok_register_file(file_id uuid,file_name text,file_path text,file_hash text,file_size bigint,file_mime text) returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=public.potok_require_user(); f public.potok_files;
begin
 if split_part(file_path,'/',1)<>u::text or split_part(file_path,'/',2)<>file_id::text or file_hash!~'^[0-9a-f]{64}$' or length(file_name)>500 then raise exception 'INVALID_FILE'; end if;
 if not exists(select 1 from storage.objects where bucket_id='potok-statements' and name=file_path) then raise exception 'FILE_MISSING'; end if;
 insert into public.potok_files(id,user_id,name,path,sha256,size,mime) values(file_id,u,file_name,file_path,file_hash,file_size,file_mime) on conflict(user_id,sha256) do nothing;
 select * into f from public.potok_files where user_id=u and sha256=file_hash;
 return to_jsonb(f);
end $$;

revoke all on function public.potok_require_user(),public.potok_projection(jsonb,date),public.potok_validate(jsonb),public.potok_summary(jsonb,date) from public,anon,authenticated;
revoke all on function public.potok_load(),public.potok_save(jsonb,bigint),public.potok_close_month(date,bigint,boolean),public.potok_reopen_month(uuid,text,bigint),public.potok_register_file(uuid,text,text,text,bigint,text) from public,anon,authenticated;
grant execute on function public.potok_load(),public.potok_save(jsonb,bigint),public.potok_close_month(date,bigint,boolean),public.potok_reopen_month(uuid,text,bigint),public.potok_register_file(uuid,text,text,text,bigint,text) to authenticated;
commit;
