-- PixelHopper online leaderboard: run this in the Supabase dashboard (SQL Editor -> New query -> Run).
-- Safe to re-run: it creates what's missing and upgrades an older setup in place.
--
-- Security model: the game ships with the public (publishable/anon) key, so anyone can call these APIs.
--  * Anyone can READ scores.
--  * Nobody can insert, update or delete rows directly.
--  * New scores only go in through submit_score(), which checks they're plausible.
-- This stops casual junk, but a determined cheater can still submit a fake (plausible) score.

create table if not exists public.scores (
	id bigint generated always as identity primary key,
	player_name text not null check (char_length(player_name) between 1 and 16),
	score integer not null check (score between 1 and 10000),
	time_seconds real not null check (time_seconds > 0 and time_seconds < 36000),
	created_at timestamptz not null default now()
);

-- Each run has a client-generated id, so retried uploads can't create duplicates
alter table public.scores add column if not exists run_id text;
create unique index if not exists scores_run_id_key on public.scores (run_id);

-- Matches the game's ordering: highest score first, shorter time wins ties
create index if not exists scores_rank_idx on public.scores (score desc, time_seconds asc);

alter table public.scores enable row level security;

drop policy if exists "Anyone can read scores" on public.scores;
create policy "Anyone can read scores"
	on public.scores for select
	to anon, authenticated
	using (true);

-- No insert/update/delete policies: with RLS on, direct writes are refused.

-- Replaced by the version below that takes a run id
drop function if exists public.submit_score(text, integer, real);

-- Returns true if the run was saved, false if that run id was already on the server
create or replace function public.submit_score(p_run_id text, p_name text, p_score integer, p_time real)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
	clean_name text := left(btrim(coalesce(p_name, '')), 16);
begin
	if p_run_id is null or char_length(p_run_id) not between 8 and 64 then
		raise exception 'Missing run id' using errcode = '22023';
	end if;

	if clean_name = '' then
		clean_name := 'Player';
	end if;

	-- Plausibility: a black carrot is worth 1 and a white one 3, and you can't collect
	-- them faster than a few per second
	if p_score < 1 or p_time <= 0 or p_score > p_time * 3 + 5 then
		raise exception 'Score not plausible' using errcode = '22023';
	end if;

	insert into public.scores (run_id, player_name, score, time_seconds)
	values (p_run_id, clean_name, p_score, p_time)
	on conflict (run_id) do nothing;

	return found;
end;
$$;

revoke all on function public.submit_score(text, text, integer, real) from public;
grant execute on function public.submit_score(text, text, integer, real) to anon, authenticated;
