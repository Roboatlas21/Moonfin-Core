# Cinema Mode trailer requests

Requests use the active Moonfin account's existing Seerr connection, even when
the trailer plays from another server. This feature does not add direct Seerr
configuration: the existing Moonbase-backed Seerr integration is still required.

The resolver identifies the advertised title using both a TMDB ID and its
`movie` or `tv` type. These are separate ID namespaces. A typed movie trailer
can play before an episode, and a typed series trailer can play before a movie.
The media item's `MediaType: Video` does not identify the advertised title type.

Recognized identity sources:

- Jellyfin `Type: Movie` or `Type: Series` together with `ProviderIds.Tmdb`.
- Generic trailer videos with `ProviderIds.TmdbMediaType: movie|tv` and
  `ProviderIds.Tmdb`; optionally `ProviderIds.TmdbSeason` for a TV season.
- An accessible Movie or Series owner of an attached trailer, resolved through
  Moonbase with the source server's authenticated user.
- The legacy `trailers4jellyfin.trailer` provider marker from the movie-only
  enhanced Trailers4Jellyfin downloader. An explicit type takes precedence over
  this legacy convention.

Bare IDs on generic videos, conflicting metadata, inaccessible owners, ambiguous
matches and failed lookups leave the request button hidden. Episode TMDB IDs are
not treated as series IDs.

## Filename fallback

Filename/name searches require the updated Moonbase `Cinema/ResolveMedia`
endpoint on the trailer's source server. Moonfin passes the main feature's type:

| Main feature | Search | Required match |
| --- | --- | --- |
| Movie | Movies only | Exact normalized title and year |
| Episode | Series only | Exact unambiguous title; year optional |
| Anything else or unknown | None | No filename lookup |

For filename-only trailers, configure **movie trailers before movies and series
trailers before episodes**. The filename cannot prove its media type; mixed pools
require typed metadata. A failed movie search never switches to series, and
absence of a year never makes a movie filename a series.

Trailing `Season 5` or `S05` can identify a TV season. When present, the trailer
year is not compared with the series' first-air year; the series title must still
be unique. Hashed cache paths (including NeXroll's) can use a readable item name.
Contradictory filename/name matches are rejected.

## Request behavior

`Request Movie` keeps its existing standard-quality one-tap request.
`Request Series` pauses the trailer and opens the existing Seerr season picker.
It preselects an identified season only if Seerr reports it as requestable.
Otherwise the selection starts empty. The user can explicitly select seasons or
all seasons; merely opening the picker never submits a request.

The trailer resumes when the picker closes only if it was playing and the same
trailer/account is still active. Late results and stale dialogs cannot submit for
a different account or trailer. Request lookups do not delay playback or Skip.
Movie-only Moonbase responses are never used as typed identity fallbacks.
