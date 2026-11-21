#!/usr/bin/env python3
"""Reattribute only Wizard V3's six newly-created commits.

The original PR and upstream commits are never recreated. Git trees,
commit messages, and merge parents remain identical. This operation
refuses to overwrite V3 if its head changed since assembly.
"""
import os
import subprocess
import sys

REPO = "origin"
BRANCH = "integration/live-tv-channel-groups-wizard-v3-20261120"
EXPECTED = "9d9f8da0e0de67a89f5a52ae7062fdf48c0efc84"
PR = "b27e2be2f4e34edba6eec0ab25c218adffc2ba91"
UPSTREAM = "defe4661b603826bf91c9564a5bd71ccadbb47e6"
V2 = "2d9163499a7f694c7dfd953c9461936677934d16"

def git(*args, inp=None, env=None):
    p = subprocess.run(["git", *args], input=inp, text=True,
                       capture_output=True, env=env)
    if p.returncode:
        raise RuntimeError(f"git {' '.join(args)}: {p.stdout[-1200:]} {p.stderr[-1200:]}")
    return p.stdout.strip()

def main():
    remote_line = git("ls-remote", "--heads", REPO, BRANCH)
    if not remote_line or remote_line.split()[0] != EXPECTED:
        raise RuntimeError("Wizard V3 head changed: refusing rewrite")
    git("fetch", "--no-tags", REPO,
        f"refs/heads/{BRANCH}:refs/remotes/{REPO}/{BRANCH}")
    original = git("rev-list", "--first-parent", "-n", "7", EXPECTED).splitlines()
    if len(original) != 7 or original[-1] != PR:
        raise RuntimeError(f"Unexpected first-parent V3 ancestry: {original}")
    merge = original[-2]
    parents = git("rev-list", "--parents", "-n", "1", merge).split()
    if parents != [merge, PR, UPSTREAM]:
        raise RuntimeError(f"Unexpected merge parents: {parents}")
    if git("rev-parse", f"{EXPECTED}^{{tree}}") != git("rev-parse", f"{V2}^{{tree}}"):
        raise RuntimeError("V3 already differs from V2")

    # Take attribution from the user's own PR commit, not an invented author.
    author = git("show", "-s", "--format=%an%n%ae", PR).splitlines()
    if author[0] != "Roboatlas21":
        raise RuntimeError(f"Unexpected PR author: {author[0]}")
    identity = {
        "GIT_AUTHOR_NAME": author[0],
        "GIT_AUTHOR_EMAIL": author[1],
        "GIT_COMMITTER_NAME": author[0],
        "GIT_COMMITTER_EMAIL": author[1],
    }
    last = PR
    for index, old in enumerate(reversed(original[:-1])):
        tree = git("rev-parse", f"{old}^{{tree}}")
        message = git("show", "-s", "--format=%B", old)
        old_parent_list = git("rev-list", "--parents", "-n", "1", old).split()
        if index == 0 and old != merge:
            raise RuntimeError("Missing expected upstream merge")
        if index and len(old_parent_list) != 2:
            raise RuntimeError("Nonlinear feature history")
        env = dict(os.environ, **identity,
            GIT_AUTHOR_DATE=git("show", "-s", "--format=%aI", old),
            GIT_COMMITTER_DATE=git("show", "-s", "--format=%cI", old))
        new_parents = [last, UPSTREAM] if index == 0 else [last]
        args = ["commit-tree", tree]
        for parent in new_parents:
            args += ["-p", parent]
        new = git(*args, inp=message + "\n", env=env)
        if git("show", "-s", "--format=%B", new) != message:
            raise RuntimeError("Commit message changed during recreation")
        if git("rev-parse", f"{new}^{{tree}}") != tree:
            raise RuntimeError("A recreated commit changed files")
        print(f"RECREATED {index + 1}/6 {new[:12]} {message.splitlines()[0]}", flush=True)
        last = new

    if git("rev-parse", f"{last}^{{tree}}") != git("rev-parse", f"{V2}^{{tree}}"):
        raise RuntimeError("Final tracked tree does not match Wizard V2")
    expected_lease = f"--force-with-lease=refs/heads/{BRANCH}:{EXPECTED}"
    git("push", expected_lease, REPO, f"{last}:refs/heads/{BRANCH}")
    if git("ls-remote", "--heads", REPO, BRANCH).split()[0] != last:
        raise RuntimeError("Remote head verification failed after push")
    print(f"SUCCESS: {BRANCH} {last}", flush=True)
    print(f"IDENTITY: {author[0]} (matches original PR)", flush=True)
    print("VERIFIED: original PR SHA, upstream SHA, messages, merge parents, V2 tree", flush=True)

if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print("REPAIR FAILED:", e, flush=True)
        sys.exit(1)
