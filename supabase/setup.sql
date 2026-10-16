-- PixelHopper online leaderboard: run this once in the Supabase dashboard (SQL Editor -> New query -> Run).
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

-- Matches the game's ordering: highest score first, shorter time wins ties
create index if not exists scores_rank_idx on public.scores (score desc, time_seconds asc);

alter table public.scores enable row level security;

drop policy if exists "Anyone can read scores" on public.scores;
create policy "Anyone can read scores"
	on public.scores for select
	to anon, authenticated
	using (true);

-- No insert/update/delete policies: with RLS on, direct writes are refused.

create or replace function public.submit_score(p_name text, p_score integer, p_time real)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
	clean_name text := left(btrim(coalesce(p_name, '')), 16);
begin
	if clean_name = '' then
		clean_name := 'Player';
	end if;

	-- Plausibility: a black carrot is worth 1 and a white one 3, and you can't collect
	-- them faster than a few per second
	if p_score < 1 or p_time <= 0 or p_score > p_time * 3 + 5 then
		raise exception 'Score not plausible' using errcode = '22023';
	end if;

	insert into public.scores (player_name, score, time_seconds)
	values (clean_name, p_score, p_time);
end;
$$;

revoke all on function public.submit_score(text, integer, real) from public;
grant execute on function public.submit_score(text, integer, real) to anon, authenticated;
