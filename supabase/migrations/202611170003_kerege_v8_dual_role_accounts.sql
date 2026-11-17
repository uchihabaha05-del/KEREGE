-- KEREGE 8.0: every account can buy and sell.
-- Existing buyer/supplier accounts become dual-role without changing their UUID or data.

do $$
declare c record;
begin
  for c in
    select conname from pg_constraint
    where conrelid='public.profiles'::regclass and contype='c'
      and pg_get_constraintdef(oid) ilike '%role%'
  loop
    execute format('alter table public.profiles drop constraint %I',c.conname);
  end loop;
end $$;

alter table public.profiles alter column role set default 'both';
update public.profiles set role='both' where role in ('buyer','supplier');

-- Rewrite RLS policy predicates that previously distinguished buyer and supplier roles.
do $$
declare p record; v_using text; v_check text; v_roles text;
begin
 for p in
   select * from pg_policies where schemaname='public'
     and (coalesce(qual,'') ~* 'role[[:space:]]*=[[:space:]]*''(buyer|supplier)'''
       or coalesce(with_check,'') ~* 'role[[:space:]]*=[[:space:]]*''(buyer|supplier)''')
 loop
   v_using:=p.qual;
   v_check:=p.with_check;
   if v_using is not null then
     v_using:=regexp_replace(v_using,'([a-z_][a-z0-9_]*\\.)?role[[:space:]]*=[[:space:]]*''buyer''','\\1role = ''buyer'' or \\1role = ''both''','gi');
     v_using:=regexp_replace(v_using,'([a-z_][a-z0-9_]*\\.)?role[[:space:]]*=[[:space:]]*''supplier''','\\1role = ''supplier'' or \\1role = ''both''','gi');
   end if;
   if v_check is not null then
     v_check:=regexp_replace(v_check,'([a-z_][a-z0-9_]*\\.)?role[[:space:]]*=[[:space:]]*''buyer''','\\1role = ''buyer'' or \\1role = ''both''','gi');
     v_check:=regexp_replace(v_check,'([a-z_][a-z0-9_]*\\.)?role[[:space:]]*=[[:space:]]*''supplier''','\\1role = ''supplier'' or \\1role = ''both''','gi');
   end if;
   select string_agg(case when x='public' then 'public' else quote_ident(x) end,',')
     into v_roles from unnest(p.roles) x;
   execute format('drop policy %I on %I.%I',p.policyname,p.schemaname,p.tablename);
   execute format('create policy %I on %I.%I as %s for %s to %s%s%s',
     p.policyname,p.schemaname,p.tablename,lower(p.permissive),p.cmd,v_roles,
     case when v_using is null then '' else format(' using (%s)',v_using) end,
     case when v_check is null then '' else format(' with check (%s)',v_check) end);
 end loop;
end $$;

-- Rewrite stored PL/pgSQL / SQL function definitions which enforce a single role.
do $$
declare f record; v_definition text;
begin
 for f in
   select p.oid,pg_get_function_identity_arguments(p.oid) as args,
          n.nspname,p.proname
   from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public'
     and p.prokind='f'
     and pg_get_functiondef(p.oid) ~* 'role[[:space:]]*=[[:space:]]*''(buyer|supplier)'''
 loop
   v_definition:=pg_get_functiondef(f.oid);
   v_definition:=regexp_replace(v_definition,'([a-z_][a-z0-9_]*\\.)?role[[:space:]]*=[[:space:]]*''buyer''','\\1role = ''buyer'' or \\1role = ''both''','gi');
   v_definition:=regexp_replace(v_definition,'([a-z_][a-z0-9_]*\\.)?role[[:space:]]*=[[:space:]]*''supplier''','\\1role = ''supplier'' or \\1role = ''both''','gi');
   execute v_definition;
 end loop;
end $$;

comment on column public.profiles.role is 'Account capabilities: both users can buy and sell; legacy buyer/supplier values remain supported.';
