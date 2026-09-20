# Lambda

**A declarative, database-free package manager for Vind Linux, written entirely in POSIX shell.**

## About

Lambda is the package manager built for [Vind Linux](https://github.com/VindLinux). It is written in `sh` (POSIX, using `local`, which dash, bash, and BusyBox ash all support), and it deliberately avoids any external state: what's on disk *is* the state.

Lambda is **declarative**. You don't tell it to install or remove packages directly — you describe the system you want in `/etc/lambda/system`, and `lambda reconcile` makes the real system converge to that description.

```text
/etc/lambda/system                 desired state (what you asked for)
        │
        ▼
 lambda reconcile  ──── compares ────►  /usr/share/lambda/installed/   current state
        │
        ▼
 /usr/share/lambda/packages/         recipes (how to build each package)
```

There is no `lambda install` or `lambda remove`. Installing and removing is always the job of `reconcile`, driven by the `system` file.

## Features

- **Declarative package management** — edit `/etc/lambda/system` and let `reconcile` do the rest.
- **No database, no `jq`** — the filesystem is the single source of truth.
- **Full dependency resolution** — transitive dependency closure, cycle detection, and a readable dependency tree via `lambda deps`.
- **Compile-time attributes** — optional per-package features (`COMP_ATTRS`), configurable globally or per package, with automatic rebuilds when they change.
- **Orphan detection** — `lambda orphan` finds and removes dependencies nobody needs anymore.
- **Safe `/etc` handling** — config files are never overwritten or deleted; conflicts are written alongside as `.lambda-new`.
- **Multiple recipe repositories** — an official repository plus any number of community repositories, resolved by priority.
- **Atomic-ish operations** — recipe swaps, self-updates, and binary replacement all avoid leaving the system in a half-updated state.

## Commands

| Command | What it does | Needs root |
|---|---|---|
| `lambda mutate append <pkg>...` | Adds packages to `system` | yes |
| `lambda mutate purge <pkg>...` | Removes packages from `system` | yes |
| `lambda deps <pkg>` | Shows the dependency tree and install order | no |
| `lambda reconcile` | Installs, upgrades, rebuilds, and removes to match `system` | yes |
| `lambda orphan` | Finds and removes dependencies nobody needs anymore | yes |
| `lambda sync [--soft]` | Updates local recipes from the configured repositories | yes |
| `lambda update` | Updates Lambda itself | yes |
| `lambda info` | Shows a package information | no |

## Current Status

Lambda is **experimental and under active development**, alongside Vind Linux itself. The system can already:

- Resolve and install packages declaratively through `reconcile`
- Detect and report dependency cycles or missing recipes before touching anything
- Track compile-time attributes and trigger rebuilds when they change
- Protect user edits in `/etc` across upgrades and removals
- Sync recipes from multiple prioritized repositories
- Update itself in place

## Philosophy

Lambda is built around a few simple ideas:

- Keep state in the filesystem, not in a database.
- Describe what you want and let the tool figure out how to get there.
- Never silently overwrite what the user has edited.
- Prefer plain POSIX shell and common system tools over new dependencies.
- Make every operation predictable and inspectable.

## Repository Structure

```text
lambda/
├── lambda.sh                 becomes /usr/bin/lambda
├── installer.sh              installs and updates Lambda
├── configs/                  templates for /etc/lambda/*
│   ├── make.conf              build environment (CC, CFLAGS, global COMP_ATTRS, ...)
│   ├── lambda.conf             recipe/self-update repositories
│   └── package.compattrs        per-package COMP_ATTRS overrides
├── funcs/                    becomes /usr/lib/lambda/
│   ├── lib.sh                shared library
│   ├── attrs.sh               attribute checks
│   ├── recipe-env.sh          environment for recipes
│   ├── info.sh                  package information
│   ├── install.sh             package installation
│   ├── remove.sh               package removal
│   ├── mutate.sh               edits to /etc/lambda/system
│   ├── deps.sh                  dependency tree and order
│   ├── orphan.sh                orphan detection
│   ├── reconcile.sh             the core install/upgrade/remove loop
│   ├── sync.sh                  recipe repository sync
│   └── update.sh                self-update
└── examples/package-example    an annotated example package with example files inside
```

## File Layout

Lambda keeps everything under three places. There is no other state anywhere.

```text
/etc/lambda/
├── system              desired state: one package name per line (# comments allowed)
├── make.conf            build environment + global COMP_ATTRS
├── lambda.conf           recipe/self-update repositories
└── package.compattrs      per-package COMP_ATTRS overrides

/usr/share/lambda/packages/<pkg>/       the recipe database ($PKG_DB), one dir per known package
├── recipe               pkg_download / pkg_build / pkg_install / pkg_strip
├── dependencies          one dependency per line, "pkg" or "flag?pkg"
├── compattrs              attribute names this package understands (bare names, one per line)
├── description            one-line human-readable description
└── version                 one-line version string

/usr/share/lambda/installed/<pkg>/      the installed database ($INST_DB), one dir per installed package
├── files                 every path this package's recipe put on disk (its manifest)
├── compattrs              the resolved COMP_ATTRS string it was actually built with
├── version                 the version that is currently installed
├── reason                  "explicit" (asked for in `system`) or "dependency" (pulled in)
└── build                    date/cc/cxx/cflags/cxxflags snapshot of the last build
```

A package only exists to Lambda in one of two independent senses: it is *known* if it has a directory under `packages/`, and it is *installed* if it has a directory under `installed/`. A package can be installed with no matching recipe anymore (the recipe disappeared upstream) — `lambda info` reports this explicitly, and `lambda orphan`/`reconcile` can still remove it by name.

## Compile-time Attributes (COMP_ATTRS)

COMP_ATTRS are optional, per-package build-time features — think `--enable-x11`, `--without-python`, that sort of switch. Lambda resolves them from three layers and rebuilds a package automatically whenever the *resolved* value changes.

### 1. What a package understands

A package opts into attributes by listing their bare names in its `compattrs` file, one per line:

```text
# examples/package-example/compattrs
shout
color
```

Only attributes listed here mean anything for that package. Anything not declared is simply not applicable — you cannot enable an attribute a package doesn't know about, and Lambda never complains about it either, it's just ignored.

### 2. Setting the global default — `make.conf`

`/etc/lambda/make.conf` has a single `COMP_ATTRS` variable, shared by every package:

```sh
# name alone  = enabled
# -name       = explicitly disabled
# not listed  = disabled by default
COMP_ATTRS="color -shout"
```

Every attribute a package declares starts disabled unless `COMP_ATTRS` turns it on.

### 3. Overriding one package — `package.compattrs`

`/etc/lambda/package.compattrs` lets you override the global default for a single package, without touching `make.conf`:

```text
# format: <package> <attr> [-attr ...]
vim -python lua
```

An override always wins over the global value for that package.

### How the final value is computed

`resolve_comp_attrs` (`lib.sh`) walks every attribute the package declares in its `compattrs` file and, for each one, applies the layers in order — **declared → global (`make.conf`) → per-package override (`package.compattrs`)** — with each later layer taking precedence over the previous one. The result is printed as a single string, e.g.:

```text
-python lua -clipboard
```

where a bare name means enabled and a `-name` prefix means explicitly disabled. This is exactly the string exported as `COMP_ATTRS` to a recipe's environment (see `install.sh`/`recipe-env.sh`), and it's what a recipe checks with:

```sh
if attr_on color; then
    color_flag="--enable-color"
fi
```

`attr_on` (`attrs.sh`) matches whole tokens only — it deliberately avoids `grep -w`, because `-python` contains the substring `python`, and a naive match would treat the package as having Python enabled when it's explicitly disabled.

### Conditional dependencies

A package's `dependencies` file can make a dependency conditional on one of its own attributes:

```text
zlib             # unconditional, always pulled in
color?ncurses    # only pulled in if "color" resolves to enabled
```

`direct_deps` (`lib.sh`) resolves the package's own `COMP_ATTRS` first, then only emits `ncurses` if `color` is a bare (enabled) token in that resolved string. The same whole-token matching rule applies here, for the same reason as `attr_on`.

### Rebuilds

Lambda distinguishes the *resolved* string (`-python lua -clipboard`) from the *set of enabled attributes* (`lua`), because that's the only part that actually matters for whether a rebuild is needed — a package gaining a new attribute it understands, that still defaults to disabled, doesn't need a rebuild. `attrs_enabled` extracts and sorts just the enabled names; `reconcile` and `info` both compare `attrs_enabled(installed/<pkg>/compattrs)` against `attrs_enabled(resolve_comp_attrs(pkg))` — if the sets differ, the package is scheduled for `rebuild`. `attrs_diff` then produces a human-readable `+lua -python` summary, shown next to the rebuild in `lambda reconcile`'s plan as `[ trigger: +lua -python ]`.

### Inspecting the result

`lambda info <pkg>` shows, per package, which attributes are currently enabled/excluded and where each one's value came from — `defaults`, `make.conf`, or `package.compattrs` — so you can always tell why a package was (or wasn't) rebuilt.

## How `reconcile` Decides What to Do

`lambda reconcile` is the only thing that actually installs, upgrades, rebuilds, or removes packages. Each run:

1. Resolves the full dependency closure of `/etc/lambda/system` (dependencies before dependents), failing early — before touching anything — if there's a missing recipe or a circular dependency.
2. Updates the bookkeeping in `installed/<pkg>/reason`: anything listed in `system` is marked `explicit`; anything installed only because something else needs it is marked `dependency`. A package removed from `system` but still required by something else quietly becomes a `dependency` instead of being removed — it survives until nothing needs it anymore, at which point `lambda orphan` picks it up.
3. Builds a plan, dependencies first:
   - **install** — wanted, not yet installed.
   - **upgrade** — installed, but the recipe now has a different `version`.
   - **rebuild** — installed, but the resolved set of *enabled* `COMP_ATTRS` no longer matches what it was built with.
   - **remove/purge** — installed `explicit`ly, no longer in `system`, and nothing else needs it.
4. Shows the plan (colorized: green = install/up to date, yellow = rebuild/update available, red = purge/excluded) and asks for confirmation.
5. Applies install/upgrade/rebuild first, then removals — so a failed build never touches a package that was already working.

Orphaned dependencies (installed as a dependency, but nothing wanted needs them anymore) are never removed by `reconcile` itself; that's what `lambda orphan` is for, run separately.

## Writing a Recipe

A recipe is a single `recipe` file with one function per phase:

| Function | Required | Default |
|---|---|---|
| `pkg_download` | yes | — |
| `pkg_build` | no | does nothing |
| `pkg_install` | yes | — |
| `pkg_strip` | no | strips symbols from ELF files |

```sh
src="hello-1.0"

pkg_download()
{
    # fetch and extract the source here
    :
}

pkg_build()
{
    cd "$src" || exit 1
    ./configure --prefix="$PREFIX"
    make $MAKEOPTS
}

pkg_install()
{
    cd "$src" || exit 1
    make DESTDIR="$DESTDIR" install
}
```

Each phase runs in its own `sh`, starting in the staging directory, with everything installed under `$DESTDIR`. Nothing carries over between phases except what the recipe file itself defines at the top level (like `src` above) — `cd` into the source again in every phase that needs it. Available to every phase: `DESTDIR`, `PREFIX`/`MAKEOPTS`/`CFLAGS`/... from `make.conf`, `COMP_ATTRS` (the package's own resolved string), `PKG_NAME`, `PKG_VERSION`, and `attr_on <attr>` to check an attribute. See `examples/package-example/recipe` for a fully annotated recipe.

The phases are named `pkg_*` on purpose: a function called `install` would shadow coreutils' `install`, and `pkg_install` calling `install -D` would otherwise recurse into itself.

Files placed under `/etc` are special: they are never overwritten by an upgrade/rebuild if the on-disk copy differs from the packaged one (the new version is kept alongside as `<file>.lambda-new` instead), and they are never deleted when the package is removed.

## Quick Example

```sh
# install Lambda and fetch recipes
sudo sh installer.sh
sudo lambda sync

# see if vim is avaliable

# see what vim would pull in
lambda deps vim

# ask for vim and apply
sudo lambda mutate append vim
sudo lambda reconcile

# no longer want vim
sudo lambda mutate purge vim
sudo lambda reconcile
sudo lambda orphan
```

## Requirements

Lambda only relies on common system tools: `id`, `sed`, `grep`, `cat`, `cut`, `sort`, `tr`, `find`, `tar`, `mktemp`, `cmp`, `diff`, `cp`, `mv`, `rm`, `rmdir`, `mkdir`, `chmod`, `touch`, `env`, `od`, `head`, `date`, and `git` (only for `sync` and `update`).

## Related Projects

- **[Vind Linux](https://github.com/VindLinux)** — the distribution Lambda is built for
- **[packages](https://github.com/VindLinux/vind-packages)** — official Lambda recipes

## Contributing

Lambda is currently a personal experimental project, but contributions, ideas, bug reports, and discussions are welcome.

If you find something broken, feel free to open an issue.

## License

This project is licensed under the [MIT License](LICENSE).
