#!/usr/bin/env sh
set -eu

SCRIPT_NAME=$(basename "$0")
DEFAULT_DATASET_NAME="dummy-idataset"

print_help() {
    cat <<EOF_HELP
Usage:
  sh $SCRIPT_NAME [DATASET_PATH]
  ./$SCRIPT_NAME [DATASET_PATH]

Arguments:
  DATASET_PATH   Optional path to the existing dummy inode dataset directory
                 Default: ./$DEFAULT_DATASET_NAME

Behavior:
  - If DATASET_PATH is omitted, the script uses:
      ./$DEFAULT_DATASET_NAME
  - Detects standard chunk inode units from existing chunk_XXXX directories
  - Shows current chunk layout first
  - Prompts for how many chunks to release
  - Releases chunks from largest index backward
  - A smaller remainder chunk such as chunk_0000 will usually be kept

Examples:
  1) sh $SCRIPT_NAME
  2) sh $SCRIPT_NAME ./my-idataset
EOF_HELP
}

if [ "$#" -eq 1 ]; then
    case "$1" in
        -h|--help)
            print_help
            exit 0
            ;;
    esac
fi

if [ "$#" -gt 1 ]; then
    echo "Error: invalid arguments."
    echo
    print_help
    exit 1
fi

DATASET_PATH="./$DEFAULT_DATASET_NAME"

if [ "$#" -eq 1 ]; then
    DATASET_PATH=$1
fi

if [ ! -d "$DATASET_PATH" ]; then
    echo "Error: dataset path does not exist: $DATASET_PATH"
    echo
    print_help
    exit 1
fi

if ! command -v numfmt >/dev/null 2>&1; then
    echo "Error: numfmt command not found."
    exit 1
fi

if ! command -v df >/dev/null 2>&1; then
    echo "Error: df command not found."
    exit 1
fi

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM

ALL_CHUNKS_LIST="$TMP_DIR/all_chunks.txt"
INFER_CHUNKS_LIST="$TMP_DIR/infer_chunks.txt"
CHUNK_UNITS_LIST="$TMP_DIR/chunk_units.txt"
RELEASABLE_CHUNKS_LIST="$TMP_DIR/releasable_chunks.txt"

human_count() {
    numfmt --to=si "$1"
}

ABS_DATASET_PATH=$(CDPATH= cd -- "$DATASET_PATH" && pwd)
cd "$DATASET_PATH"

find . -maxdepth 1 -mindepth 1 -type d -name 'chunk_[0-9][0-9][0-9][0-9]' -printf '%f\n' | sort > "$ALL_CHUNKS_LIST"

if [ ! -s "$ALL_CHUNKS_LIST" ]; then
    echo "Error: no chunk_XXXX directories found in: $ABS_DATASET_PATH"
    exit 1
fi

: > "$CHUNK_UNITS_LIST"
while IFS= read -r chunk; do
    [ -n "$chunk" ] || continue
    file_count=$(find "$chunk" -maxdepth 1 -type f -name 'inode_*.dat' | wc -l | tr -d ' ')
    inode_units=$((file_count + 1))
    printf "%s %s\n" "$chunk" "$inode_units" >> "$CHUNK_UNITS_LIST"
done < "$ALL_CHUNKS_LIST"

echo "Dataset path               : $ABS_DATASET_PATH"
echo
echo "Current chunks:"
cat "$CHUNK_UNITS_LIST" | sed 's/^/  /'
echo

grep -v '^chunk_0000 ' "$CHUNK_UNITS_LIST" > "$INFER_CHUNKS_LIST" || true

if [ ! -s "$INFER_CHUNKS_LIST" ]; then
    cp "$CHUNK_UNITS_LIST" "$INFER_CHUNKS_LIST"
    echo "Warning: only chunk_0000 or very few chunks remain."
    echo "Chunk unit detection may be ambiguous."
    echo
fi

DETECTED_CHUNK_UNITS=$(
    awk '{print $2}' "$INFER_CHUNKS_LIST" \
    | sort -n \
    | uniq -c \
    | sort -k1,1nr -k2,2nr \
    | awk 'NR==1 { print $2 }'
)

if [ -z "$DETECTED_CHUNK_UNITS" ]; then
    echo "Error: failed to detect chunk inode units."
    exit 1
fi

ESTIMATED_RELEASE_UNITS=$DETECTED_CHUNK_UNITS

echo "Detected real chunk units   : $(human_count "$DETECTED_CHUNK_UNITS")"
echo "Estimated release/chunk     : $(human_count "$ESTIMATED_RELEASE_UNITS")"
echo

: > "$RELEASABLE_CHUNKS_LIST"
sort -r "$ALL_CHUNKS_LIST" | while IFS= read -r chunk; do
    [ -n "$chunk" ] || continue
    units=$(awk -v c="$chunk" '$1==c { print $2 }' "$CHUNK_UNITS_LIST")
    [ -n "$units" ] || continue
    if [ "$units" -eq "$DETECTED_CHUNK_UNITS" ]; then
        echo "$chunk" >> "$RELEASABLE_CHUNKS_LIST"
    fi
done

AVAILABLE_COUNT=$(wc -l < "$RELEASABLE_CHUNKS_LIST" | tr -d ' ')

if [ "$AVAILABLE_COUNT" -eq 0 ]; then
    echo "No releasable standard chunks found."
    exit 0
fi

echo "Releasable chunks:"
sed 's/^/  /' "$RELEASABLE_CHUNKS_LIST"
echo
echo "Releasable chunk count: $AVAILABLE_COUNT"
echo

printf "How many chunks do you want to release? "
IFS= read -r RELEASE_COUNT

case "$RELEASE_COUNT" in
    ''|*[!0-9]*)
        echo "Error: please enter a non-negative integer."
        exit 1
        ;;
esac

if [ "$RELEASE_COUNT" -eq 0 ]; then
    echo "Nothing to do."
    exit 0
fi

if [ "$RELEASE_COUNT" -gt "$AVAILABLE_COUNT" ]; then
    echo "Error: requested $RELEASE_COUNT chunks, but only $AVAILABLE_COUNT are available."
    exit 1
fi

echo
echo "Chunks to be removed:"
sed -n "1,${RELEASE_COUNT}p" "$RELEASABLE_CHUNKS_LIST" | sed 's/^/  /'

TOTAL_RELEASE_UNITS=$((RELEASE_COUNT * ESTIMATED_RELEASE_UNITS))
echo "Estimated released units: $(human_count "$TOTAL_RELEASE_UNITS")"
echo

printf "Confirm deletion? [y/N] "
IFS= read -r CONFIRM

case "$CONFIRM" in
    y|Y)
        ;;
    *)
        echo "Cancelled."
        exit 0
        ;;
esac

IFREE_BEFORE=$(df -Pi . | awk 'NR==2 {print $4}')

sed -n "1,${RELEASE_COUNT}p" "$RELEASABLE_CHUNKS_LIST" | while IFS= read -r chunk; do
    [ -n "$chunk" ] || continue
    rm -rf -- "$chunk"
    echo "Removed $chunk"
done

sync

IFREE_AFTER=$(df -Pi . | awk 'NR==2 {print $4}')
OBSERVED_RELEASE="N/A"
if [ -n "$IFREE_BEFORE" ] && [ -n "$IFREE_AFTER" ]; then
    OBSERVED_RELEASE=$((IFREE_AFTER - IFREE_BEFORE))
fi

echo
echo "Done."
echo "Observed released inodes: $OBSERVED_RELEASE"
echo "Current inode usage:"
df -i .
echo
find . -maxdepth 1 -mindepth 1 -type d -name 'chunk_[0-9][0-9][0-9][0-9]' -printf '%f\n' | sort | head -n 20
