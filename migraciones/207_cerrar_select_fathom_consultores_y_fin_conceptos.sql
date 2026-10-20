-- Migración 207 (20/10/2026): cerrar la lectura de cs_fathom_consultores y fin_conceptos al equipo.
-- Para qué: ambas tenían SELECT abierto a cualquier authenticated (using (true)). Ahora hay alumnos del panel
-- de Agus que son authenticated pero NO están en crm_members; ya no deben leerlas.
-- Nueva condición: fundador o cualquier fila en crm_members con user_id = auth.uid().
-- No cambia: cs_fundador_insert / cs_fundador_update, fin_conceptos_escritura, grants, service_role (bypassa RLS).
-- Lectores verificados: front y edge functions de Producto (equipo), vista fin_v_conceptos_desconocidos y
-- fin_v_pagos_categoria (security invoker, sobre fin_pagos que solo leen miembros), fin_categoria_concepto (invoker).
-- Correr fuera de :00/:15/:30/:45. Se puede correr más de una vez (drop + create con el mismo nombre).

begin;

drop policy if exists cs_select on public.cs_fathom_consultores;
create policy cs_select
  on public.cs_fathom_consultores
  for select
  to authenticated
  using (
    coalesce(public.es_fundador(), false)
    or exists (select 1 from public.crm_members m where m.user_id = (select auth.uid()))
  );

drop policy if exists fin_conceptos_select on public.fin_conceptos;
create policy fin_conceptos_select
  on public.fin_conceptos
  for select
  to authenticated
  using (
    coalesce(public.es_fundador(), false)
    or exists (select 1 from public.crm_members m where m.user_id = (select auth.uid()))
  );

commit;

-- ============================================================
-- CONTROLES (correr de a uno, después de la migración)
-- ============================================================
-- C1. Las dos políticas select con la nueva condición; las demás iguales.
-- select tablename, policyname, cmd, roles::text, qual from pg_policies where schemaname='public' and tablename in ('cs_fathom_consultores','fin_conceptos') order by 1,2;
--
-- C2. Alumno de prueba (NO está en crm_members): esperado 0 y 0.
-- begin; set local role authenticated;
-- select set_config('request.jwt.claims', json_build_object('sub',(select id from auth.users where email='vettastore1@gmail.com'),'role','authenticated')::text, true);
-- select (select count(*) from cs_fathom_consultores) a, (select count(*) from fin_conceptos) b; rollback;
--
-- C3. Fundador: mismos conteos que como postgres (select count(*) de cada tabla sin rol).
-- begin; set local role authenticated;
-- select set_config('request.jwt.claims', json_build_object('sub',(select m.user_id from crm_members m where m.rol='fundador' limit 1),'role','authenticated')::text, true);
-- select (select count(*) from cs_fathom_consultores) a, (select count(*) from fin_conceptos) b; rollback;
--
-- VUELTA ATRÁS (solo si hiciera falta): recrear cs_select y fin_conceptos_select con using (true).
