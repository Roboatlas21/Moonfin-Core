#!/usr/bin/env python3
"""Rebuild Wizard V3 with the original feature commits and a clean upstream merge.

This runs only on an isolated CI branch. It does not rewrite the original
feature branch, Wizard V2, or any existing merge commit.
"""
import os
import subprocess
import sys

PR = os.environ["PR_TIP"]
UPSTREAM = os.environ["UPSTREAM_TIP"]
WIZARD_V2 = os.environ["WIZARD_V2_TIP"]
V3 = os.environ["WIZARD_V3_BRANCH"]
MERGE_MESSAGE = "Merge remote-tracking branch 'origin/main' into feat/live-tv-channel-groups-pr"

MESSAGES = [
    (
        "Polish Live TV filters and navigation",
        "Improve the group picker, pinned filters, saved preferences, search, styling, and TV/mobile focus handling.",
    ),
    (
        "Make guide paging and loading more reliable",
        "Keep EPG listings and displayed time in sync, handle partial failures and retries, and improve guide navigation and carousel loading.",
    ),
    (
        "Improve Plex Free TV reliability",
        "Handle Plex Cloud connection failures, background sessions, EPG errors, lineup recovery, authentication, and Featured groups.",
    ),
    (
        "Keep channel favorites in sync across Live TV",
        "Sync Plex account favorites across Cloud and PMS connections, maintain DVR identities, and refresh favorites on Home and in search across Jellyfin, Emby, and Plex.",
    ),
    (
        "Streamline Live TV tests",
        "Keep tests focused on everyday Live TV usage, including guide navigation, channel groups, search, playback, and favorites. Remove redundant coverage while preserving important regression checks.",
    ),
]


def git(*args, check=True):
    result = subprocess.run(["git", *args], capture_output=True, text=True)
    if check and result.returncode:
        raise RuntimeError(f"git {' '.join(args)}\n{result.stdout}\n{result.stderr}")
    return result


def classify(path):
    if path.startswith(("test/", "integration_test/")) or "/test/" in path or "/integration_test/" in path:
        return 5
    if (
        path.startswith(("lib/l10n/", "lib/preference/", "lib/ui/screens/livetv/guide/"))
        or path in {
            "lib/ui/screens/livetv/live_tv_guide_screen.dart",
            "lib/ui/screens/livetv/epg/widgets/epg_now_next_card.dart",
            "lib/data/services/plugin_sync_service.dart",
            "lib/data/services/synced_fields.dart",
        }
    ):
        return 1
    if (
        path in {
            "lib/data/viewmodels/live_tv_guide_view_model.dart",
            "lib/ui/widgets/live_tv/channel_carousel_overlay.dart",
            "lib/ui/widgets/live_tv/live_tv_recording_dialog.dart",
        }
        or path.startswith("lib/ui/widgets/live_tv/")
    ):
        return 2
    if (
        path.startswith(("packages/server_plex/", "lib/auth/", "lib/playback/", "lib/ui/screens/auth/"))
        or path in {
            "lib/data/services/moonbase_endpoint.dart",
            "lib/ui/screens/livetv/live_tv_channel_player_loader.dart",
            "lib/ui/screens/playback/appletv_livetv_player_host_screen.dart",
        }
    ):
        return 3
    if (
        path.startswith(("lib/data/", "lib/ui/screens/home/"))
        or path in {"lib/data/services/plex_free_tv_favorites.dart"}
    ):
        return 4
    if path.startswith("lib/ui/screens/livetv/"):
        return 2
    raise RuntimeError(f"Unclassified changed file: {path}")


def main():
    git("config", "user.name", "Moonfin history builder")
    git("config", "user.email", "history-builder@users.noreply.github.com")
    for ref in (PR, UPSTREAM, WIZARD_V2):
        git("cat-file", "-e", f"{ref}^{{commit}}")
    if git("ls-remote", "--heads", "origin", V3).stdout.strip():
        raise RuntimeError(f"Destination already exists: {V3}")

    git("checkout", "-b", V3, PR)
    merge = git("merge", "--no-ff", "--no-commit", "-s", "ort", "-X", "ours", UPSTREAM, check=False)
    print("Upstream merge result:", merge.returncode, merge.stdout[-1800:], merge.stderr[-1800:], flush=True)
    if merge.returncode:
        # For non-content conflicts (for example modify/delete), retain the
        # original feature side. The subsequent commits reconcile the complete
        # tracked tree against Wizard V2 regardless of conflict resolution.
        unresolved = git("diff", "--name-only", "--diff-filter=U", "-z").stdout.split("\0")
        for path in filter(None, unresolved):
            print("Resolving merge conflict:", path, flush=True)
            chosen = git("checkout", "--ours", "--", path, check=False)
            if chosen.returncode:
                git("rm", "-f", "--ignore-unmatch", "--", path)
            git("add", "-A", "--", path)

    if git("ls-files", "-u").stdout.strip():
        raise RuntimeError("Unresolved merge paths remain")
    if not os.path.isfile(".git/MERGE_HEAD"):
        raise RuntimeError("Expected an in-progress upstream merge")
    git("commit", "-m", MERGE_MESSAGE)
    merge_sha = git("rev-parse", "HEAD").stdout.strip()
    parent_list = git("rev-list", "--parents", "-n", "1", "HEAD").stdout.strip().split()
    if parent_list != [merge_sha, PR, UPSTREAM]:
        raise RuntimeError(f"Incorrect merge parents: {parent_list}")
    print("MERGE", merge_sha, "PARENTS", parent_list[1:], flush=True)

    changed = [
        p for p in git("diff", "--name-only", "--no-renames", "-z", "HEAD", WIZARD_V2).stdout.split("\0")
        if p
    ]
    groups = {n: [] for n in range(1, 6)}
    for path in changed:
        groups[classify(path)].append(path)
    print("Files different from Wizard V2:", len(changed), flush=True)
    for n in range(1, 6):
        print(f"GROUP {n} ({len(groups[n])} files):", *groups[n], sep="\n  ", flush=True)
        if not groups[n]:
            raise RuntimeError(f"Group {n} was unexpectedly empty")

    for n in range(1, 6):
        title, description = MESSAGES[n - 1]
        # Git restore writes the source tree's exact blobs and file modes into
        # both the index and working tree, including deleting obsolete paths.
        for path in groups[n]:
            git("restore", "--source", WIZARD_V2, "--staged", "--worktree", "--", path)
        if git("diff", "--cached", "--quiet", check=False).returncode == 0:
            raise RuntimeError(f"No staged changes for group {n}")
        git("commit", "-m", title, "-m", description)
        print(f"COMMIT {n} {git('rev-parse', 'HEAD').stdout.strip()} {title}", flush=True)

    actual_tree = git("rev-parse", "HEAD^{tree}").stdout.strip()
    expected_tree = git("rev-parse", f"{WIZARD_V2}^{{tree}}").stdout.strip()
    if actual_tree != expected_tree:
        diff = git("diff", "--stat", "HEAD", WIZARD_V2).stdout
        raise RuntimeError(f"Final V3 tree differs from V2:\n{diff}")
    if git("diff", "--quiet", "HEAD", WIZARD_V2, check=False).returncode:
        raise RuntimeError("Final content comparison against V2 failed")
    count = int(git("rev-list", "--first-parent", "--count", f"{PR}..HEAD").stdout.strip())
    if count != 6:
        raise RuntimeError(f"Expected one merge and five commits, found {count}")
    if git("rev-list", "--first-parent", "-n", "6", "HEAD").stdout.strip().splitlines()[-1] != merge_sha:
        raise RuntimeError("Unexpected first-parent history")
    print("VERIFIED final tracked tree:", actual_tree, flush=True)
    print("VERIFIED original PR tip:", PR, flush=True)
    print("VERIFIED six first-parent commits on top (merge + five)", flush=True)
    print("PUSHING", V3, flush=True)
    git("push", "origin", f"HEAD:refs/heads/{V3}")
    print("SUCCESS V3", git("rev-parse", "HEAD").stdout.strip(), flush=True)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print("ASSEMBLY FAILED:", error, flush=True)
        sys.exit(1)
