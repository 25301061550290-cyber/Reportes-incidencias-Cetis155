-- ==========================================================================
--  Reportes de incidencias CETis 155 · Esquema de Supabase (PostgreSQL)
--  Pégalo COMPLETO en Supabase > SQL Editor > New query > Run.
--  Idea de seguridad: nadie toca las tablas directamente. El público solo usa
--  funciones (RPC) con reglas; el personal entra con Supabase Auth y RLS.
-- ==========================================================================

create table public.areas(nombre text primary key, grupo text not null, orden int not null, activa boolean not null default true);  -- activa=false oculta un área del formulario sin romper reportes viejos

create table public.reportes(
 id uuid primary key default gen_random_uuid(),
 num bigint not null unique,                        -- consecutivo del folio
 folio text not null unique,                        -- INC-2026-0001 (público)
 codigo text not null,                              -- 8 caracteres aleatorios (privado)
 id_envio uuid unique,                              -- evita duplicados al reintentar
 nombre text not null check (char_length(nombre) between 3 and 80),
 matricula text not null check (char_length(matricula) between 4 and 20),
 area text not null references public.areas(nombre),
 descripcion text not null check (char_length(descripcion) between 10 and 600),
 foto_path text,                                    -- archivo en Storage, ya no base64
 estado text not null default 'pendiente' check (estado in ('pendiente','proceso','resuelta')),
 creado_en timestamptz not null default now(),
 resuelto_en timestamptz,
 eliminado_en timestamptz,                          -- borrado lógico
 fallos int not null default 0,                     -- intentos fallidos de consulta
 bloqueado_hasta timestamptz);
create index on public.reportes(matricula, creado_en);
create sequence public.folio_seq;

create table public.historial(
 id bigint generated always as identity primary key,
 reporte_id uuid not null references public.reportes(id) on delete cascade,
 estado text not null, fecha timestamptz not null default now(), por uuid);

create table public.personal(user_id uuid primary key references auth.users(id) on delete cascade, nombre text);

-- ---------- Funciones auxiliares ----------
create function public.es_personal() returns boolean language sql stable security definer set search_path=public
as $$ select exists(select 1 from public.personal where user_id = auth.uid()) $$;

create function public.puede_subir_foto(n text) returns boolean language sql stable security definer set search_path=public
as $$ select exists(select 1 from public.reportes where foto_path = n and creado_en > now() - interval '15 minutes' and eliminado_en is null) $$;

create function public.gen_codigo() returns text language plpgsql volatile as $$
declare a constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; b bytea := decode(replace(gen_random_uuid()::text,'-',''),'hex'); s text := ''; i int;
begin
 for i in 0..7 loop s := s || substr(a, (get_byte(b, case when i < 6 then i else i+1 end) % 32) + 1, 1); end loop;  -- se saltan los bytes con bits fijos del UUID
 return s;
end $$;

-- ---------- Alumnado: crear reporte ----------
create function public.crear_reporte(p_nombre text, p_matricula text, p_area text, p_descripcion text,
  p_foto boolean default false, p_id_envio uuid default null, p_web text default '')
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_nom text := trim(p_nombre); v_mat text := upper(trim(p_matricula)); v_des text := trim(p_descripcion);
  r public.reportes; v_id uuid := gen_random_uuid(); v_n bigint;
begin
 if coalesce(p_web,'') <> '' then return jsonb_build_object('ok',false,'msg','No se pudo enviar el reporte.'); end if;  -- trampa anti-bots
 if p_id_envio is not null then select * into r from public.reportes where id_envio = p_id_envio; end if;
 if r.id is null then
  if char_length(v_nom) not between 3 and 80 then return jsonb_build_object('ok',false,'msg','Nombre inválido.'); end if;
  if char_length(v_mat) not between 4 and 20 then return jsonb_build_object('ok',false,'msg','Matrícula inválida.'); end if;
  if char_length(v_des) not between 10 and 600 then return jsonb_build_object('ok',false,'msg','Descripción inválida.'); end if;
  if not exists(select 1 from public.areas where nombre = p_area) then return jsonb_build_object('ok',false,'msg','Área inválida.'); end if;
  if (select count(*) from public.reportes where matricula = v_mat and creado_en > now() - interval '1 hour') >= 5
   then return jsonb_build_object('ok',false,'msg','Ya enviaste varios reportes. Intenta más tarde.'); end if;
  if (select count(*) from public.reportes where creado_en > now() - interval '1 hour') >= 200
   then return jsonb_build_object('ok',false,'msg','Hay demasiados reportes en este momento. Intenta más tarde.'); end if;
  v_n := nextval('public.folio_seq');
  insert into public.reportes(id,num,folio,codigo,id_envio,nombre,matricula,area,descripcion,foto_path)
  values (v_id, v_n, 'INC-'||to_char(now(),'YYYY')||'-'||lpad(v_n::text,4,'0'),
          public.gen_codigo(), p_id_envio, v_nom, v_mat, p_area, v_des,
          case when p_foto then v_id::text||'.jpg' end)
  on conflict (id_envio) do nothing returning * into r;
  if r.id is null then select * into r from public.reportes where id_envio = p_id_envio;
  else insert into public.historial(reporte_id,estado) values (r.id,'pendiente'); end if;
 end if;
 return jsonb_build_object('ok',true,'id',r.id,'folio',r.folio,'codigo',r.codigo,'area',r.area,'fecha',r.creado_en,'estado',r.estado);
end $$;

-- ---------- Alumnado: consultar (folio + matrícula + código privado; 5 fallos = 15 min de bloqueo) ----------
-- Devuelve {ok:false} en vez de lanzar error: si lanzara error, PostgreSQL desharía el contador de fallos.
create function public.consultar_reporte(p_folio text, p_matricula text, p_codigo text) returns jsonb language plpgsql security definer set search_path=public as $$
declare v text := upper(trim(p_folio)); n bigint; r public.reportes;
  err constant jsonb := jsonb_build_object('ok',false,'msg','Los datos no coinciden con ningún reporte.');
begin
 if v !~ '^INC-[0-9]{4}-[0-9]{4,}$' then return err; end if;
 n := substring(v from '^INC-[0-9]{4}-([0-9]{4,})$')::bigint;       -- se cuenta por número de folio
 select * into r from public.reportes where num = n and eliminado_en is null for update;
 if r.id is null or r.folio <> v then return err; end if;
 if r.bloqueado_hasta > now() then return jsonb_build_object('ok',false,'msg','Demasiados intentos. Espera unos minutos.'); end if;
 if r.codigo <> upper(trim(p_codigo)) or upper(r.matricula) <> upper(trim(p_matricula)) then
  update public.reportes set fallos = case when fallos+1 >= 5 then 0 else fallos+1 end,
   bloqueado_hasta = case when fallos+1 >= 5 then now() + interval '15 minutes' else bloqueado_hasta end where id = r.id;
  return err;
 end if;
 update public.reportes set fallos = 0 where id = r.id and fallos <> 0;
 return jsonb_build_object('ok',true,'folio',r.folio,'area',r.area,'estado',r.estado,'desc',r.descripcion,
  'foto',r.foto_path is not null,
  'hist',(select coalesce(jsonb_agg(jsonb_build_object('e',h.estado,'f',h.fecha) order by h.fecha),'[]'::jsonb) from public.historial h where h.reporte_id = r.id));
end $$;

-- ---------- Personal: cambiar estado y eliminar (solo si es_personal) ----------
create function public.cambiar_estado(p_id uuid, p_estado text) returns jsonb language plpgsql security definer set search_path=public as $$
declare r public.reportes;
begin
 if not public.es_personal() then raise exception 'No autorizado' using errcode='PT403'; end if;
 if p_estado not in ('pendiente','proceso','resuelta') then raise exception 'Estado inválido' using errcode='PT400'; end if;
 update public.reportes set estado = p_estado,
  resuelto_en = case when p_estado = 'resuelta' then coalesce(resuelto_en, now()) else null end
  where id = p_id and eliminado_en is null returning * into r;
 if r.id is null then raise exception 'Reporte no encontrado' using errcode='PT404'; end if;
 insert into public.historial(reporte_id,estado,por) values (r.id,p_estado,auth.uid());
 return jsonb_build_object('id',r.id,'estado',r.estado,'resuelto_en',r.resuelto_en);
end $$;

create function public.eliminar_reporte(p_id uuid) returns jsonb language plpgsql security definer set search_path=public as $$
declare r public.reportes;
begin
 if not public.es_personal() then raise exception 'No autorizado' using errcode='PT403'; end if;
 select * into r from public.reportes where id = p_id and eliminado_en is null;
 if r.id is null then raise exception 'Reporte no encontrado' using errcode='PT404'; end if;
 if r.estado <> 'resuelta' or r.resuelto_en > now() - interval '10 minutes'
  then raise exception 'Solo se puede eliminar 10 minutos después de resolver el reporte' using errcode='PT403'; end if;
 update public.reportes set eliminado_en = now() where id = p_id;
 return jsonb_build_object('id',p_id);
end $$;

-- ---------- Seguridad a nivel de fila (RLS) y permisos ----------
alter table public.areas enable row level security;
alter table public.reportes enable row level security;
alter table public.historial enable row level security;
alter table public.personal enable row level security;

revoke all on public.areas, public.reportes, public.historial, public.personal from anon, authenticated;
grant select on public.areas to anon, authenticated;
grant select on public.reportes, public.historial to authenticated;

create policy areas_lectura on public.areas for select to anon, authenticated using (true);
create policy reportes_personal on public.reportes for select to authenticated using (public.es_personal() and eliminado_en is null);
create policy historial_personal on public.historial for select to authenticated using (public.es_personal());

revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function public.crear_reporte(text,text,text,text,boolean,uuid,text), public.consultar_reporte(text,text,text), public.puede_subir_foto(text) to anon, authenticated;
grant execute on function public.es_personal(), public.cambiar_estado(uuid,text), public.eliminar_reporte(uuid) to authenticated;

-- ---------- Almacenamiento de fotos (bucket privado, solo JPEG, máx. 600 KB) ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('evidencias','evidencias',false,600000,array['image/jpeg']) on conflict (id) do nothing;
create policy evidencias_subir on storage.objects for insert to anon, authenticated
 with check (bucket_id = 'evidencias' and public.puede_subir_foto(name));
create policy evidencias_ver_personal on storage.objects for select to authenticated
 using (bucket_id = 'evidencias' and public.es_personal());

-- ---------- Áreas del plantel ----------
insert into public.areas(nombre,grupo,orden) values
 ('Aula 1','Aulas',1),
 ('Aula 2','Aulas',2),
 ('Aula 3','Aulas',3),
 ('Aula 4','Aulas',4),
 ('Aula 5','Aulas',5),
 ('Aula 6','Aulas',6),
 ('Aula 7','Aulas',7),
 ('Aula 8','Aulas',8),
 ('Aula 09','Aulas',9),
 ('Aula 10','Aulas',10),
 ('Aula 11','Aulas',11),
 ('Aula 12','Aulas',12),
 ('Aula 13','Aulas',13),
 ('Aula 14','Aulas',14),
 ('Aula 15','Aulas',15),
 ('Aula 16','Aulas',16),
 ('Aula 17','Aulas',17),
 ('Aula 18','Aulas',18),
 ('Laboratorio de Ciencias','Laboratorios y talleres',19),
 ('Anexos de Laboratorio de Ciencias','Laboratorios y talleres',20),
 ('Laboratorio de Cómputo 1','Laboratorios y talleres',21),
 ('Laboratorio de Cómputo 2','Laboratorios y talleres',22),
 ('Laboratorio de Cómputo 3','Laboratorios y talleres',23),
 ('Laboratorio de Cómputo 4','Laboratorios y talleres',24),
 ('Laboratorio de Soporte y Mantenimiento de Equipo de Cómputo','Laboratorios y talleres',25),
 ('Laboratorio de Recursos Humanos','Laboratorios y talleres',26),
 ('Robótica','Laboratorios y talleres',27),
 ('Taller de Mantenimiento Automotriz','Laboratorios y talleres',28),
 ('Biblioteca','Laboratorios y talleres',29),
 ('Módulos de Asesorías','Laboratorios y talleres',30),
 ('Dirección','Oficinas y administración',31),
 ('Recepción de Dirección','Oficinas y administración',32),
 ('Subdirección Académica','Oficinas y administración',33),
 ('Recepción de Subdirección','Oficinas y administración',34),
 ('Planeación','Oficinas y administración',35),
 ('Control Escolar','Oficinas y administración',36),
 ('Servicios Docentes, Editorial y Responsable de Lab.','Oficinas y administración',37),
 ('Servicios Administrativos y Humanos','Oficinas y administración',38),
 ('Recursos Financieros y Protección Civil','Oficinas y administración',39),
 ('Sala de Juntas','Oficinas y administración',40),
 ('Sala de Maestros (junto a Aula 5)','Oficinas y administración',41),
 ('Sala de Maestros (zona este)','Oficinas y administración',42),
 ('Servidor','Oficinas y administración',43),
 ('Becas','Oficinas y administración',44),
 ('Archivo','Oficinas y administración',45),
 ('Almacén','Oficinas y administración',46),
 ('Bodega de Activo Fijo','Oficinas y administración',47),
 ('Oficina de Mantenimiento','Oficinas y administración',48),
 ('Pasillo de oficinas','Oficinas y administración',49),
 ('Apoyo Académico','Atención a estudiantes',50),
 ('Orientación Educativa','Atención a estudiantes',51),
 ('Psicología','Atención a estudiantes',52),
 ('Trabajo Social','Atención a estudiantes',53),
 ('Vinculación','Atención a estudiantes',54),
 ('Centro de Atención para Estudiantes con Discapacidad','Atención a estudiantes',55),
 ('Enfermería','Atención a estudiantes',56),
 ('Prefectura y Vigilancia','Atención a estudiantes',57),
 ('Sala Audiovisual','Espacios comunes',58),
 ('Deportes, Formación Dual y Usos Múltiples','Espacios comunes',59),
 ('Cafetería','Espacios comunes',60),
 ('Entrada Principal','Espacios comunes',61),
 ('Pasillo de Entrada','Espacios comunes',62),
 ('Explanada Principal','Espacios comunes',63),
 ('Explanada Cultural','Espacios comunes',64),
 ('Explanada Química','Espacios comunes',65),
 ('Baño hombres (junto a Aula 14)','Baños',66),
 ('Baño mujeres (junto a Aula 14)','Baños',67),
 ('Baño hombres (junto a Aula 4)','Baños',68),
 ('Baño mujeres (junto a Aula 4)','Baños',69),
 ('Baño hombres (zona Control Escolar)','Baños',70),
 ('Baño mujeres (zona Control Escolar)','Baños',71),
 ('Cancha de Fútbol 7','Canchas y exteriores',72),
 ('Cancha de Fútbol Rápido','Canchas y exteriores',73),
 ('Cancha de Básquetbol','Canchas y exteriores',74),
 ('Estacionamiento del Personal','Canchas y exteriores',75),
 ('Estacionamiento Exterior','Canchas y exteriores',76),
 ('Humedal 1','Canchas y exteriores',77),
 ('Humedal 2','Canchas y exteriores',78),
 ('Sistema de Riego y áreas verdes','Canchas y exteriores',79),
 ('Salidas de emergencia','Infraestructura y seguridad',80),
 ('Extintores (22 en plantel)','Infraestructura y seguridad',81),
 ('Detectores de humo (72 en plantel)','Infraestructura y seguridad',82),
 ('Ductos de energía eléctrica (30 en plantel)','Infraestructura y seguridad',83),
 ('Cisternas de agua potable (5 en plantel)','Infraestructura y seguridad',84),
 ('Drenaje de aguas negras (4 en plantel)','Infraestructura y seguridad',85),
 ('Tambos de basura','Infraestructura y seguridad',86);

-- ---------- Dar de alta a una persona del personal (haz esto DESPUÉS de crearla en Authentication > Users) ----------
-- insert into public.personal(user_id, nombre) values ('PEGA-AQUÍ-EL-UUID-DEL-USUARIO', 'Nombre de la persona');
