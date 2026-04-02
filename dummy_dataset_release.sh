#!/usr/bin/env sh
set -eu

SCRIPT_NAME=$(basename "$0")
DEFAULT_DATASET_NAME="dummy-dataset"
DEFAULT_ACCOUNT_MODE="double"

print_help() {
    cat <<EOF
Usage:
  sh $SCRIPT_NAME [DATASET_PATH] [single|double]
  ./$SCRIPT_NAME [DATASET_PATH] [single|double]

Arguments:
  DATASET_PATH   Optional path to the existing dummy dataset directory
                 Default: ./$DEFAULT_DATASET_NAME
  single|double  Optional accounting mode
                 Default: $DEFAULT_ACCOUNT_MODE

Accounting mode:
  double  Assume the filesystem/accounting shows about 2x usage in 'du'.
          The script will estimate released space as:
            file_size * 2

  single  Normal 1x behavior.
          The script will estimate released space as:
            file_size * 1

Behavior:
  - If DATASET_PATH is omitted, the script uses:
      ./$DEFAULT_DATASET_NAME
  - Automatically detects the standard chunk file size from current part_*.bin files
  - Shows the current file layout first
  - Prompts for how many chunks to release
  - Releases files from the largest index backward
  - A smaller remainder file such as part_0000.bin will usually be kept

Examples:
  1) sh $SCRIPT_NAME
     Meaning:
       Release from ./$DEFAULT_DATASET_NAME using mode '$DEFAULT_ACCOUNT_MODE'

  2) sh $SCRIPT_NAME ./my-dataset
     Meaning:
       Release from ./my-dataset using mode '$DEFAULT_ACCOUNT_MODE'

  3) sh $SCRIPT_NAME single
     Meaning:
       Release from ./$DEFAULT_DATASET_NAME using mode 'single'

  4) sh $SCRIPT_NAME ./my-dataset single
     Meaning:
       Release from ./my-dataset using mode 'single'
EOF
}

if [ "$#" -eq 1 ]; then
    case "$1" in
        -h|--help)
            print_help
            exit 0
            ;;
    esac
fi

if [ "$#" -gt 2 ]; then
    echo "Error: invalid arguments."
    echo
    print_help
    exit 1
fi

DATASET_PATH="./$DEFAULT_DATASET_NAME"
ACCOUNT_MODE=$DEFAULT_ACCOUNT_MODE

if [ "$#" -eq 1 ]; then
    case "$1" in
        single|double)
            ACCOUNT_MODE=$1
            ;;
        *)
            DATASET_PATH=$1
            ;;
    esac
fi

if [ "$#" -eq 2 ]; then
    DATASET_PATH=$1
    ACCOUNT_MODE=$2
fi

case "$ACCOUNT_MODE" in
    single)
        ACCOUNT_FACTOR=1
        ;;
    double)
        ACCOUNT_FACTOR=2
        ;;
    *)
        echo "Error: accounting mode must be 'single' or 'double'."
        exit 1
        ;;
esac

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

if ! command -v stat >/dev/null 2>&1; then
    echo "Error: stat command not found."
    exit 1
fi

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM

ALL_FILES_LIST="$TMP_DIR/all_files.txt"
INFER_FILES_LIST="$TMP_DIR/infer_files.txt"
CHUNK_FILES_LIST="$TMP_DIR/chunk_files.txt"

human_size() {
    numfmt --to=iec-i --suffix=B "$1"
}

ABS_DATASET_PATH=$(CDPATH= cd -- "$DATASET_PATH" && pwd)
cd "$DATASET_PATH"

find . -maxdepth 1 -type f -name 'part_*.bin' -printf '%f\n' | sort > "$ALL_FILES_LIST"

if [ ! -s "$ALL_FILES_LIST" ]; then
    echo "Error: no part_*.bin files found in: $ABS_DATASET_PATH"
    exit 1
fi

echo "Dataset path              : $ABS_DATASET_PATH"
echo "Accounting mode           : $ACCOUNT_MODE"
echo "Accounting factor         : ${ACCOUNT_FACTOR}x"
echo
echo "Current files (top lines):"
ls -lh | head -n 12
echo

# Prefer part_0001.bin and later files when inferring the standard chunk size,
# because part_0000.bin may be the smaller remainder file.
grep -v '^part_0000\.bin$' "$ALL_FILES_LIST" > "$INFER_FILES_LIST" || true

if [ ! -s "$INFER_FILES_LIST" ]; then
    cp "$ALL_FILES_LIST" "$INFER_FILES_LIST"
    echo "Warning: only part_0000.bin or very few files remain."
    echo "Chunk size detection may be ambiguous."
    echo
fi

DETECTED_CHUNK_BYTES=$(
    while IFS= read -r file; do
        [ -n "$file" ] || continue
        stat -c %s "$file"
    done < "$INFER_FILES_LIST" \
    | sort -n \
    | uniq -c \
    | sort -k1,1nr -k2,2nr \
    | awk 'NR==1 { print $2 }'
)

if [ -z "$DETECTED_CHUNK_BYTES" ]; then
    echo "Error: failed to detect chunk size."
    exit 1
fi

ESTIMATED_CHUNK_RELEASE_BYTES=$((DETECTED_CHUNK_BYTES * ACCOUNT_FACTOR))

echo "Detected real chunk file size : $(human_size "$DETECTED_CHUNK_BYTES")"
echo "Estimated released size/chunk : $(human_size "$ESTIMATED_CHUNK_RELEASE_BYTES")"
echo

: > "$CHUNK_FILES_LIST"
sort -r "$ALL_FILES_LIST" | while IFS= read -r file; do
    [ -n "$file" ] || continue
    size=$(stat -c %s "$file")
    if [ "$size" -eq "$DETECTED_CHUNK_BYTES" ]; then
        echo "$file" >> "$CHUNK_FILES_LIST"
    fi
done

AVAILABLE_COUNT=$(wc -l < "$CHUNK_FILES_LIST" | tr -d ' ')

if [ "$AVAILABLE_COUNT" -eq 0 ]; then
    echo "No releasable chunk files found."
    exit 0
fi

echo "Releasable chunk files:"
sed 's/^/  /' "$CHUNK_FILES_LIST"
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
echo "Files to be removed:"
sed -n "1,${RELEASE_COUNT}p" "$CHUNK_FILES_LIST" | sed 's/^/  /'

TOTAL_RELEASE_BYTES=$((RELEASE_COUNT * ESTIMATED_CHUNK_RELEASE_BYTES))
echo "Estimated released size: $(human_size "$TOTAL_RELEASE_BYTES")"
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

sed -n "1,${RELEASE_COUNT}p" "$CHUNK_FILES_LIST" | while IFS= read -r file; do
    [ -n "$file" ] || continue
    rm -f -- "$file"
    echo "Removed $file"
done

sync

echo
echo "Done."
echo "Current usage:"
du -sh .
du -sh --apparent-size .
echo
ls -lh | head -n 12
