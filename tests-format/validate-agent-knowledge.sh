#!/bin/sh
# Validate that project changes include substantive agent knowledge updates.

set -eu

usage() {
	printf 'Usage: %s [--base REF] [ROOT_DIR]\n' "${0##*/}" >&2
}

base=
root=.
while [ "$#" -gt 0 ]; do
	case "$1" in
	--base)
		[ "$#" -ge 2 ] || {
			usage
			exit 2
		}
		base=$2
		shift 2
		;;
	-h | --help)
		usage
		exit 0
		;;
	-*)
		usage
		exit 2
		;;
	*)
		[ "$root" = . ] || {
			usage
			exit 2
		}
		root=$1
		shift
		;;
	esac
done

cd "$root"
command -v git >/dev/null 2>&1 || {
	echo 'ERROR: git is required' >&2
	exit 2
}
git rev-parse --show-toplevel >/dev/null 2>&1 || {
	echo 'ERROR: run inside a Git worktree' >&2
	exit 2
}

if [ -n "$base" ]; then
	git rev-parse --verify "$base^{commit}" >/dev/null 2>&1 || {
		printf 'ERROR: base revision does not resolve: %s\n' "$base" >&2
		exit 2
	}
	changed=$(git diff --name-only "$base" --)
else
	changed=$(git diff --name-only HEAD --)
fi
untracked=$(git ls-files --others --exclude-standard)
changed=$(printf '%s\n%s\n' "$changed" "$untracked" | awk 'NF && !seen[$0]++')

[ -n "$changed" ] || {
	echo 'Agent knowledge check: no repository changes detected.'
	exit 0
}

is_instruction() {
	case "$1" in
	AGENTS.md | */AGENTS.md | *.agent.md | .agents/skills/*/SKILL.md | .github/skills/*/SKILL.md | .claude/skills/*/SKILL.md | */SKILL.md | *copilot-instructions.md | .cursorrules | */.cursorrules | .cursor/rules/*.md | .cursor/rules/*.mdc | .windsurfrules | .windsurf/rules/* | GEMINI.md | */GEMINI.md | CLAUDE.md | */CLAUDE.md)
		return 0
		;;
	*) return 1 ;;
	esac
}

project_changes=
knowledge_changes=
while IFS= read -r path; do
	[ -n "$path" ] || continue
	if is_instruction "$path"; then
		knowledge_changes="${knowledge_changes}${knowledge_changes:+
}${path}"
	else
		project_changes="${project_changes}${project_changes:+
}${path}"
	fi
done <<EOF
$changed
EOF

if [ -n "$project_changes" ] && [ -z "$knowledge_changes" ]; then
	printf '%s\n' 'ERROR: project changes have no accompanying agent/skills instruction update.' 'Update a relevant AGENTS.md, agent definition, or SKILL.md with substantive reusable guidance.' >&2
	exit 1
fi

if [ -n "$knowledge_changes" ]; then
	valid_updates=0
	status_file=$(mktemp "${TMPDIR:-/tmp}/agent-knowledge.XXXXXX")
	trap 'rm -f "$status_file"' EXIT HUP INT TERM
	printf '%s\n' "$knowledge_changes" | while IFS= read -r path; do
		[ -n "$path" ] || continue
		[ -f "$path" ] || {
			printf 'ERROR: changed instruction file is missing: %s\n' "$path" >&2
			exit 1
		}
		case "$path" in
		*.agent.md)
			grep -q '^## Post-Change Knowledge Synchronization$' "$path" || {
				printf 'ERROR: agent lacks required synchronization section: %s\n' "$path" >&2
				exit 1
			}
			;;
		*/SKILL.md)
			grep -q '^## Maintenance & Continuous Learning$' "$path" || {
				printf 'ERROR: skill lacks required maintenance section: %s\n' "$path" >&2
				exit 1
			}
			if ! grep -q '^name:' "$path" ||
				! sed -n '1p' "$path" | grep -q '^---$' ||
				! awk 'NR > 1 && /^---[[:space:]]*$/ { found = 1; exit } END { exit !found }' "$path"; then
				printf 'ERROR: skill frontmatter is missing or malformed: %s\n' "$path" >&2
				exit 1
			fi
			;;
		AGENTS.md | */AGENTS.md)
			grep -q '^## Continuous Agent & Skills Maintenance$' "$path" || {
				printf 'ERROR: AGENTS.md lacks required maintenance section: %s\n' "$path" >&2
				exit 1
			}
			;;
		esac

		if git ls-files --error-unmatch "$path" >/dev/null 2>&1; then
			diff_content=$(git diff --unified=0 HEAD -- "$path" | sed -n '/^[+-][^+-]/p' | sed 's/^[+-][[:space:]]*//' | grep -Ev '^($|#{1,6}[[:space:]]|<!--|-->$|[-*_]{3,}$)' || true)
		else
			diff_content=$(sed -E 's/^[[:space:]]+|[[:space:]]+$//g' "$path" | grep -Ev '^($|#{1,6}[[:space:]]|<!--|-->$|[-*_]{3,}$)' || true)
		fi
		if [ -n "$diff_content" ]; then
			printf 'valid\n' >>"$status_file"
		fi
	done
	valid_updates=$(wc -l <"$status_file" | tr -d ' ')
	rm -f "$status_file"
	trap - EXIT HUP INT TERM
	if [ "$valid_updates" -eq 0 ]; then
		echo 'ERROR: instruction changes are empty, cosmetic, or contain no substantive content change.' >&2
		exit 1
	fi
fi

# Validate relative Markdown links in changed operational documents.
printf '%s\n' "$knowledge_changes" | while IFS= read -r path; do
	[ -n "$path" ] || continue
	[ -f "$path" ] || continue
	perl -MFile::Basename=dirname -MFile::Spec -e '
		my ($file) = @ARGV;
		open my $fh, "<", $file or die "ERROR: cannot read $file: $!\n";
		local $/;
		my $text = <$fh>;
		while ($text =~ /\]\(([^)]+)\)/g) {
			my $target = $1;
			$target =~ s/^<|>$//g;
			next if $target =~ m{^(?:[A-Za-z][A-Za-z0-9+.-]*:|#)};
			$target =~ s/[?#].*$//;
			next unless length $target;
			my $resolved = File::Spec->catfile(dirname($file), $target);
			die "ERROR: broken local reference in $file: $target\n" unless -e $resolved;
		}
	' "$path"
done

printf 'Agent knowledge check: PASS (%s substantive instruction update(s); structural checks and local references validated).\n' "$valid_updates"
echo 'Semantic relevance still requires human review.'
