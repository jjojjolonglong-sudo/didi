-- didi 컬렉션 정렬: 독서·영상에서 자동으로 들어온 기록의 '완료 시각'을 실제 입력 시각으로 (2026-11-20)
-- 지금은 완료 날짜의 낮 12시로 고정 → 같은 날 다른 기록과 순서가 섞이지 않음.
-- 바꾼 뒤: 날짜는 그대로, 시각만 '독서앱에서 완독 로그를 입력한 시각' / '영상앱에서 작품(연속극은 마지막 화)을 입력한 시각'.
-- 테이블·칸은 바꾸지 않아요. 함수 2개만 고치고, 마지막에 기존 기록을 한 번 다시 맞춰요.

CREATE OR REPLACE FUNCTION public.didi_sync_book(p_book text, p_user uuid)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  b record; e record; r record;
  v_title text; v_rt text; v_max int := 0; v_flag boolean;
  v_cat constant uuid := 'eed2cf8c-8db6-42ba-b67f-cb18d51af4f0';   -- 독서 분류
  v_created timestamptz; v_donets timestamptz;
  n_checked boolean; n_done timestamptz; n_flag boolean;
begin
  select bk.id, bk.page, bk.cover, bk.label, s.name as sname into b
    from bkbk_books bk left join bkbk_series s on s.id = bk.series
   where bk.id::text = p_book;
  if not found then
    update didi_log set discarded_at = now()
     where user_id = p_user and meta->>'bkbk_book' = p_book and discarded_at is null;
    return;
  end if;

  v_title := coalesce(nullif(b.sname, ''), '(제목 없음)')
             || case when coalesce(b.label, '') <> '' then ' [' || b.label || ']' else '' end;

  for r in
    with o as (
      select l."date"::date as d, l.created_at as ca,
             ((l.offpage is not null and b.page is not null and l.offpage >= b.page)
              or (l.offpct is not null and l.offpct >= 1)) as c,
             row_number() over (order by l."date"::date, coalesce(l.onpage, 0), coalesce(l.onpct, 0), l.ctid) as rn
        from bkbk_logs l where l.book::text = p_book
    ), m as (
      select d, c, ca, rn,
             1 + coalesce(sum(case when c then 1 else 0 end)
                   over (order by rn rows between unbounded preceding and 1 preceding), 0) as rno
        from o
    )
    select rno, min(d) as first_d, min(d) filter (where c) as done_d,
           (array_agg(ca order by rn) filter (where c))[1] as done_ca      -- 완독 로그를 입력한 시각
      from m group by rno order by rno
  loop
    v_max := r.rno;
    v_rt := v_title || case when r.rno > 1 then ' (' || r.rno || '회독)' else '' end;
    v_created := (r.first_d + time '12:00') at time zone 'Asia/Seoul';
    v_donets  := (r.done_d + coalesce((r.done_ca at time zone 'Asia/Seoul')::time, time '12:00')) at time zone 'Asia/Seoul';

    select id, is_checked, done_at, created_at, text, image_url, discarded_at, meta into e from didi_log
     where user_id = p_user
       and ((meta->>'bkbk_book' = p_book and coalesce((meta->>'bkbk_round')::int, 1) = r.rno)
            or (r.rno = 1 and meta->>'bkbk_book' is null
                and meta->'ref'->>'t' = 'bkbk_books' and meta->'ref'->>'id' = p_book))
     order by (meta->>'bkbk_book' is not null) desc, seq limit 1;

    if not found then
      insert into didi_log (user_id, text, category_id, log_date, is_checked, created_at, done_at, image_url, meta)
      values (p_user, v_rt, v_cat, null, r.done_d is not null, v_created, v_donets, b.cover,
              jsonb_build_object('bkbk_book', p_book, 'bkbk_round', r.rno, 'bkbk_done', r.done_d is not null,
                'ref', jsonb_build_object('t', 'bkbk_books', 'id', p_book, 'name', v_rt)));
      continue;
    end if;

    if e.discarded_at is not null then continue; end if;

    if e.meta->>'bkbk_book' is null then
      if r.done_d is not null and coalesce(e.is_checked, false) = false then
        update didi_log set is_checked = true, done_at = v_donets where id = e.id;
      end if;
      continue;
    end if;

    v_flag := coalesce((e.meta->>'bkbk_done')::boolean, false);
    n_checked := e.is_checked; n_done := e.done_at; n_flag := v_flag;
    if r.done_d is not null and (coalesce(e.is_checked, false) = false or v_flag) then
      n_checked := true; n_done := v_donets; n_flag := true;
    elsif r.done_d is null and v_flag then
      n_checked := false; n_done := null; n_flag := false;
    end if;

    if e.text is distinct from v_rt or e.image_url is distinct from b.cover
       or e.created_at is distinct from v_created or e.is_checked is distinct from n_checked
       or e.done_at is distinct from n_done or n_flag is distinct from v_flag then
      update didi_log set text = v_rt, image_url = b.cover, created_at = v_created,
             is_checked = n_checked, done_at = n_done,
             meta = e.meta || jsonb_build_object('bkbk_done', n_flag, 'bkbk_round', r.rno,
                      'ref', jsonb_build_object('t', 'bkbk_books', 'id', p_book, 'name', v_rt))
       where id = e.id;
    end if;
  end loop;

  update didi_log set discarded_at = now()
   where user_id = p_user and meta->>'bkbk_book' = p_book and discarded_at is null
     and coalesce((meta->>'bkbk_round')::int, 1) > v_max;
end $function$;

CREATE OR REPLACE FUNCTION public.didi_sync_movie(p_movie text, p_user uuid)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  m record; e record;
  v_cat constant uuid := '89253f70-a97f-4747-b304-061a942866ed';   -- 영상 분류
  v_first date; v_done date; v_doneca timestamptz; v_created timestamptz; v_donets timestamptz;
  v_meta jsonb; v_flag boolean; n_checked boolean; n_done timestamptz; n_flag boolean;
begin
  select mm.id, mm.name, mm.poster, mm."date" as d, mm.sort, mm.created_at as ca into m
    from mvmv_movie mm where mm.id::text = p_movie;
  if not found then
    update didi_log set discarded_at = now(), meta = meta || '{"mvmv_auto_trash": true}'::jsonb
     where user_id = p_user and meta->>'mvmv_movie' = p_movie and discarded_at is null;
    return;
  end if;

  v_doneca := m.ca;
  if m.sort = '연속극' then
    select min(ep.watched) into v_first from mvmv_episode ep
     where ep.movie = m.id and ep.watched is not null;
    select ep.watched, ep.created_at into v_done, v_doneca from mvmv_episode ep   -- 마지막화를 본 날과 그 화를 입력한 시각
     where ep.movie = m.id and ep.watched is not null
     order by ep.episode desc nulls last limit 1;
    v_first := coalesce(v_first, m.d);
    if v_done is null then v_done := m.d; v_doneca := m.ca; end if;
  else
    v_first := m.d; v_done := m.d;
  end if;

  if v_first is null then
    update didi_log set discarded_at = now(), meta = meta || '{"mvmv_auto_trash": true}'::jsonb
     where user_id = p_user and meta->>'mvmv_movie' = p_movie and discarded_at is null;
    return;
  end if;

  v_created := (v_first + time '12:00') at time zone 'Asia/Seoul';
  v_donets  := case when v_done is null then null
               else (v_done + coalesce((v_doneca at time zone 'Asia/Seoul')::time, time '12:00')) at time zone 'Asia/Seoul' end;

  select id, is_checked, done_at, created_at, text, image_url, discarded_at, meta into e from didi_log
   where user_id = p_user
     and ( meta->>'mvmv_movie' = p_movie
        or (meta->>'mvmv_movie' is null and meta->'ref'->>'t' = 'mvmv_movie' and meta->'ref'->>'id' = p_movie) )
   order by (meta->>'mvmv_movie' is not null) desc, seq limit 1;

  if not found then
    insert into didi_log (user_id, text, category_id, log_date, is_checked, created_at, done_at, image_url, meta)
    values (p_user, m.name, v_cat, null, v_done is not null, v_created, v_donets, m.poster,
            jsonb_build_object('mvmv_movie', p_movie, 'mvmv_done', v_done is not null,
              'ref', jsonb_build_object('t', 'mvmv_movie', 'id', p_movie, 'name', m.name)));
    return;
  end if;

  v_meta := e.meta;
  if e.meta->>'mvmv_movie' is null then return; end if;

  if e.discarded_at is not null then
    if coalesce((v_meta->>'mvmv_auto_trash')::boolean, false) then
      v_meta := v_meta - 'mvmv_auto_trash';
      update didi_log set discarded_at = null, meta = v_meta where id = e.id;
    else
      return;
    end if;
  end if;

  v_flag := coalesce((v_meta->>'mvmv_done')::boolean, false);
  n_checked := e.is_checked; n_done := e.done_at; n_flag := v_flag;
  if v_done is not null and (coalesce(e.is_checked, false) = false or v_flag) then
    n_checked := true; n_done := v_donets; n_flag := true;
  elsif v_done is null and v_flag then
    n_checked := false; n_done := null; n_flag := false;
  end if;

  if e.text is distinct from m.name or e.image_url is distinct from m.poster
     or e.created_at is distinct from v_created or e.is_checked is distinct from n_checked
     or e.done_at is distinct from n_done or n_flag is distinct from v_flag then
    update didi_log set text = m.name, image_url = m.poster, created_at = v_created,
           is_checked = n_checked, done_at = n_done,
           meta = v_meta || jsonb_build_object('mvmv_done', n_flag,
                    'ref', jsonb_build_object('t', 'mvmv_movie', 'id', p_movie, 'name', m.name))
     where id = e.id;
  end if;
end $function$;

-- 기존 기록 한 번 다시 맞추기 (날짜는 그대로, 시각만 바뀜)
do $$
declare r record;
begin
  for r in select distinct user_id, meta->>'bkbk_book' as k from didi_log where meta->>'bkbk_book' is not null loop
    perform didi_sync_book(r.k, r.user_id);
  end loop;
  for r in select distinct user_id, meta->>'mvmv_movie' as k from didi_log where meta->>'mvmv_movie' is not null loop
    perform didi_sync_movie(r.k, r.user_id);
  end loop;
end $$;
